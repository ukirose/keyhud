import XCTest
import ApplicationServices
@testable import KeyHUDCore

/// Assertions against the computed layout rather than against a screenshot or a view tree.
///
/// The panel body was a tree of nested NSStackViews, and four rounds of constraint changes
/// failed to stop "Minimize" drawing as "Minimi..." — Auto Layout resolved the row
/// differently from how it drew it, so measuring the views agreed with itself while the
/// pixels disagreed. The body is now placed arithmetically from measured string widths,
/// which makes the failure inexpressible and makes it checkable here.
final class PanelLayoutTests: XCTestCase {
    private var panel: HUDPanel!
    private var store: LearningStore!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyhud-layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LearningStore(directory: dir)
        panel = HUDPanel()
        panel.learning = store
        KeyboardLayout.load()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func shortcut(_ title: String, _ key: String) -> Shortcut {
        Shortcut(path: ["ファイル", title], mods: [.command], keyLabel: key, source: .char,
                 element: AXUIElementCreateApplication(0), enabled: true)
    }

    private func model(_ items: [Shortcut]) -> PanelContent {
        PanelContent.resolve(appName: "TestApp", appKey: "test", mods: [.command],
                             sections: [MenuSection(name: "ファイル", items: items)],
                             learning: store, hideDisabled: true, hideMastered: false)
    }

    private func keymapMode() {
        var s = store.settings
        s.layoutMode = "keymap"
        store.settings = s
    }

    /// The property the rewrite buys: a run of text is placed at a position derived from
    /// its own measured width, so it cannot be given less room than it draws in.
    func testEveryTextFitsInsideThePanel() {
        let layout = panel.layoutForTesting(model([
            shortcut("サーバへ接続…", "K"),
            shortcut("Minimize", "M"),
            shortcut("取り消す – 新規フォルダ", "Z"),
            shortcut("新規Finderウインドウ", "N"),
        ]))
        let overflowing = layout.texts.filter { $0.origin.x + $0.width > layout.size.width + 0.5 }
        XCTAssertEqual(overflowing.map(\.string), [],
                       "text placed past the panel edge is text the user cannot read")
        XCTAssertTrue(layout.texts.contains { $0.string == "Minimize" },
                      "the full title must be present, not a truncated stand-in")
    }

    func testTitlesAreNeverShortenedInTheLayout() {
        let titles = ["Minimize", "コピー", "貼り付け", "Hide Claude", "サーバへ接続…"]
        for t in titles { store.noteKeyboardUse(app: "test", path: ["ファイル", t], assisted: false) }
        let layout = panel.layoutForTesting(model([
            shortcut("Minimize", "M"), shortcut("コピー", "C"), shortcut("貼り付け", "V"),
            shortcut("Hide Claude", "H"), shortcut("サーバへ接続…", "K"),
        ]))
        for t in titles {
            XCTAssertTrue(layout.texts.contains { $0.string == t }, "\(t) is missing or shortened")
        }
    }

    /// Grouping is checked by where things are placed, not by a caption naming the
    /// group. The captions are gone — the gauges say which column is which — so a test
    /// that looked for their text was testing the label, never the layout.
    func testColumnsAreSplitByLearningState() {
        // Driven from a keyboard use. This used to be a mouse pick, which put the item in
        // its own column via the orange to-learn state — the display that was removed, so
        // a mouse pick now leaves both rows in the same column and the test proved nothing
        // about columns.
        store.noteKeyboardUse(app: "test", path: ["ファイル", "サーバへ接続…"], assisted: false)
        let layout = panel.layoutForTesting(model([
            shortcut("サーバへ接続…", "K"),
            shortcut("新規タブ", "T"),
        ]))
        guard let learning = layout.texts.first(where: { $0.string == "サーバへ接続…" }),
              let unused = layout.texts.first(where: { $0.string == "新規タブ" }) else {
            return XCTFail("both rows should be placed")
        }
        XCTAssertGreaterThan(abs(learning.origin.x - unused.origin.x), 40,
                             "a mouse-picked item and an untouched one belong in different columns")
    }

