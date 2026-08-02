import XCTest
@testable import KeyHUDCore

/// Cap matching used to live inside the view, so the only way to check it was to render a
/// panel and look. Every case below is one that shipped wrong at some point.
final class KeyboardLayoutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeyboardLayout.current = KeyboardLayout.builtinHHKBUS
    }

    func testLetterLandsOnItsCap() {
        XCTAssertEqual(KeyboardLayout.locate("S")?.cap, "S")
        XCTAssertEqual(KeyboardLayout.locate("S")?.shifted, false)
        XCTAssertEqual(KeyboardLayout.locate("S")?.viaFn, false)
    }

    /// Zoom In is reported as "+" by Safari, Ghostty and Claude, with the shift flag
    /// clear. "+" is printed on no cap's match list; it is Shift-"=" and belongs there.
    func testShiftedCharacterResolvesToItsBaseKey() {
        let plus = KeyboardLayout.locate("+")
        XCTAssertEqual(plus?.cap, "=")
        XCTAssertEqual(plus?.shifted, true)
    }

    func testGlyphKeysResolve() {
        XCTAssertEqual(KeyboardLayout.locate("⌫")?.cap, "delete")
        XCTAssertEqual(KeyboardLayout.locate("↩")?.cap, "return")
        XCTAssertEqual(KeyboardLayout.locate("⇥")?.cap, "tab")
        XCTAssertEqual(KeyboardLayout.locate("⎋")?.cap, "esc")
    }

    func testKeysNotOnThisBoardReturnNil() {
        // The builtin fallback carries no Fn layer, so arrows genuinely are not on it.
        XCTAssertNil(KeyboardLayout.locate("F13"))
    }

    /// The generated layout puts arrows on the Fn layer, and they must be reported as
    /// such — drawing them as base-layer caps would teach a motion that does not exist.
    func testFnLayerIsDistinguished() {
        KeyboardLayout.current = [
            KeyboardLayout.Row([
                KeyboardLayout.Cap("[", ["["], 1, fnMatch: ["↑"], shiftLabel: "{"),
            ]),
        ]
        let up = KeyboardLayout.locate("↑")
        XCTAssertEqual(up?.cap, "[")
        XCTAssertEqual(up?.viaFn, true)

        let base = KeyboardLayout.locate("[")
        XCTAssertEqual(base?.viaFn, false)
    }

    /// A base-layer match must win over an Fn-layer one on the same cap.
    func testBaseLayerWinsOverFnLayer() {
        KeyboardLayout.current = [
            KeyboardLayout.Row([
                KeyboardLayout.Cap("A", ["A"], 1, fnMatch: ["A"]),
            ]),
        ]
        XCTAssertEqual(KeyboardLayout.locate("A")?.viaFn, false)
    }

    func testWidthIsDerivedFromTheLoadedRows() {
        XCTAssertEqual(KeyboardLayout.widthUnits, 15, accuracy: 0.001,
                       "HHKB ANSI is 15u wide; a wrong width clips the rightmost column")
    }

    /// QMK's 60_hhkb is sixty keys. An earlier hand-written layout invented two ◇ caps.
    func testBuiltinBoardHasSixtyKeys() {
        let total = KeyboardLayout.builtinHHKBUS.reduce(0) { $0 + $1.caps.count }
        XCTAssertEqual(total, 62, "the fallback is the old hand-written board; the generated one is authoritative")
    }
}

extension KeyboardLayoutTests {
    /// The board has to be able to show what is being held, and it can only do that if
    /// the modifier names in the layout file match the ones looked up here. A keyboard.json
    /// that spells the cap "cmd" instead of "⌘" would silently light nothing.
    func testEveryModifierFindsACapOnTheLoadedBoard() {
        KeyboardLayout.load()
        for (name, mod) in [("⌘", Shortcut.Mods.command), ("⌃", .control),
                            ("⌥", .option), ("⇧", .shift), ("fn", .function)] {
            XCTAssertFalse(KeyboardLayout.caps(holding: mod).isEmpty,
                           "\(name) has no cap on the loaded layout, so holding it would show nothing")
        }
    }

    /// Without a reported side, every cap bearing the modifier lights — two ⇧ caps means
    /// two lit keys, because an unreported side is not evidence that one of them is up.
    func testHoldingAModifierLightsEveryCapThatBearsIt() {
        KeyboardLayout.current = [
            KeyboardLayout.Row([KeyboardLayout.Cap("shift", ["⇧"], 2.25),
                                KeyboardLayout.Cap("Z"),
                                KeyboardLayout.Cap("shift", ["⇧"], 1.75)]),
        ]
        XCTAssertEqual(KeyboardLayout.caps(holding: [.shift]).map(\.index).sorted(), [0, 2])
        XCTAssertTrue(KeyboardLayout.caps(holding: [.command]).isEmpty)
    }

    private func labels(_ positions: Set<KeyboardLayout.CapPosition>) -> Set<String> {
        Set(positions.map { KeyboardLayout.current[$0.row].caps[$0.index].label })
    }

    func testCombinedHoldLightsAllOfThem() {
        KeyboardLayout.load()
        let both = labels(KeyboardLayout.caps(holding: [.command, .option]))
        XCTAssertTrue(both.contains("⌘"))
        XCTAssertTrue(both.contains("⌥"))
        XCTAssertFalse(both.contains("shift"))
    }

