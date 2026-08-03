import Cocoa

/// The overlay. Deliberately plain: it appears while a modifier is held and vanishes the
/// instant it is released, so anything that draws attention to itself — animation, a
/// shadow that lingers, a title bar — is a cost paid on every single use.
final class HUDPanel {
    private var panel: NSPanel?

    /// Non-activating so the app underneath keeps focus and keeps its menu state. If the
    /// panel ever became key, the frontmost application would change and the shortcuts on
    /// screen would stop describing the thing the user is looking at.
    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }

    /// Whether to drop items the app currently reports as disabled. A shortcut that will
    /// not fire right now is noise, and hiding it is also the cheapest way to cut the wall
    /// of text down to something readable at a glance.
    ///
    /// A `let`: it had no writer anywhere in the sources or the tests, so the `var` was
    /// advertising a choice nobody could make and leaving four unreachable branches in the
    /// drawing code behind it.
    let hideDisabled = true

    /// Learning state — colours the rows. Set once at startup.
    var learning: LearningStore?
    /// Whether the keyboard in use ever reports the fn modifier. Observed, not configured.
    var canTypeFunctionModifier = false
    /// Which physical modifier keys are down. Observed too — a keyboard that does not
    /// report sides leaves this unknown and both caps light, as they always did.
    var heldSides: Shortcut.Sides = .unknown
    /// Whether F1-F12 reach applications rather than being spent on brightness and
    /// volume. Read from the system each time: it is a checkbox, not a property of the
    /// hardware, and the panel should follow it the moment it is flipped.
    var canTypeFunctionKeys: Bool { KeyboardLayout.functionKeysAreStandard }
    /// The frontmost app's icon, set alongside its name.
    var appIcon: NSImage?
    /// What the system text-editing layer contributes to this hold.
    ///
    /// A closure rather than a direct call, because the direct call reaches the machine:
    /// it asks the window server what has keyboard focus right now. Under test that is
    /// whatever the person running the suite happens to be looking at, so three cases
    /// passed or failed depending on whether a text field was focused at that instant —
    /// green meant nothing for them. A test supplies its own and gets the same answer
    /// every run.
    var textLayer: () -> [Shortcut] = {
        (!TextBindings.all.isEmpty && TextBindings.applyToFocusedElement()) ? TextBindings.all : []
    }
    /// Resolved once and reused: parsing a theme file on every hold would put file I/O
    /// on the path between pressing a key and seeing the panel.
    var theme: Theme = .builtin
    /// Everything one hold decides, decided once.
    ///
    /// These were eight mutable properties on this object, written by `show()` and by
    /// `renderPNG()` alike, and three bugs came out of that sharing: a preview left
    /// `holdFrame` set so the next real hold skipped positioning entirely and opened in
    /// the bottom-left corner; `hide()` did not clear `lastSections`, so adding ⇧ during
    /// the next app's scrape drew the *previous* app's bindings under the new app's name;
    /// and a preview fired mid-hold repainted the live panel from the preview target.
    ///
    /// A value cannot be half-cleared, and an offscreen render that builds its own cannot
    /// inherit or corrupt a live one.
    struct Hold {
        let appName: String
        let appKey: String
        /// The scrape, unfiltered — every combination the hold can narrow to.
        let sections: [MenuSection]
        /// Whether the system text-editing layer applies to what has focus. One
        /// Accessibility round trip, at the start, never per repaint.
        let textBindings: [Shortcut]
        /// Width is pinned for the whole hold; height follows each page.
        let frame: CGSize
        /// Top-left corner, in screen coordinates.
        let anchor: CGPoint
        /// The display this hold is sized and placed for. Read from one place, so the
        /// column reflow and the placement cannot disagree about which screen they mean.
        let screen: CGSize
    }

    private var currentHold: Hold?

    /// All metrics, weights and opacities in one value, so tuning legibility is a single
    /// place rather than a hunt through the view code.
    private var style: PanelStyle { PanelStyle(scale: CGFloat(settings.uiScale), theme: theme) }
    private var settings: LearningStore.Settings { learning?.settings ?? .init() }

    /// The paths actually drawn, for whoever needs to know what was consulted.
    ///
    /// App.swift used to work this out again with its own filter — enabled and matching
    /// the held modifiers — which ignored the three the panel applies (mastered, fn, and
    /// F-keys macOS has taken). Items the panel deliberately hid were recorded as having
    /// been looked at, so pressing one later counted as *assisted* and earned nothing: the
    /// user was denied credit for recalling something they were never shown.
    private(set) var shownPaths: [[String]] = []
    /// Guarded on having content rather than on the panel being on screen: narrowing to
    /// a combination with no bindings withdraws the panel, and an `isVisible` guard then
    /// made that withdrawal permanent — releasing ⇧ could never bring the ⌘ page back.
    func rerender(mods: Shortcut.Mods) {
        guard let currentHold else { return }
        draw(currentHold, mods: mods)
    }

    func show(appName: String, appKey: String, sections rawSections: [MenuSection],
              mods: Shortcut.Mods) {
        // Continuation is decided by identity, not by "a hold exists". Scrapes land
        // asynchronously — measured p99 143ms, max 486ms against a 250ms threshold — so a
        // slow app's results can arrive after the user has moved to another one and begun
        // a fresh hold. Without this the late arrival started a hold for the *old* app and
        // the new app's own results were then silently discarded as a repaint of it: the
        // panel showed one app's name, another's icon and the first one's bindings, for
        // the rest of the hold, with no way back.
        if currentHold?.appKey != appKey {
            currentHold = begin(appName: appName, appKey: appKey,
                                sections: rawSections, mods: mods)
        }
        guard let currentHold else { hide(); return }
        draw(currentHold, mods: mods)
    }

    /// Settles everything a hold needs before anything is drawn: whether the text layer
    /// applies, how wide the panel will be, and where its top-left corner goes. Nil when
    /// there is nothing to say at all.
    ///
    /// The frame does not move again until the keys come up. A panel that resizes is a
    /// panel that moves — it is centred, so every row that appears or disappears would
    /// slide the whole thing under the reader's eyes while their fingers are still down.
    /// - Parameter textLayer: nil to ask what has focus; a value to pin it. Only the
    ///   offscreen render pins it, and only so two captures are comparable. This was read
    ///   from a file *inside* here, which made it apply to real holds too: with the file
    ///   left behind by a render, every ⌃ hold in every app listed thirty text-editing
    ///   bindings whether or not a text field had focus. A knob for reproducing a
    ///   screenshot had become a behaviour change, on the live path, silently.
    private func begin(appName: String, appKey: String, sections: [MenuSection],
                       mods: Shortcut.Mods, pinnedLayer: Bool? = nil) -> Hold? {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // One Accessibility round trip, here, rather than one per repaint: narrowing from
        // ⌘ to ⇧⌘ happens while the fingers are still down and cannot afford one.
        let bindings = pinnedLayer.map { $0 ? TextBindings.all : [] } ?? textLayer()
        let visible = placementFrame(panel)

        let probe = Hold(appName: appName, appKey: appKey, sections: sections,
                         textBindings: bindings, frame: .zero, anchor: .zero,
                         screen: visible.size)
        let content = resolve(mods, in: probe)
        guard !content.hasNothingToShow else { return nil }

        let frame = frameForHold(content, in: probe)
        let anchor = Self.anchor(for: frame, in: visible)
        debugLog("placing on \(visible.debugDescription) at \(anchor.debugDescription) "
                 + "for a \(Int(frame.width))x\(Int(frame.height)) page")
        return Hold(appName: appName, appKey: appKey, sections: sections,
                    textBindings: bindings, frame: frame, anchor: anchor,
                    screen: visible.size)
    }

    /// Draws one page of a hold. Width comes from the hold; height is whatever this page
    /// needs, so the corner holds still and the list simply ends where it ends.
    private func draw(_ hold: Hold, mods: Shortcut.Mods) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let content = resolve(mods, in: hold)
        // Withdrawn only when there is genuinely nothing to say. An empty body with a
        // populated bar still answers "where is it, then?".
        guard !content.hasNothingToShow else { hide(); return }

        shownPaths = content.shownPaths
        let (view, size) = buildContent(content, in: hold,
                                        minimum: CGSize(width: hold.frame.width, height: 0))
        panel.contentView = view
        panel.setContentSize(size)
        // Clamped here as well as in `anchor`. The anchor is computed from the *tallest*
        // page and clamped to the screen, but the page actually drawn can be taller still:
        // the layout deliberately trades height for width when both budgets cannot be met,
        // and says so in the log. Placing an unclamped size against a clamped corner put
        // the last rows below the bottom of the display, with nothing to indicate it.
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, anchoredAt: hold.anchor,
                                         in: placementFrame(panel)))
        panel.orderFrontRegardless()
    }

    /// Builds the panel's content view without showing it, so the same code path can be
    /// rendered offscreen. Verifying the panel by eye otherwise needs a screen recording
    /// grant *and* someone holding a key down; rasterising the view needs neither and is
    /// reproducible.
    /// Computes the panel arithmetically and hands it to a view that only draws.
    /// Nothing here negotiates: every position comes from a measured string, so a label
    /// can never be narrower than its own text.
    private func buildContent(_ model: PanelContent, in hold: Hold,
                              minimum: CGSize = .zero) -> (NSView, NSSize) {
        let layout = builder(for: hold).build(model, allSections: hold.sections, minimum: minimum)

        let view = PanelView(frame: NSRect(origin: .zero, size: layout.size))
        view.layout = layout
        view.theme = theme
        return (view, layout.size)
    }

    private func builder(for hold: Hold) -> PanelLayoutBuilder {
        // Both caps come off the hold's screen. They used to be read from two different
        // places — the reflow from `NSScreen.main`, the placement from the panel's own
        // screen — so on two displays of different sizes the columns were wrapped for one
        // and the panel opened on the other.
        let screen = hold.screen == .zero ? CGSize(width: 1440, height: 900) : hold.screen
        return PanelLayoutBuilder(
            style: style, learning: learning,
            showProgress: settings.perAppProgress, keymap: settings.layoutMode == "keymap",
            currentAppKey: hold.appKey, appIcon: appIcon, heldSides: heldSides,
            maxHeight: screen.height * style.maxHeightFraction,
            maxWidth: screen.width * style.maxWidthFraction)
    }

    private func resolve(_ mods: Shortcut.Mods, in hold: Hold) -> PanelContent {
        PanelContent.resolve(
            appName: hold.appName, appKey: hold.appKey, mods: mods, sections: hold.sections,
            learning: learning, hideDisabled: hideDisabled,
            hideMastered: settings.hideMastered,
            textBindings: hold.textBindings,
            canTypeFunctionModifier: canTypeFunctionModifier,
            canTypeFunctionKeys: canTypeFunctionKeys)
    }

    /// Which screen the panel belongs on.
    ///
    /// A brand-new panel is created at `.zero` — a zero-size rect at the origin — and
    /// `NSWindow.screen` is nil for a window that is not on any screen, while
    /// `NSScreen.main` is documented in terms of the window with keyboard focus, which
    /// this app deliberately never has. Both can therefore be nil on the very first hold,
    /// and the panel opened in the bottom-left corner. `NSScreen.screens.first` is the
    /// display with the menu bar and cannot be empty on a running Mac.
    private func placementFrame(_ panel: NSPanel) -> CGRect {
        // The display the user is working on, not the one the panel was last shown on.
        // `panel.screen` is that last display and sticks there for the process's life, so
        // moving to an external monitor left the panel behind on the laptop — and on the
        // very first hold it is nil, along with `NSScreen.main`, which is defined by
        // keyboard focus and this app never takes any.
        let screen = targetScreen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        if screen == nil { debugLog("no screen available for placement") }
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The screen holding the frontmost app's window, when it could be determined.
    var targetScreen: NSScreen?

    /// Top-left corner for a hold, from centring its tallest page — clamped so the panel
    /// is inside the screen whatever it was handed.
    ///
    /// Pure and static so it can be tested. Window placement had no test at all, which is
    /// why it took a person noticing to find out it opened in the corner; the layout
    /// inside the panel has been arithmetic-with-tests for a while and the window holding
    /// it was still hand-placed geometry nobody could check.
    ///
    /// `NSWindow.center()` is not used: it re-centres whatever size the window happens to
    /// be at that moment, which is exactly the movement being removed here.
    static func anchor(for frame: CGSize, in visible: CGRect) -> CGPoint {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        let top = max(min(visible.midY + height / 2, visible.maxY), visible.minY + height)
        return CGPoint(x: x.rounded(), y: top.rounded())
    }

    /// Bottom-left origin for a page of `size` hanging from `anchor`, kept on screen.
    ///
    /// Pure and static for the same reason `anchor(for:in:)` is: this is the arithmetic
    /// that decides where the window lands, and it had none of its own tests while the
    /// layout inside the window had ninety.
    static func origin(for size: CGSize, anchoredAt anchor: CGPoint, in visible: CGRect) -> CGPoint {
        let x = min(max(anchor.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let top = min(max(anchor.y, visible.minY + min(size.height, visible.height)), visible.maxY)
        return CGPoint(x: x.rounded(), y: (top - size.height).rounded())
    }

    /// The largest page any combination reachable from this hold would need.
    ///
    /// Every combination in the bar is a page the user can open without letting go, so
    /// every one of them has to fit. Measuring them all is arithmetic over strings — no
    /// menus are walked and nothing is drawn — but it is not free and it is not hidden:
    /// this runs *after* the threshold has already elapsed, on the way to first paint, and
    /// an app with eleven chips pays for eleven layouts. The elapsed time is logged rather
    /// than assumed; an earlier version of this comment claimed the cost was absorbed by
    /// the 250ms wait, which was simply wrong.
    private func frameForHold(_ content: PanelContent, in hold: Hold) -> CGSize {
        let began = DispatchTime.now().uptimeNanoseconds
        var size = CGSize.zero
        for combination in content.combinations {
            let page = combination.mods == content.mods ? content : resolve(combination.mods, in: hold)
            guard !page.isEmpty else { continue }
            let measured = builder(for: hold).build(page, allSections: hold.sections).size
            size.width = max(size.width, measured.width)
            size.height = max(size.height, measured.height)
        }
        debugLog(String(format: "hold frame %.0fx%.0f from %d combinations in %.1fms",
                        size.width, size.height, content.combinations.count,
                        Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000))
        return size
    }

    /// Renders a page offscreen, for verification.
    ///
    /// It builds its *own* hold and never touches `currentHold`. When these shared the
    /// panel's mutable state a preview left `holdFrame` set, and the next real hold —
    /// looking like a continuation of one that never happened — skipped positioning
    /// entirely and drew at the `contentRect: .zero` origin, in the bottom-left corner.
    /// - Parameter icon: the icon to draw, passed in rather than read off the panel.
    ///   `appIcon` is written by the live path from whichever app was last held, which is
    ///   why it used to be blanked here — but blanking it made every capture disagree with
    ///   the running panel, which draws the frontmost app's icon in its header. The render
    ///   knows exactly which app it is drawing, so the icon is not ambient for it.
    /// - Parameter sides: which physical modifier keys to draw as held. Neutralised to
    ///   `.unknown` here for the same reason the screen was, and `.unknown` lights *both*
    ///   caps of every held modifier — correct for a keyboard that does not report sides,
    ///   and a picture of something that never happens for one that does. A capture states
    ///   what it is showing rather than falling through to the ambiguous case.
    func renderPNG(appName: String, appKey: String, sections: [MenuSection],
                   mods: Shortcut.Mods, icon: NSImage? = nil,
                   sides: Shortcut.Sides = .unknown) -> Data? {
        // Pinned so two captures of different builds are comparable. Whether the text
        // layer applies otherwise depends on what has keyboard focus at that instant, and
        // comparing two builds produced thirty-two differing images of which twenty-four
        // were only that.
        let pin = (try? String(contentsOf: DataDir.url.appendingPathComponent("preview-text-layer.txt"),
                               encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

        // The rest of what a render depends on is instance state the live path writes and
        // this path does not. `canTypeFunctionModifier` is a *filter* input, so a capture
        // taken before any hold dropped every fn binding and one taken after kept them —
        // two images of the same build that disagree. The target screen came from
        // whichever app was held last, so a render of VS Code wrapped its columns for
        // another app's display. Neutral values here; a render is not a continuation of
        // anything — except the icon, which the caller states outright.
        let liveIcon = appIcon, liveScreen = targetScreen, liveSides = heldSides
        let liveFn = canTypeFunctionModifier
        appIcon = icon; targetScreen = nil; heldSides = sides; canTypeFunctionModifier = false
        defer { appIcon = liveIcon; targetScreen = liveScreen; heldSides = liveSides
                canTypeFunctionModifier = liveFn }

        guard let hold = begin(appName: appName, appKey: appKey, sections: sections,
                               mods: mods, pinnedLayer: pin.map { $0 == "1" }) else { return nil }
        let model = resolve(mods, in: hold)
        guard !model.hasNothingToShow else { return nil }
        let (view, size) = buildContent(model, in: hold,
                                        minimum: CGSize(width: hold.frame.width, height: 0))
        guard size.width > 1, size.height > 1 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Builds and lays out the panel without showing it, for tests. Returns the root view
    /// so assertions can be made against measured frames rather than against a rendered
    /// image — three build cycles were spent adjusting constraints to fix a truncation
    /// that a 2x screenshot only appeared to show.
    func layoutForTesting(_ model: PanelContent, minimum: CGSize = .zero) -> PanelLayout {
        let hold = Hold(appName: model.appName, appKey: model.appKey,
                        sections: [MenuSection(name: "test", items: model.rows.map(\.shortcut))],
                        textBindings: [], frame: minimum, anchor: .zero, screen: .zero)
        return (buildContent(model, in: hold, minimum: minimum).0 as! PanelView).layout
    }

    /// Whether a hold is in progress. Exposed so the invariant that broke can be tested:
    /// an offscreen render must not leave one behind, because `show()` treats an existing
    /// hold as a continuation and skips positioning entirely.
    var hasActiveHold: Bool { currentHold != nil }

    func hide() {
        panel?.orderOut(nil)
        // One value, cleared in one place. It used to be eight properties and `hide()`
        // cleared four of them, which is how a hold kept inheriting the last one's frame,
        // menus and text-layer answer.
        currentHold = nil
        shownPaths = []
        // And the menus. `rerender` is guarded on these being non-empty, and a scrape runs
        // asynchronously — measured p99 143ms, max 486ms over 651 real invocations — so
        // adding ⇧ inside that window redrew the *previous* app's bindings under the new
        // app's name, and then pinned the new app's panel to the old one's frame.
    }











}