    /// The state columns shipped in list mode only; the keymap legend kept its own
    /// grouping and looked, correctly, like the feature had not been implemented.
    func testKeymapLegendIsAlsoSplitByLearningState() {
        keymapMode()
        // Driven from a keyboard use. This used to be a mouse pick, which put the item in
        // its own column via the orange to-learn state — the display that was removed, so
        // a mouse pick now leaves both rows in the same column and the test proved nothing
        // about columns.
        store.noteKeyboardUse(app: "test", path: ["ファイル", "サーバへ接続…"], assisted: false)
        let layout = panel.layoutForTesting(model([
            shortcut("サーバへ接続…", "K"),
            shortcut("新規タブ", "T"),
        ]))
        guard let learning = layout.texts.first(where: { $0.string == "サーバへ接続…" }),
              let unused = layout.texts.first(where: { $0.string == "新規タブ" }) else {
            return XCTFail("both rows should be placed")
        }
        XCTAssertGreaterThan(abs(learning.origin.x - unused.origin.x), 40,
                             "keymap mode must group into the same columns as the list")
        XCTAssertNotNil(layout.board, "keymap mode must place the board")
        XCTAssertFalse(layout.texts.contains { $0.string.contains("光っているキー") },
                       "the old grouping should be gone, not layered on top")
    }

    /// Rows of one column share an x and stack downward. Previously this was checked
    /// against a caption's position; captions are gone, and the rows themselves are the
    /// thing that has to line up anyway.
    func testRowsInAColumnShareAnEdgeAndStack() {
        let layout = panel.layoutForTesting(model([
            shortcut("新規タブ", "T"), shortcut("検索", "F"),
            shortcut("設定…", ","), shortcut("表示オプション", "J"),
        ]))
        let titles = ["新規タブ", "検索", "設定…", "表示オプション"]
            .compactMap { t in layout.texts.first { $0.string == t } }
        XCTAssertEqual(titles.count, 4)
        let xs = Set(titles.map { ($0.origin.x * 10).rounded() })
        XCTAssertEqual(xs.count, 1, "one column, one left edge")
        let ys = titles.map(\.origin.y).sorted()
        for (a, b) in zip(ys, ys.dropFirst()) {
            XCTAssertGreaterThan(b - a, 4, "rows must not overlap")
            XCTAssertLessThan(b - a, 60, "nor drift apart")
        }
    }

    /// The cap on title width is what keeps one pathological menu entry from sizing the
    /// whole panel.
    func testAbsurdlyLongTitleIsCapped() {
        let layout = panel.layoutForTesting(model([shortcut(String(repeating: "長", count: 200), "L")]))
        XCTAssertLessThan(layout.size.width, 1200)
    }

    /// A panel is drawn while a key is held; the old constraint-solving path was measured
    /// at 72ms for 27 rows and 338ms for 120.
    func testLayoutOfALargeMenuIsFast() {
        let items = (0..<120).map { shortcut("メニュー項目 \($0)", "A") }
        let content = model(items)
        let began = Date()
        for _ in 0..<10 { _ = panel.layoutForTesting(content) }
        let msPerLayout = Date().timeIntervalSince(began) * 100
        XCTAssertLessThan(msPerLayout, 30, "the warm path must stay well under a frame")
    }
}

extension PanelLayoutTests {
    /// Holding a modifier whose bindings all need a second one leaves no rows. The panel
    /// still has to show the header and the bar that says where those bindings are.
    func testPanelWithNoRowsStillHasHeightForItsHeaderAndBar() {
        let content = PanelContent.resolve(
            appName: "TestApp", appKey: "test", mods: [.control],
            sections: [MenuSection(name: "m", items: [
                Shortcut(path: ["m", "a"], mods: [.control, .command], keyLabel: "A",
                         source: .char, element: AXUIElementCreateApplication(0), enabled: true),
            ])],
            learning: store, hideDisabled: true, hideMastered: false)

        let layout = panel.layoutForTesting(content)
        XCTAssertTrue(content.isEmpty)
        XCTAssertGreaterThan(layout.size.height, 60, "an empty body still needs its header")
        XCTAssertTrue(layout.texts.contains { $0.string.contains("TestApp") })
        // The real invariant is that everything drawn fits, not that the panel reaches
        // some arbitrary width — with two chips and a title it is legitimately narrow.
        let overflowing = layout.texts.filter { $0.origin.x + $0.width > layout.size.width + 0.5 }
        XCTAssertEqual(overflowing.map(\PanelLayout.Text.string), [])
    }
}

