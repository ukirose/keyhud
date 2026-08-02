import XCTest
import ApplicationServices
@testable import KeyHUDCore

/// Matching a typed chord to a menu shortcut, across the several ways a key can be named.
///
/// Usage used to be inferred only from kAXMenuItemSelected. An app is under no obligation
/// to emit it: Electron binds more than one accelerator per command and only one is the
/// menu item, which is why ⌘− was recorded as practice for weeks while ⌘+ never was. The
/// fallback reads the keystroke, and to be useful it has to know that the "+" printed in
/// the menu and the "=" under the finger are the same key.
///
/// This file used to test neither of those things. The matcher was a private method on
/// AppDelegate, so every case here called `KeyboardLayout.locate` or `MenuScraper.baseKey`
/// instead — and one of them asserted only that two distinct keys stay distinct, which
/// holds when `locate` returns nil for everything. It passed with the layout deleted.
final class ChordMatchingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeyboardLayout.load()
    }

    private func item(_ title: String, _ mods: Shortcut.Mods, _ key: String,
                      enabled: Bool = true) -> Shortcut {
        Shortcut(path: ["表示", title], mods: mods, keyLabel: key, source: .char,
                 element: AXUIElementCreateApplication(0), enabled: enabled)
    }

    private func match(_ mods: Shortcut.Mods, _ key: String, _ items: [Shortcut]) -> String? {
        ChordMatch.find(mods: mods, key: key,
                        in: [MenuSection(name: "表示", items: items)])?.title
    }

    // MARK: - the case the fallback exists for

    /// The measured failure: Zoom In is printed "+" and typed on "=", so a keystroke of
    /// ⌘= never matched the ⌘+ menu item and the shortcut looked unused for weeks while
    /// its neighbour ⌘− accumulated practice.
    func testAShiftedLegendIsCreditedByTheKeyThatProducesIt() {
        let items = [item("拡大", [.command], "+"), item("縮小", [.command], "-")]
        XCTAssertEqual(match([.command], "=", items), "拡大")
        XCTAssertEqual(match([.command, .shift], "=", items), "拡大",
                       "typing + means holding Shift, which the menu never recorded")
        XCTAssertEqual(match([.command], "-", items), "縮小")
    }

    /// Adjacent keys are not the same key. This is the assertion the old file thought it
    /// was making; run through the matcher it can actually fail.
    func testTheNeighbouringKeyIsNotCredited() {
        let items = [item("拡大", [.command], "+")]
        XCTAssertNil(match([.command], "-", items))
        XCTAssertNil(match([.command], "0", items))
    }

    // MARK: - modifiers

    func testTheModifiersHaveToMatch() {
        let items = [item("保存", [.command], "S"),
                     item("別名で保存", [.command, .shift], "S")]
        XCTAssertEqual(match([.command], "S", items), "保存")
        XCTAssertEqual(match([.command, .shift], "S", items), "別名で保存")
        XCTAssertNil(match([.option], "S", items))
        XCTAssertNil(match([], "S", items))
    }

    /// The Shift concession is only for shifted legends. An ordinary letter binding must
    /// not be fired by a chord that adds Shift — ⇧⌘S is a different command from ⌘S, and
    /// crediting the wrong one is worse than crediting nothing.
    func testShiftIsNotForgivenForAnOrdinaryLetter() {
        let items = [item("保存", [.command], "S")]
        XCTAssertNil(match([.command, .shift], "S", items))
    }

    /// An app that binds both legends of one key to different commands. Resolution used to
    /// be "whichever the scraper walked first".
    func testAnExactMatchWinsOverTheShiftConcession() {
        let both = [item("プラス", [.command], "+"), item("イコール", [.command], "=")]
        XCTAssertEqual(match([.command], "=", both), "イコール")
        XCTAssertEqual(match([.command], "=", both.reversed()), "イコール",
                       "and it must not depend on the order the menus were walked")
        XCTAssertEqual(match([.command, .shift], "=", both), "プラス")
    }

    // MARK: - key naming

    /// Glyph-named keys must resolve, or ⌘⌫ credits nothing.
    func testGlyphKeysAreMatchedThroughTheirCap() {
        let items = [item("削除", [.command], "⌫"), item("開く", [.command], "↩")]
        XCTAssertEqual(match([.command], "⌫", items), "削除")
        XCTAssertEqual(match([.command], "↩", items), "開く")
    }

    /// The Fn layer produces an ordinary arrow keycode, so ⌘↑ is matched like any key.
    func testAnFnLayerKeyIsMatchedByWhatItProduces() {
        let items = [item("上へ", [.command], "↑")]
        XCTAssertEqual(match([.command], "↑", items), "上へ")
    }

    // MARK: - what must never be credited

    func testADisabledBindingIsNeverCredited() {
        XCTAssertNil(match([.command], "S", [item("保存", [.command], "S", enabled: false)]))
    }

    func testAnEmptyTableCreditsNothing() {
        XCTAssertNil(match([.command], "S", []))
    }

    func testAnUnboundKeyCreditsNothing() {
        XCTAssertNil(match([.command], "Q", [item("保存", [.command], "S")]))
    }

    // MARK: - crediting the system text-editing layer

    /// The measured bug: the panel prints ^A as 行頭へ, you press it, and nothing is
    /// recorded. `creditChord` matched only against the menu scrape, while the text
    /// bindings were appended to a *different* array at draw time, so every binding in the
    /// テキスト編集 section was displayed and uncountable — in every app, since the day the
    /// section was added. Confirmed against ^a in StandardKeyBinding.dict.

    private func textItem(_ name: String, _ mods: Shortcut.Mods, _ key: String) -> Shortcut {
        Shortcut(path: ["テキスト編集", name], mods: mods, keyLabel: key,
                 source: .char, element: nil, enabled: true)
    }

    /// The key is put through the same normalisation `Trigger` applies, rather than
    /// written out as the table already spells it. The first version of these tests typed
    /// a literal "a" — a lowercase chord, which Trigger cannot emit, because
    /// `normalizeTypedKey` uppercases — and so they failed against a correct
    /// implementation, on an input that does not occur.
    private func credit(_ mods: Shortcut.Mods, _ typed: String,
                        menu: [MenuSection], text: [Shortcut]) -> ChordMatch.Credit? {
        ChordMatch.credit(mods: mods, key: MenuScraper.normalizeTypedKey(typed),
                          menu: menu, text: text)
    }

    func testASystemTextBindingIsCreditedWhenNoMenuClaimsTheChord() {
        let menu = [MenuSection(name: "ファイル", items: [item("保存", [.command], "S")])]
        let hit = credit([.control], "a", menu: menu,
                         text: [textItem("行頭へ", [.control], "A")])
        XCTAssertEqual(hit?.shortcut.title, "行頭へ")
    }

    /// The negative control for the test above. If ^A were credited from an empty text
    /// table, that test would be passing on something other than the table it names.
    func testTheSameChordCreditsNothingWithoutTheTextTable() {
        let menu = [MenuSection(name: "ファイル", items: [item("保存", [.command], "S")])]
        XCTAssertNil(credit([.control], "a", menu: menu, text: []),
                     "the text table has to be what is doing the work")
    }

    /// Precedence, and the one case that cannot come out right by accident: both tables
    /// claim ^A. Crediting 行頭へ would record a command the app never ran.
    func testTheAppsOwnBindingWinsOverTheSystemOne() {
        let menu = [MenuSection(name: "編集", items: [item("行を選択", [.control], "A")])]
        let hit = credit([.control], "a", menu: menu,
                         text: [textItem("行頭へ", [.control], "A")])
        XCTAssertEqual(hit?.shortcut.title, "行を選択")
        XCTAssertFalse(hit?.needsTextFocus ?? true,
                       "a menu command is a fact about the app, not about what has focus")
    }

    /// The two cases have to be told apart, or the focus gate cannot be applied to one and
    /// not the other — which is the entire reason this returns a case rather than a
    /// Shortcut.
    func testATextBindingIsReportedAsNeedingFocus() {
        let hit = credit([.control], "a", menu: [],
                         text: [textItem("行頭へ", [.control], "A")])
        XCTAssertTrue(hit?.needsTextFocus ?? false)
    }

    func testAChordInNeitherTableCreditsNothing() {
        let menu = [MenuSection(name: "ファイル", items: [item("保存", [.command], "S")])]
        XCTAssertNil(credit([.control], "q", menu: menu,
                            text: [textItem("行頭へ", [.control], "A")]))
    }
}

