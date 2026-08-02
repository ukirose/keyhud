import Cocoa
import ApplicationServices

/// Records which menu items get *picked with the mouse* while the app runs, and whether
/// the item already had a keyboard shortcut.
///
/// This is the measurement for the one feature idea in this space that isn't already a
/// graveyard. Every prior attempt at "personalise by usage" built a heatmap of the
/// shortcuts you already press — `muratcakmak/keyboard-logger` (2★),
/// `keijiro1992/KeyLogger` (0★), `masonc15/keymapper` (0★). Ranking a cheat sheet by
/// what you already use is backwards: the entries you use most are the ones you never
/// need to look up. The useful direction is the inverse — the thing you keep reaching
/// for the mouse to do, that has a shortcut you haven't learned.
///
/// Pre-registered kill threshold: if fewer than 20 shortcut-bearing menu items per day
/// are picked by mouse, there is nothing here worth building and the feature is dropped.
///
/// Everything stays in a local JSONL file. Nothing is uploaded.
final class UsageLog {
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private let learning: LearningStore
    /// Depth of currently-open menus. A selection while one is open came from the menu;
    /// with none open it was a shortcut press.
    ///
    /// This replaced a two-second window, which was wrong in both directions: browsing a
    /// menu for longer than two seconds and then clicking recorded a *keyboard* press and
    /// advanced the graduation chain, and pressing a shortcut shortly after dismissing a
    /// menu with Esc recorded a *mouse* pick and wiped it.
    fileprivate var openMenus = 0
    /// What the panel last put on screen, and when. A press shortly afterwards counts as
    /// *assisted* — the user looked it up and acted on it.
    ///
    /// Both halves matter. Stamping the time on release as well as on show marked every
    /// hold as a consultation, including the ordinary 250ms+ pause before typing ⌘S, and
    /// an assisted press blocks graduation for fourteen days — so simply being a slow
    /// typist made every shortcut unlearnable. And a single global timestamp credited the
    /// consultation to whatever was pressed next, in any app; only the paths actually
    /// displayed can honestly be called assisted.
    private var shownPaths: Set<String> = []
    private var shownAt = Date.distantPast
    private var shownApp = ""

    private var pendingChords: [String: DispatchWorkItem] = [:]

    /// Records a use inferred from the keystroke itself, unless the app reports the same
    /// selection first. The delay is the deduplication: AX wins when it speaks.
    ///
    /// - Parameter confirm: an extra condition the caller cannot afford to evaluate at the
    ///   keystroke. The system text-editing bindings only fire when something that accepts
    ///   typing has focus, and asking that is an Accessibility round trip — while the
    ///   caller is inside the event tap callback, on the main run loop, which macOS
    ///   disables when it runs slow. Asked inside the deferred block instead: by then the
    ///   tap has long returned, and focus has not moved in 0.4s.
    func creditChordUse(app: String, path: [String], confirm: (() -> Bool)? = nil) {
        let k = app + "\u{1F}" + path.joined(separator: "\u{1F}")
        pendingChords[k]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChords[k] = nil
            if let confirm, !confirm() {
                debugLog("chord not credited, focus does not take it: \(k)")
                return
            }
            self.learning.noteKeyboardUse(app: app, path: path,
                                          assisted: self.wasAssisted(app: app, path: path))
            debugLog("chord credited \(k)")
        }
        pendingChords[k] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Called when AX reports a selection, so the keystroke fallback stands down.
    private func cancelPendingChord(app: String, path: [String]) {
        let k = app + "\u{1F}" + path.joined(separator: "\u{1F}")
        pendingChords[k]?.cancel()
        pendingChords[k] = nil
    }

    func notePanelShown(app: String, paths: [[String]]) {
        shownApp = app
        shownAt = Date()
        shownPaths = Set(paths.map { $0.joined(separator: "\u{1F}") })
    }

    private func wasAssisted(app: String, path: [String]) -> Bool {
        guard app == shownApp, Date().timeIntervalSince(shownAt) < 10 else { return false }
        return shownPaths.contains(path.joined(separator: "\u{1F}"))
    }
    /// M4 — kept live in memory so opening the status menu costs nothing.
    weak var invocationStats: InvocationStats?
    private let url: URL
    private let invocationsURL: URL

    init(learning: LearningStore) {
        self.learning = learning
        let dir = DataDir.url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("menu-picks.jsonl")
        invocationsURL = dir.appendingPathComponent("invocations.jsonl")
    }