extension PanelLayoutTests {
    /// The two things called fn.
    ///
    /// ⌥⌘↑ is typed here as ⌥⌘ plus the keyboard's own fn+`[`. The panel used to print
    /// that as "fn ⌥ ⌘ [", which put a firmware layer in the run of keys you hold and made
    /// it indistinguishable from the fn *modifier* — the one this keyboard can never send.
    /// The chord now says what macOS says, and the board says where the key is.
    func testFnLayerIsNotWrittenIntoTheChord() {
        keymapMode()
        let up = Shortcut(path: ["編集", "カーソルを上に挿入"], mods: [.command],
                          keyLabel: "↑", source: .char,
                          element: AXUIElementCreateApplication(0), enabled: true)
        let layout = panel.layoutForTesting(model([up, shortcut("保存", "S")]))

        XCTAssertTrue(layout.texts.contains { $0.string == "↑" },
                      "the row names the key macOS names")
        XCTAssertFalse(layout.texts.contains { $0.string == "fn" },
                       "no fn in the chord: nothing here is a held fn")
        XCTAssertFalse(layout.texts.contains { $0.string == "[" },
                       "nor the cap it happens to sit on — that is the board's job")
    }

    /// The modifier fn is a real thing on keyboards that have one, and it still belongs in
    /// the chord when a binding needs it.
    func testFnModifierIsStillWrittenIntoTheChord() {
        let tile = Shortcut(path: ["ウインドウ", "左に移動"], mods: [.function, .control],
                            keyLabel: "←", source: .char,
                            element: AXUIElementCreateApplication(0), enabled: true)
        let content = PanelContent.resolve(
            appName: "TestApp", appKey: "test", mods: [.function, .control],
            sections: [MenuSection(name: "ウインドウ", items: [tile])],
            learning: store, hideDisabled: true, hideMastered: false,
            canTypeFunctionModifier: true)
        let layout = panel.layoutForTesting(content)
        XCTAssertTrue(layout.texts.contains { $0.string == "fn" })
    }
}

extension PanelLayoutTests {
    /// The keyboard is a picture of an object. Against the left edge of a panel that a
    /// long menu title has made wider than the board, it read as a misplaced element.
    func testTheBoardIsCentredWhateverDrivesThePanelWidth() {
        keymapMode()
        for items in [[shortcut("保存", "S")],
                      [shortcut(String(repeating: "長い項目名", count: 20), "S")]] {
            let layout = panel.layoutForTesting(model(items))
            guard let board = layout.board else { return XCTFail("keymap mode drew no board") }
            let boardWidth = KeyboardLayout.widthUnits * board.unit
            XCTAssertEqual(board.origin.x + boardWidth / 2, layout.size.width / 2, accuracy: 1,
                           "the board's centre must be the panel's centre")
            XCTAssertGreaterThanOrEqual(board.origin.x, 0)
        }
    }

    /// Centring one block and leaving the others against the left edge looks like the
    /// accident rather than the intent, so every block moves.
    func testEveryBlockIsCentred() {
        keymapMode()
        let layout = panel.layoutForTesting(model([
            shortcut(String(repeating: "長い項目名", count: 20), "S"),
            shortcut("保存", "T"),
        ]))
        let mid = layout.size.width / 2
        guard let title = layout.texts.first(where: { $0.string.contains("TestApp") }) else {
            return XCTFail("no header")
        }
        XCTAssertEqual(title.origin.x + title.width / 2, mid, accuracy: 2)
    }

    /// Centring must not push anything off either edge.
    func testCentringKeepsEverythingInsideThePanel() {
        keymapMode()
        let layout = panel.layoutForTesting(model([
            shortcut("保存", "S"), shortcut("開く", "O"), shortcut("閉じる", "W"),
        ]))
        for t in layout.texts {
            XCTAssertGreaterThanOrEqual(t.origin.x, 0, "\(t.string) starts left of the panel")
            XCTAssertLessThanOrEqual(t.origin.x + t.width, layout.size.width + 0.5,
                                     "\(t.string) runs past the right edge")
        }
        if let board = layout.board {
            XCTAssertLessThanOrEqual(board.origin.x + KeyboardLayout.widthUnits * board.unit,
                                     layout.size.width + 0.5)
        }
    }
}

extension PanelLayoutTests {
    /// A page smaller than the hold's frame still centres on the frame.
    ///
    /// Without this the panel is pinned but its contents are not: narrowing from ⌘ to ⇧⌘
    /// would centre the board on the *page's* width, sliding it inside a window that never
    /// moved — the same noise, one level down.
    func testASmallPageCentresOnTheHoldFrameNotOnItself() {
        keymapMode()
        let wide = panel.layoutForTesting(model([
            shortcut(String(repeating: "長い項目名", count: 12), "S"),
            shortcut("保存", "T"),
        ]))
        let floor = CGSize(width: wide.size.width, height: 0)
        let narrow = panel.layoutForTesting(model([shortcut("保存", "T")]), minimum: floor)

        XCTAssertEqual(narrow.size.width, wide.size.width, accuracy: 0.5)
        guard let a = wide.board, let b = narrow.board else { return XCTFail("no board") }
        XCTAssertEqual(a.origin.x, b.origin.x, accuracy: 1,
                       "the board must sit at the same x on every page of one hold")
    }