/// What the keystroke actually carries, versus what the menu says.
///
/// The matcher was only ever tested with the menu's own spelling handed in as the typed
/// key — `match([.command], "⌫", …)` against an item labelled "⌫" — which makes
/// `locate(key)?.cap ?? key` and `locate(item.keyLabel)?.cap ?? item.keyLabel` literally
/// the same expression. Those cases hold whether the layout resolves anything or not, and
/// they hid the fact that `Trigger` never sends "⌫": it sends U+007F.
final class TypedKeyNormalisationTests: XCTestCase {
    override func setUp() { super.setUp(); KeyboardLayout.load() }

    /// The raw encodings `charactersIgnoringModifiers` produces, in the alphabet the menus
    /// are written in.
    func testTheRawEncodingsBecomeTheMenuGlyphs() {
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{7F}"), "⌫")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{8}"), "⌫")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{9}"), "⇥")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{D}"), "↩")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{1B}"), "⎋")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{F700}"), "↑")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{F702}"), "←")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("\u{F704}"), "F1")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("s"), "S", "ordinary keys are unchanged")
        XCTAssertEqual(MenuScraper.normalizeTypedKey("="), "=")
    }

    /// End to end: the encoding the event carries has to reach the menu item.
    ///
    /// Every one of these earned no score at all. They never graduated and sat in the
    /// to-learn column indefinitely while letter shortcuts advanced past them.
    func testAGlyphKeyChordIsCreditedFromWhatTheEventCarries() {
        let items = [
            Shortcut(path: ["ファイル", "ゴミ箱に入れる"], mods: [.command], keyLabel: "⌫",
                     source: .char, element: nil, enabled: true),
            Shortcut(path: ["移動", "内包しているフォルダ"], mods: [.command], keyLabel: "↑",
                     source: .char, element: nil, enabled: true),
            Shortcut(path: ["ファイル", "開く"], mods: [.command], keyLabel: "↩",
                     source: .char, element: nil, enabled: true),
        ]
        let sections = [MenuSection(name: "m", items: items)]

        for (raw, expected) in [("\u{7F}", "ゴミ箱に入れる"), ("\u{F700}", "内包しているフォルダ"),
                                ("\u{D}", "開く")] {
            let key = MenuScraper.normalizeTypedKey(raw)
            XCTAssertEqual(ChordMatch.find(mods: [.command], key: key, in: sections)?.title,
                           expected, "U+\(String(raw.unicodeScalars.first!.value, radix: 16))")
        }
    }

    /// The un-normalised form must not match, or the test above proves nothing.
    func testTheRawFormOnItsOwnMatchesNothing() {
        let items = [Shortcut(path: ["m", "削除"], mods: [.command], keyLabel: "⌫",
                              source: .char, element: nil, enabled: true)]
        XCTAssertNil(ChordMatch.find(mods: [.command], key: "\u{7F}",
                                     in: [MenuSection(name: "m", items: items)]),
                     "if this matched, normalisation would be doing nothing")
    }
}