    /// Diagnostic for one open question: does `AXEnabled` actually track context, or do
    /// apps only validate their menus when a menu is really opened? If the enabled count
    /// equals the total on every invocation, the contextual filter is a no-op and the
    /// feature needs a different mechanism. Also records how long the walk took, which
    /// decides whether the structure cache is earning its keep.
    func recordInvocation(app: String, sections: [MenuSection], cached: Bool,
                          elapsedMs: Double, shown: Bool) {
        let items = sections.flatMap(\.items)
        if shown { invocationStats?.noteShown(at: Date()) }
        write(to: invocationsURL, [
            "t": ISO8601DateFormatter().string(from: Date()),
            "app": app,
            // The inverse KPI counts lookups, and a hold released before the scrape
            // landed was never a lookup. Without this flag every accidental 250ms hold
            // inflates the number the user is trying to drive down.
            "shown": shown,
            "total": items.count,
            "enabled": items.filter(\.enabled).count,
            // Which attribute carried the key. `glyph` counts arrows, ↩, ⌫, F-keys and
            // 英数/かな — every one of which the first version dropped on the floor.
            "char": items.filter { $0.source == .char }.count,
            "glyph": items.filter { $0.source == .glyph }.count,
            "vkey": items.filter { $0.source == .virtualKey }.count,
            "cached": cached,
            "ms": (elapsedMs * 10).rounded() / 10,
        ])
    }

    func followFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.attach(to: app)
        }
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        detach()

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, ctx in
            guard let ctx else { return }
            let log = Unmanaged<UsageLog>.fromOpaque(ctx).takeUnretainedValue()
            switch notification as String {
            case kAXMenuOpenedNotification as String: log.openMenus += 1
            case kAXMenuClosedNotification as String: log.openMenus = max(0, log.openMenus - 1)
            default: log.record(element)
            }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // kAXMenuItemSelectedNotification fires for a shortcut press just as much as for
        // a mouse pick — the first 34 records were 20x Undo, i.e. ⌘Z, not the Edit menu
        // being opened twenty times. Watching for a menu actually opening is what
        // separates the two, and separating them is the entire point of this log.
        AXObserverAddNotification(obs, axApp, kAXMenuOpenedNotification as CFString, ctx)
        AXObserverAddNotification(obs, axApp, kAXMenuClosedNotification as CFString, ctx)
        AXObserverAddNotification(obs, axApp, kAXMenuItemSelectedNotification as CFString, ctx)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        observer = obs
        observedPID = pid
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
    }

    private func record(_ item: AXUIElement) {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
        guard let title = titleRef as? String, !title.isEmpty else { return }

        // Must agree with the scraper. Checking AXMenuItemCmdChar alone — as this did —
        // classifies every glyph-carried shortcut (arrows, ↩, ⌫, F-keys, 英数/かな) as
        // having no shortcut, so those items never enter the learning model at all while
        // the panel happily displays them.
        let hasShortcut = MenuScraper.keyEquivalent(item) != nil

        let viaMenu = openMenus > 0
        let app = NSWorkspace.shared.frontmostApplication
        let appKey = app?.bundleIdentifier ?? app?.localizedName ?? "?"
        let appName = app?.localizedName ?? "?"
        let path = MenuScraper.path(of: item)
        let itemPath = path.isEmpty ? [title] : path

        learning.noteSelectionSeen(app: appKey)
        cancelPendingChord(app: appKey, path: itemPath)

        // Feed the learning model. Both branches matter: mouse picks define what still
        // needs emphasis, unaided keyboard uses are the only thing that earns progress.
        if hasShortcut {
            if viaMenu {
                learning.noteMousePick(app: appKey, path: itemPath)
            } else {
                learning.noteKeyboardUse(app: appKey, path: itemPath,
                                         assisted: wasAssisted(app: appKey, path: itemPath))
            }
        }

        write(to: url, [
            "t": ISO8601DateFormatter().string(from: Date()),
            "app": appName,
            "appKey": appKey,
            "item": title,
            "path": itemPath,
            "hasShortcut": hasShortcut,
            "viaMenu": viaMenu,
        ])
    }

    private func write(to destination: URL, _ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = Data((json + "\n").utf8)

        if let handle = try? FileHandle(forWritingTo: destination) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: destination)
        }
    }
}