    /// Only the width is pinned. Pinning the height too padded every short page out to the
    /// tallest one's size, which is blank space where the panel should simply have ended;
    /// the top-left corner is what actually has to hold still, and everything that must not
    /// move — header, modifier bar, board — is above the rows.
    func testTheHeightStillFollowsTheRows() {
        keymapMode()
        let many = panel.layoutForTesting(model(
            (0..<12).map { shortcut("項目\($0)", "S") }))
        let one = panel.layoutForTesting(model([shortcut("保存", "T")]),
                                         minimum: CGSize(width: many.size.width, height: 0))

        XCTAssertEqual(one.size.width, many.size.width, accuracy: 0.5, "width is pinned")
        XCTAssertLessThan(one.size.height, many.size.height, "height is not")

        // Everything above the rows is at the same y on both pages.
        for text in one.texts where text.string.contains("TestApp") {
            let other = many.texts.first { $0.string.contains("TestApp") }
            XCTAssertEqual(text.origin.y, other?.origin.y ?? -1, accuracy: 0.5)
        }
        XCTAssertEqual(one.board?.origin.y ?? -1, many.board?.origin.y ?? -2, accuracy: 0.5)
    }

    /// The floor only ever grows the panel.
    func testAFloorSmallerThanTheContentIsIgnored() {
        let natural = panel.layoutForTesting(model([shortcut("保存", "S")]))
        let floored = panel.layoutForTesting(model([shortcut("保存", "S")]),
                                             minimum: CGSize(width: 10, height: 10))
        XCTAssertEqual(natural.size, floored.size)
    }
}

/// Where the window itself goes.
///
/// The panel's *contents* have been arithmetic-with-tests for a while; the window holding
/// them was hand-placed geometry with no test, and it opened in the bottom-left corner on
/// the first hold after launch. A brand-new NSPanel is created at `.zero`, so it is on no
/// screen, and `NSScreen.main` is defined in terms of the window with keyboard focus —
/// which this app never has, by design.
final class PanelPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1710, height: 999)

    /// Where the panel actually ends up: the anchor, then the placement.
    ///
    /// This used to apply `min(size, visible)` itself before comparing — a clamp the
    /// production code did not have — so `testAnOversizedPanelIsClampedInsideTheScreen`
    /// was asserting behaviour that existed only in the test helper. The panel really did
    /// hang off the bottom of the display.
    private func place(_ size: CGSize, in visible: CGRect) -> CGRect {
        let anchor = HUDPanel.anchor(for: size, in: visible)
        let origin = HUDPanel.origin(for: size, anchoredAt: anchor, in: visible)
        return CGRect(origin: origin, size: size)
    }

    func testAnOrdinaryPanelIsCentred() {
        let frame = place(CGSize(width: 700, height: 500), in: screen)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, screen.midY, accuracy: 1)
    }

    /// The failure the user saw. Zero is what the size is before anything has been
    /// measured, and it must not put the window in a corner.
    func testAZeroSizedPanelStillLandsInTheMiddle() {
        let a = HUDPanel.anchor(for: .zero, in: screen)
        XCTAssertEqual(a.x, screen.midX, accuracy: 1)
        XCTAssertEqual(a.y, screen.midY, accuracy: 1)
        XCTAssertNotEqual(a, .zero, "the bottom-left corner is never the answer")
    }

    /// A panel taller or wider than the display is pinned to it rather than hanging off.
    /// A page larger than the display starts at its top-left corner rather than hanging
    /// off the bottom. It cannot be made to fit — but which rows are lost is then the
    /// user's scroll, not the window server's arithmetic.
    func testAnOversizedPanelStartsInsideTheScreen() {
        for size in [CGSize(width: 4000, height: 500),
                     CGSize(width: 700, height: 4000),
                     CGSize(width: 4000, height: 4000)] {
            let frame = place(size, in: screen)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX - 0.5, "\(size) left edge")
            XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 0.5, "\(size) top edge")
        }
    }

    /// The case that actually happens: the layout trades height for width when both
    /// budgets cannot be met, so a page can be taller than the frame the anchor was
    /// computed for. Placing it unclamped put the last rows below the screen.
    func testAPageTallerThanItsHoldFrameStaysOnScreen() {
        let anchor = HUDPanel.anchor(for: CGSize(width: 700, height: 400), in: screen)
        let origin = HUDPanel.origin(for: CGSize(width: 700, height: 950),
                                     anchoredAt: anchor, in: screen)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY - 0.5,
                                    "the bottom rows would be off the display")
        XCTAssertLessThanOrEqual(origin.y + 950, screen.maxY + 0.5)
    }

    /// And an ordinary page hangs from the anchor exactly, which is the whole point of
    /// pinning the corner.
    func testAnOrdinaryPageHangsFromTheAnchor() {
        let anchor = HUDPanel.anchor(for: CGSize(width: 700, height: 800), in: screen)
        for height in [800.0, 500.0, 200.0] {
            let origin = HUDPanel.origin(for: CGSize(width: 700, height: height),
                                         anchoredAt: anchor, in: screen)
            XCTAssertEqual(origin.y + height, anchor.y, accuracy: 0.5,
                           "a \(height)pt page must keep the same top edge")
        }
    }

    /// A second display sits at a non-zero origin, and can be to the left or below the
    /// main one, which means negative coordinates.
    func testAScreenAwayFromTheOriginIsHandled() {
        let external = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        let frame = place(CGSize(width: 700, height: 500), in: external)
        XCTAssertEqual(frame.midX, external.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, external.midY, accuracy: 1)
    }

    /// The tallest page a hold can reach is what the corner is chosen for, so that page
    /// is the one that ends up centred.
    func testTheAnchorCentresTheTallestPage() {
        let a = HUDPanel.anchor(for: CGSize(width: 700, height: 800), in: screen)
        XCTAssertEqual(a.y, screen.midY + 400, accuracy: 1)
    }
}