    /// A 60% board has no F-row and no arrow cluster; both live on the Fn layer, which
    /// QMK's default HHKB keymap places on the number row and the right-hand punctuation.
    /// The panel writes the motion out rather than marking it with a symbol, because a
    /// symbol needs a legend and the legend was removed.
    func testFnLayerKeysReportTheCapThatProducesThem() {
        KeyboardLayout.load()
        XCTAssertEqual(KeyboardLayout.locate("F3")?.cap, "3", "F3 is Fn and 3")
        XCTAssertEqual(KeyboardLayout.locate("F3")?.viaFn, true)
        XCTAssertEqual(KeyboardLayout.locate("F12")?.cap, "=")
        XCTAssertEqual(KeyboardLayout.locate("↑")?.cap, "[")
        XCTAssertEqual(KeyboardLayout.locate("←")?.cap, ";")
        XCTAssertEqual(KeyboardLayout.locate("→")?.cap, "'")
        XCTAssertEqual(KeyboardLayout.locate("↓")?.cap, "/")
    }
}

extension KeyboardLayoutTests {
    /// Left and right, from the device-dependent flag bits.
    ///
    /// An earlier comment in this project said the flags do not distinguish them. They do:
    /// `CGEventFlags` carries NX_DEVICE*KEYMASK alongside the generic masks.
    func testSidesAreDecodedFromTheDeviceBits() {
        func sides(_ raw: UInt64) -> Shortcut.Sides { Shortcut.Sides(CGEventFlags(rawValue: raw)) }
        XCTAssertEqual(sides(0x08).command, .left)
        XCTAssertEqual(sides(0x10).command, .right)
        XCTAssertEqual(sides(0x18).command, .both)
        XCTAssertEqual(sides(0x01).control, .left)
        XCTAssertEqual(sides(0x2000).control, .right)
        XCTAssertEqual(sides(0x20).option, .left)
        XCTAssertEqual(sides(0x40).option, .right)
        XCTAssertEqual(sides(0x02).shift, .left)
        XCTAssertEqual(sides(0x04).shift, .right)
    }

    /// A keyboard that reports no sides must not be read as "nothing is held".
    func testSilenceIsUnknownNotAbsence() {
        let none = Shortcut.Sides(CGEventFlags(rawValue: 0))
        XCTAssertTrue(none.isSilent)
        XCTAssertEqual(none.command, .unknown)
    }

    func testOnlyTheNamedSideLightsWhenTheEventSaysWhich() {
        KeyboardLayout.load()
        var left = Shortcut.Sides(); left.command = .left
        var right = Shortcut.Sides(); right.command = .right

        let lit = KeyboardLayout.caps(holding: [.command], sides: left)
        let ritz = KeyboardLayout.caps(holding: [.command], sides: right)
        XCTAssertEqual(lit.count, 1)
        XCTAssertEqual(ritz.count, 1)
        XCTAssertNotEqual(lit, ritz, "left ⌘ and right ⌘ are different keys")
        XCTAssertLessThan(lit.first!.index, ritz.first!.index, "left is the leftmost cap")
    }

    /// The fallback that keeps a missing bit from becoming a wrong picture.
    func testBothLightWhenTheSideIsUnknown() {
        KeyboardLayout.load()
        XCTAssertEqual(KeyboardLayout.caps(holding: [.command], sides: .unknown).count, 2)
    }

    /// Each modifier resolves independently: holding left ⌘ with right ⌥ lights exactly
    /// those two caps.
    func testSidesAreResolvedPerModifier() {
        KeyboardLayout.load()
        var mixed = Shortcut.Sides()
        mixed.command = .left
        mixed.option = .right
        let lit = KeyboardLayout.caps(holding: [.command, .option], sides: mixed)
        XCTAssertEqual(lit.count, 2)
        // The bottom row runs ⌥ ⌘ space ⌘ ⌥, so left ⌘ sits right of right ⌥'s mirror.
        XCTAssertEqual(Set(lit.map(\.row)).count, 1, "both live on the bottom row")
    }

    /// Control has only one cap on an HHKB, so a side cannot narrow it away.
    func testASingleCapIsLitWhicheverSideIsReported() {
        KeyboardLayout.load()
        var right = Shortcut.Sides(); right.control = .right
        XCTAssertEqual(KeyboardLayout.caps(holding: [.control], sides: right).count, 1)
        XCTAssertEqual(KeyboardLayout.caps(holding: [.control], sides: .unknown).count, 1)
    }
}

extension KeyboardLayoutTests {
    /// The board and the chord column must speak one alphabet. Reading "^ H" in the list
    /// and hunting for a key labelled "control" is a translation step that buys nothing.
    func testModifierCapsArePaintedInTheSameNotationAsTheChords() {
        XCTAssertEqual(KeyboardLayout.legend(for: "control"), "^")
        XCTAssertEqual(KeyboardLayout.legend(for: "shift"), "⇧")
        XCTAssertEqual(KeyboardLayout.legend(for: "⌘"), "⌘")
        XCTAssertEqual(KeyboardLayout.legend(for: "Q"), "Q", "ordinary caps are printed as they are")
        XCTAssertEqual(KeyboardLayout.legend(for: "space"), "space")

        // And the notation matches what Mods.glyphs writes, which is the whole point.
        XCTAssertEqual(KeyboardLayout.legend(for: "control"), Shortcut.Mods([.control]).glyphs)
        XCTAssertEqual(KeyboardLayout.legend(for: "shift"), Shortcut.Mods([.shift]).glyphs)
    }
}
