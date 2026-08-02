import Cocoa

/// Wiring only: it owns the pieces and connects them, and holds no policy of its own.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let trigger = Trigger()
    private let hud = HUDPanel()
    private let learning = LearningStore()
    private let stats = InvocationStats()
    private lazy var usage = UsageLog(learning: learning)
    private var statusMenu: StatusMenu?

    private let dataDir = DataDir.url

    /// Scraping a menu bar makes the target app build its menus, which can cost hundreds
    /// of milliseconds in a large app. Cache per pid and reuse until the app is switched
    /// away from and back, so the panel is instant on every hold after the first.
    private var cache: [pid_t: [MenuSection]] = [:]
    private var scraping: Set<pid_t> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpStatusItem()
        hud.learning = learning
        KeyboardLayout.load()
        hud.theme = Theme.load(source: learning.settings.themeSource)
        debugLog("theme: \(hud.theme.name) font=\(hud.theme.fontFamily ?? "system")")
        usage.invocationStats = stats
        stats.loadInBackground()
        if learning.settings.weeklyDigest { Digest.generateIfNeeded(dataDir: dataDir) }
        if Clock.isFake { debugLog("CLOCK IS FAKED — do not trust timestamps in this run") }

        let accessibility = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

        trigger.onHold = { [weak self] in self?.present() }
        // Narrowing must not re-walk the menus — the user's fingers are still on the
        // keys, so this repaints from what is already in hand.
        trigger.onModifiersChanged = { [weak self] mods in
            guard let self else { return }
            self.hud.heldSides = self.trigger.currentSides
            self.hud.rerender(mods: mods)
            // Each page is its own consultation. Crediting only the first one meant
            // narrowing ⌘ to ⇧⌘ and then firing something read straight off the ⇧⌘ page
            // was recorded as unaided recall — the panel taking credit for its own help.
            if let app = NSWorkspace.shared.frontmostApplication, !self.hud.shownPaths.isEmpty {
                self.usage.notePanelShown(app: app.bundleIdentifier ?? app.localizedName ?? "?",
                                          paths: self.hud.shownPaths)
            }
        }
        trigger.onRelease = { [weak self] in self?.hud.hide() }
        trigger.onChord = { [weak self] mods, key in self?.creditChord(mods, key) }
        let tapCreated = trigger.start()

        usage.followFrontmostApp()
        installPreviewSignal()

        // Report honestly rather than optimistically: a listen-only tap is created fine
        // without Input Monitoring and then receives nothing at all, so "created" is not
        // "working". If no event has arrived a few seconds in, say so.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            // Ask TCC, do not infer from silence. `isReceiving` only flips once an event
            // arrives, so a launch during a quiet moment — which is every launch driven
            // from a script — used to raise a false alarm about a permission that was
            // perfectly fine.
            let listening = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            debugLog("permissions: inputMonitoring=\(listening) accessibility=\(AXIsProcessTrusted()) "
                     + "tapCreated=\(tapCreated) eventsSeen=\(self.trigger.isReceiving)")
            if !tapCreated || !listening {
                self.warn("KeyHUD is not receiving key events",
                          "Grant Input Monitoring, then relaunch.\nSystem Settings ▸ Privacy & Security ▸ Input Monitoring")
            } else if !accessibility && !AXIsProcessTrusted() {
                self.warn("KeyHUD cannot read menus",
                          "Grant Accessibility, then relaunch.\nSystem Settings ▸ Privacy & Security ▸ Accessibility")
            }
        }
    }

    /// The save is debounced two seconds and a menu-bar agent is quit without warning, so
    /// without this the last couple of seconds of use are simply lost. Every development
    /// restart in this project has been a `pkill`, which is a SIGTERM and does not reach
    /// this — `dev.sh` now asks the app to quit instead.
    func applicationWillTerminate(_ note: Notification) {
        learning.flush()
    }

    /// Menu *structure* is stable per app, so it is cached. Whether an item is currently
    /// enabled is not — it depends on what has focus, what is selected, what is on the
    /// pasteboard — so that one bit is re-read on every invocation. Showing a cached
    /// enabled-state would be worse than showing none, because it would be confidently
    /// wrong about which shortcuts will actually fire.
    private func present() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"
        let appKey = app.bundleIdentifier ?? name
        guard !scraping.contains(pid) else { return }
        scraping.insert(pid)
        // Snapshotted on the main queue and captured by value. Reading the dictionary from
        // the background block while the main queue writes it is a data race on a Swift
        // Dictionary — not merely a stale read but possible corruption during a resize.
        let snapshot = cache[pid]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let began = DispatchTime.now().uptimeNanoseconds
            var cached = false
            var sections: [MenuSection]

            if let hit = snapshot, let fresh = MenuScraper.refreshEnabled(hit) {
                sections = fresh
                cached = true
            } else {
                sections = MenuScraper.scrape(pid: pid)
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000

            DispatchQueue.main.async {
                self.scraping.remove(pid)
                // An empty scrape is not a fact about the app, it is a fact about the
                // moment: hold ⌘ while an app is still launching and the menu bar is not
                // there yet. Caching it was permanent — `refreshEnabled` loops zero times
                // over an empty array and returns it as successfully refreshed, so nothing
                // ever rescraped and that app showed no panel for the rest of the run.
                // Confirmed in invocations.jsonl: runs of `total:0, cached:true, ms:0`.
                if sections.isEmpty {
                    self.cache[pid] = nil
                } else {
                    self.cache[pid] = sections
                }
                // Only draw if the modifier is still down; otherwise the panel would
                // appear after the user has already let go.
                let shown = self.trigger.isHolding && !sections.isEmpty
                if shown {
                    self.hud.targetScreen = Self.screen(holdingWindowOf: pid)
                    self.hud.canTypeFunctionModifier = self.trigger.sawFunctionModifier
                    self.hud.heldSides = self.trigger.currentSides
                    self.hud.appIcon = app.icon
                    self.hud.show(appName: name, appKey: appKey,
                                  sections: sections, mods: self.trigger.currentMods)
                    // Asked of the panel, not worked out again here. This was a fourth
                    // copy of the visibility rule and it disagreed with the other three:
                    // it ignored mastered items, fn chords and the F-keys macOS has taken,
                    // so bindings the panel deliberately hid were recorded as consulted —
                    // and pressing one later then counted as assisted and earned nothing.
                    self.usage.notePanelShown(app: appKey, paths: self.hud.shownPaths)
                    // Off the critical path on purpose: the denominator only needs to be
                    // right by the next invocation, never by this one.
                    self.learning.noteObserved(app: appKey,
                                               paths: sections.flatMap(\.items).filter(\.enabled).map(\.path))
                }
                self.usage.recordInvocation(app: name, sections: sections,
                                            cached: cached, elapsedMs: ms, shown: shown)
            }
        }
    }

    /// Which display the app being described is on.
    ///
    /// Read from its focused window rather than from where the panel last appeared: the
    /// panel used to stay on whichever screen it was first shown on for the process's
    /// whole life, so moving to an external monitor left the cheat sheet behind on the
    /// laptop. Nil when the app has no focused window, which the caller falls back from.
    private static func screen(holdingWindowOf pid: pid_t) -> NSScreen? {
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }

        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXPositionAttribute as CFString,
                                            &positionRef) == .success,
              let value = positionRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }

        // AX reports windows in a top-left origin space; NSScreen works bottom-left.
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return NSScreen.screens.first { $0.frame.contains(flipped) }
    }

    /// Credits a typed chord against the frontmost app's shortcut table.
    ///
    /// Deferred briefly: when the app *does* emit kAXMenuItemSelected the observer records
    /// the same use with a proper menu path, and crediting both would double-count. The
    /// AX route is preferred because it knows the path; this is the fallback for apps that
    /// stay silent.
    /// The text-editing layer is offered to the match as well as the menu. It was not,
    /// and the menu is the only table it was ever compared against — so every binding in
    /// the テキスト編集 section was drawn on the panel and could never be counted, in every
    /// app, from the day that section was added. ^A is printed as 行頭へ, pressed, and
    /// discarded here.
    ///
    /// The cache is no longer required to be present. It gated this whole function, which
    /// meant a text binding pressed in an app whose menu had not been scraped yet was lost
    /// as well — and the text layer does not come from the menu, so it had no business
    /// waiting on one.
    private func creditChord(_ mods: Shortcut.Mods, _ key: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appKey = app.bundleIdentifier ?? app.localizedName ?? "?"
        // What arrived, before anything is decided about it. Without this a chord that
        // matches nothing and a chord that never reaches here look identical in the log —
        // which is exactly where the Ghostty investigation stalled.
        debugLog("chord seen: \(mods.glyphs)\(key) in \(appKey), "
                 + "menu=\(cache[app.processIdentifier]?.count ?? -1) sections")
        guard let credit = ChordMatch.credit(mods: mods, key: key,
                                             menu: cache[app.processIdentifier] ?? [],
                                             text: TextBindings.all) else {
            debugLog("chord matched nothing: \(mods.glyphs)\(key) in \(appKey)")
            return
        }
        usage.creditChordUse(app: appKey, path: credit.shortcut.path,
                             confirm: credit.needsTextFocus
                                 ? TextBindings.applyToFocusedElement : nil)
    }

    // MARK: - preview

    private var previewSource: DispatchSourceSignal?

    /// `kill -USR1 <pid>` writes the panel, as it would look right now for the frontmost
    /// app, to data/preview-*.png — one per layout mode. Checking the UI otherwise means
    /// a screen-recording grant plus a human holding a modifier down, neither of which is
    /// reproducible; this renders the real view through the real code path instead.
    private func installPreviewSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.writePreviews() }
        source.resume()
        previewSource = source

        // SIGUSR2 captures every running app's raw key equivalents into a fixture.
        // Four separate decoding bugs shipped — glyphs, control characters, the Globe
        // bit, shifted characters — each found by a user noticing a wrong label. They
        // are one class of failure: macOS encodes key equivalents in more ways than any
        // reading of the docs suggests. A corpus turns "find them one at a time" into a
        // test that fails the moment an unhandled encoding exists anywhere on the machine.
        signal(SIGUSR2, SIG_IGN)
        let corpus = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        corpus.setEventHandler { [weak self] in self?.writeCorpus() }
        corpus.resume()
        corpusSource = corpus

        // SIGINFO measures the ceiling on turning mouse use into shortcut suggestions.
        // See UIProbe: it reads names of on-screen controls, nothing about behaviour.
        signal(SIGINFO, SIG_IGN)
        let probe = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        probe.setEventHandler { [weak self] in self?.writeUIProbe() }
        probe.resume()
        probeSource = probe
    }

    private var corpusSource: DispatchSourceSignal?
    private var probeSource: DispatchSourceSignal?

    /// Walks the on-screen windows of every regular app and reports how many of their
    /// controls are also shortcut-bearing menu commands.
    private func writeUIProbe() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        DispatchQueue.global(qos: .utility).async {
            var lines = ["app,elements,controls,named,matched"]
            var detail: [String] = []
            for app in apps {
                let name = app.bundleIdentifier ?? app.localizedName ?? "?"
                let r = UIProbe.probe(pid: app.processIdentifier, name: name)
                guard r.elements > 0 else { continue }
                lines.append("\(r.app),\(r.elements),\(r.controls),\(r.named),\(r.matched.count)")
                for m in r.matched.prefix(20) { detail.append("  \(r.app)  \(m.chord)  \(m.name)") }
                if !r.unmatchedNames.isEmpty {
                    detail.append("  -- \(r.app) control names with no shortcut match:")
                    detail.append("     " + r.unmatchedNames.prefix(30).joined(separator: " | "))
                }
            }
            let out = (lines + ["", "matched controls (name is also a shortcut-bearing menu command):"]
                       + detail).joined(separator: "\n") + "\n"
            try? out.write(to: DataDir.url.appendingPathComponent("ui-probe.txt"),
                           atomically: true, encoding: .utf8)
            debugLog("ui probe written")
        }
    }

    private func writeCorpus() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var out: [String: Any] = [:]
            for app in apps {
                let rows = MenuScraper.dumpRaw(pid: app.processIdentifier)
                guard !rows.isEmpty else { continue }
                out[app.bundleIdentifier ?? app.localizedName ?? "?"] = rows
            }
            guard let data = try? JSONSerialization.data(withJSONObject: out,
                                                         options: [.prettyPrinted, .sortedKeys]) else { return }
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/KeyHUDCoreTests/Fixtures/ax-corpus.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
            debugLog("corpus: \(out.count) apps -> \(url.path)")
        }
    }

    /// Which combination the preview renders, from data/preview-mods.txt — so any
    /// combination can be inspected without a person holding keys down.
    ///
    /// Space-separated names ("shift cmd", "ctrl opt"), because the fixed list of
    /// spellings it used to accept silently fell through to ⌘ for everything else, and a
    /// render of the wrong combination looks exactly like a render of the right one.
    static var previewMods: Shortcut.Mods {
        let file = DataDir.url.appendingPathComponent("preview-mods.txt")
        let names: [String: Shortcut.Mods] = [
            "cmd": .command, "command": .command,
            "ctrl": .control, "control": .control,
            "opt": .option, "option": .option, "alt": .option,
            "shift": .shift, "fn": .function,
        ]
        let words = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return [.command] }
        var mods: Shortcut.Mods = []
        for word in words {
            guard let mod = names[word] else {
                debugLog("preview-mods.txt: unknown modifier '\(word)' — rendering ⌘")
                return [.command]
            }
            mods.insert(mod)
        }
        return mods
    }

    private func writePreviews() {
        // renderPNG writes the same fields rerender reads. Firing this during a hold
        // redrew the on-screen panel from the preview target's menus.
        guard !trigger.isHolding else {
            debugLog("preview skipped: a hold is in progress")
            return
        }
        // Scraping works on any pid, not only the frontmost, so a preview can target a
        // named app without activating it and disturbing whatever the user is doing.
        // Falls back to the frontmost app when no target is written.
        let targetFile = dataDir.appendingPathComponent("preview-target.txt")
        let wanted = (try? String(contentsOf: targetFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = wanted.flatMap { name in
            NSWorkspace.shared.runningApplications.first {
                $0.localizedName == name || $0.bundleIdentifier == name
            }
        }
        // Falling back silently is how a render gets captured against the wrong app and
        // then read as evidence about the right one. It has happened; say so instead.
        if let wanted, !wanted.isEmpty, target == nil {
            debugLog("preview target '\(wanted)' is not running — falling back to the frontmost app")
        }
        guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"
        let appKey = app.bundleIdentifier ?? name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sections = MenuScraper.scrape(pid: pid)
            if let raw = try? JSONSerialization.data(
                withJSONObject: MenuScraper.dumpRaw(pid: pid), options: [.prettyPrinted]) {
                try? raw.write(to: DataDir.url.appendingPathComponent("preview-raw.json"))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let saved = self.learning.settings.layoutMode
                for mode in ["list", "keymap"] {
                    var s = self.learning.settings
                    s.layoutMode = mode
                    self.learning.settings = s
                    guard let png = self.hud.renderPNG(appName: name, appKey: appKey,
                                                       sections: sections, mods: Self.previewMods,
                                                       icon: app.icon)
                    else { continue }
                    try? png.write(to: self.dataDir.appendingPathComponent("preview-\(mode).png"))
                }
                var restore = self.learning.settings
                restore.layoutMode = saved
                self.learning.settings = restore
                debugLog("previews written for \(name)")
            }
        }
    }

    // MARK: - status menu

    private func setUpStatusItem() {
        statusMenu = StatusMenu(actions: StatusMenu.Actions(
            settings: { [weak self] in self?.learning.settings ?? .init() },
            updateSettings: { [weak self] new in
                guard let self else { return }
                let themeChanged = new.themeSource != self.learning.settings.themeSource
                self.learning.settings = new
                if themeChanged { self.hud.theme = Theme.load(source: new.themeSource) }
            },
            themeName: { [weak self] in self?.hud.theme.name ?? "" },
            weeklyCounts: { [weak self] in self?.stats.recentWeeks() ?? [] },
            trend: { [weak self] in self?.stats.trend() ?? "" },
            writeDigest: { [weak self] in
                guard let self else { return }
                guard let path = Digest.generateCurrent(dataDir: self.dataDir) else {
                    self.warn("まだ書き出せるデータがありません", "しばらく使ってから試してください。")
                    return
                }
                NSWorkspace.shared.open(path)
            },
            openDataFolder: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.dataDir)
            }))
    }

    private func frontmostKey() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier ?? app?.localizedName ?? "?"
    }

    private func warn(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }
}


/// The one symbol the executable needs. Everything else stays internal, so the test
/// target can reach it with `@testable import` without the whole codebase having to be
/// annotated `public` just to be tested.
public func runKeyHUD() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // Held by the NSApplication for the process lifetime; the local would otherwise be
    // the only strong reference and could be released.
    objc_setAssociatedObject(app, "keyhud.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
    fatalError("NSApplication.run returned")
}