extension PanelLayoutTests {
    /// Splitting a tall list into columns trades height for width, so capping only the
    /// height moved the overflow instead of removing it. Measured worst case before this:
    /// twenty bindings at 特大 on a 1440pt laptop became ten columns and about 2500pt.
    func testThePanelIsNeverWiderThanItsCap() {
        keymapMode()
        let cap: CGFloat = 900
        var b = PanelLayoutBuilder(style: PanelStyle(scale: 1, theme: .builtin),
                                   learning: store, showProgress: false, keymap: false,
                                   currentAppKey: "test", appIcon: nil)
        b.maxWidth = cap
        b.maxHeight = 400

        let items = (0..<40).map {
            shortcut("とても長い項目名がここにずらりと並んでいる場合の \($0)", "S")
        }
        let layout = b.build(model(items), allSections: [])
        XCTAssertLessThanOrEqual(layout.size.width, cap + 0.5,
                                 "the reflow widened it past the display")
        // Forty rows cannot fit 400pt of height inside 900pt of width. Something has to
        // give, and it is the height: a taller panel is still one panel, while the columns
        // past the right edge are simply not there.
        XCTAssertGreaterThan(layout.size.height, b.maxHeight,
                             "and the trade must be visible, not silent")
        for text in layout.texts {
            XCTAssertLessThanOrEqual(text.origin.x + text.width, layout.size.width + 0.5,
                                     "\(text.string) runs past the right edge")
        }
    }

    /// A panel that already fits is left alone — the retry must not shorten titles for
    /// nothing.
    func testAPanelInsideTheCapIsNotNarrowed() {
        var b = PanelLayoutBuilder(style: PanelStyle(scale: 1, theme: .builtin),
                                   learning: store, showProgress: false, keymap: false,
                                   currentAppKey: "test", appIcon: nil)
        b.maxWidth = 4000
        let items = [shortcut("保存", "S"), shortcut("開く", "O")]
        let layout = b.build(model(items), allSections: [])
        for title in ["保存", "開く"] {
            XCTAssertTrue(layout.texts.contains { $0.string == title }, "\(title) was shortened")
        }
    }

    /// What the panel reports as consulted has to be exactly what it drew, or a binding
    /// the user was never shown is treated as one they looked up — which then denies them
    /// credit for recalling it.
    func testTheReportedPathsAreTheDrawnRows() {
        let content = model([shortcut("保存", "S"), shortcut("開く", "O")])
        _ = panel.layoutForTesting(content)
        panel.show(appName: "TestApp", appKey: "test",
                   sections: [MenuSection(name: "ファイル", items: content.rows.map(\.shortcut))],
                   mods: [.command])
        defer { panel.hide() }
        XCTAssertEqual(Set(panel.shownPaths.map { $0.joined(separator: "/") }),
                       Set(content.rows.map { $0.path.joined(separator: "/") }))
    }
}

extension PanelLayoutTests {
    /// "No cap" is the default, and it must not be a crash. `Int(Double.greatest… / 26)`
    /// traps rather than saturating.
    func testAnUncappedBuilderDoesNotTrap() {
        let b = PanelLayoutBuilder(style: PanelStyle(scale: 1, theme: .builtin),
                                   learning: store, showProgress: false, keymap: false,
                                   currentAppKey: "test", appIcon: nil)
        let layout = b.build(model([shortcut("保存", "S")]), allSections: [])
        XCTAssertGreaterThan(layout.size.height, 0)
    }
}

extension PanelLayoutTests {
    /// The bug the user actually saw: after a preview render, the next real hold opened in
    /// the bottom-left corner of the screen.
    ///
    /// `show()` treats an existing hold as a continuation and skips positioning. A preview
    /// left one behind, so the panel was never placed and drew at the `contentRect: .zero`
    /// origin. The state is one value now and the offscreen path builds its own; this pins
    /// that it does not publish it.
    func testAnOffscreenRenderLeavesNoHoldBehind() {
        let menus = [MenuSection(name: "ファイル", items: [shortcut("保存", "S"),
                                                          shortcut("開く", "O")])]
        XCTAssertFalse(panel.hasActiveHold)
        // The render has to have happened, or the assertion below is about nothing: an
        // early `return nil` would satisfy it just as well as a correct implementation.
        XCTAssertNotNil(panel.renderPNG(appName: "TestApp", appKey: "test",
                                        sections: menus, mods: [.command]))
        XCTAssertFalse(panel.hasActiveHold,
                       "a preview must not look like a hold in progress to the next hold")
    }

    /// The other half, and the one that actually bit: a preview fired *during* a hold.
    func testAPreviewDoesNotDisturbALiveHold() {
        let live = [MenuSection(name: "ファイル", items: [shortcut("保存", "S"),
                                                          shortcut("開く", "O")])]
        panel.show(appName: "LiveApp", appKey: "live", sections: live, mods: [.command])
        defer { panel.hide() }
        let before = panel.shownPaths

        _ = panel.renderPNG(appName: "OtherApp", appKey: "other",
                            sections: [MenuSection(name: "m", items: [shortcut("別", "K")])],
                            mods: [.command])

        XCTAssertTrue(panel.hasActiveHold, "the live hold must still be live")
        panel.rerender(mods: [.command])
        XCTAssertEqual(panel.shownPaths, before,
                       "the live panel must still be showing the app the user is holding in")
    }

    /// A hold belongs to one app.
    ///
    /// Scrapes land asynchronously — p99 143ms against a 250ms threshold — so a slow app's
    /// results can arrive after the user has moved on and started a fresh hold. Deciding
    /// continuation by "a hold exists" rather than by identity meant the new app's own
    /// results were then discarded as a repaint of the old one, for the rest of the hold.
    func testASecondAppStartsItsOwnHold() {
        panel.show(appName: "First", appKey: "first",
                   sections: [MenuSection(name: "m", items: [shortcut("一番目", "A")])],
                   mods: [.command])
        defer { panel.hide() }
        XCTAssertEqual(panel.shownPaths.map { $0.joined(separator: "/") }, ["ファイル/一番目"])

        panel.show(appName: "Second", appKey: "second",
                   sections: [MenuSection(name: "m", items: [shortcut("二番目", "B")])],
                   mods: [.command])
        XCTAssertEqual(panel.shownPaths.map { $0.joined(separator: "/") }, ["ファイル/二番目"],
                       "the second app's bindings, not a repaint of the first")
    }

    /// And a hold releases everything it took.
    func testHidingEndsTheHold() {
        panel.show(appName: "TestApp", appKey: "test",
                   sections: [MenuSection(name: "ファイル", items: [shortcut("保存", "S")])],
                   mods: [.command])
        XCTAssertTrue(panel.hasActiveHold)
        panel.hide()
        XCTAssertFalse(panel.hasActiveHold)
        XCTAssertEqual(panel.shownPaths, [], "and reports nothing as currently on screen")
        panel.rerender(mods: [.command])
        XCTAssertEqual(panel.shownPaths, [], "a released hold cannot be repainted")
    }
}
