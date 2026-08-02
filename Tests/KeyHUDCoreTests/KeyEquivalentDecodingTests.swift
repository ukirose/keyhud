import XCTest
@testable import KeyHUDCore

/// The key-equivalent decoder, driven directly.
///
/// Four decoding bugs shipped in a row here, each found by a person noticing a wrong
/// label. The corpus suite was supposed to end that, but it read back a field the decoder
/// itself had written at capture time — it would have passed with the decoder deleted.
/// Now that the decision is a pure function over the four raw attributes, the branches the
/// corpus cannot reach can be tested at all.
final class KeyEquivalentDecodingTests: XCTestCase {
    private func decode(char: String? = nil, glyph: Int? = nil, vkey: Int? = nil,
                        mods: Int = 0) -> (Shortcut.Mods, String, Shortcut.Source)? {
        MenuScraper.keyEquivalent(cmdChar: char, cmdGlyph: glyph,
                                  cmdVirtualKey: vkey, cmdModifiers: mods)
    }

    func testAnOrdinaryLetter() {
        let r = decode(char: "s")
        XCTAssertEqual(r?.1, "S")
        XCTAssertEqual(r?.0, [.command])
        XCTAssertEqual(r?.2, .char)
    }

    /// An app that sets its key equivalent to a raw control byte. Returning the byte drew
    /// an empty key column and stopped the cap from ever lighting. Finder's ⌘⌫ and
    /// Chrome's ⌃⇥ both arrive this way.
    func testControlCharacters() {
        XCTAssertEqual(decode(char: "\u{8}")?.1, "⌫")
        XCTAssertEqual(decode(char: "\u{9}")?.1, "⇥")
        XCTAssertEqual(decode(char: "\u{D}")?.1, "↩")
        XCTAssertEqual(decode(char: "\u{1B}")?.1, "⎋")
    }

    /// AppKit encodes arrows and F-keys as private-use codepoints. Rendering one prints
    /// whatever the font has for an unmapped scalar — the source of the stray "?" glyphs.
    func testPrivateUseFunctionKeys() {
        XCTAssertEqual(decode(char: "\u{F700}")?.1, "↑")
        XCTAssertEqual(decode(char: "\u{F701}")?.1, "↓")
        XCTAssertEqual(decode(char: "\u{F702}")?.1, "←")
        XCTAssertEqual(decode(char: "\u{F703}")?.1, "→")
        XCTAssertEqual(decode(char: "\u{F704}")?.1, "F1")
        XCTAssertEqual(decode(char: "\u{F70F}")?.1, "F12")
    }

    /// The branch no application on this machine reaches — which is exactly why it needs
    /// a test that does not depend on one doing so.
    func testGlyphFallback() {
        XCTAssertEqual(decode(glyph: 23)?.1, "⌫")
        XCTAssertEqual(decode(glyph: 2)?.1, "⇥")
        XCTAssertEqual(decode(glyph: 104)?.1, "↑")
        XCTAssertEqual(decode(glyph: 106)?.1, "↓")
        XCTAssertEqual(decode(glyph: 141)?.1, "英数")
        XCTAssertEqual(decode(glyph: 23)?.2, .glyph)
        XCTAssertNil(decode(glyph: 150), "an unmapped glyph must fall through, not guess")
    }

    func testVirtualKeyFallback() {
        XCTAssertEqual(decode(vkey: 126)?.1, "↑")
        XCTAssertEqual(decode(vkey: 125)?.1, "↓")
        XCTAssertEqual(decode(vkey: 123)?.1, "←")
        XCTAssertEqual(decode(vkey: 124)?.1, "→")
        XCTAssertEqual(decode(vkey: 126)?.2, .virtualKey)
    }

    /// Order matters: char wins, then glyph, then virtual key. Every captured item that
    /// carries a glyph also carries a char, so getting this backwards would relabel a
    /// hundred bindings at once.
    func testCharBeatsGlyphBeatsVirtualKey() {
        XCTAssertEqual(decode(char: "s", glyph: 23, vkey: 126)?.2, .char)
        XCTAssertEqual(decode(glyph: 23, vkey: 126)?.2, .glyph)
        XCTAssertEqual(decode(vkey: 126)?.2, .virtualKey)
    }

    /// A char the decoder cannot use must not stop the fallbacks from running.
    func testAnUnusableCharFallsThroughToTheGlyph() {
        XCTAssertEqual(decode(char: "", glyph: 23)?.1, "⌫")
        XCTAssertEqual(decode(char: "\u{F8FF}", glyph: 23)?.1, "⌫",
                       "a private-use scalar with no name is not an answer")
    }

    func testNothingAtAllIsNotAShortcut() {
        XCTAssertNil(decode())
        XCTAssertNil(decode(char: ""))
    }

    /// The bit that was dropped, checked through the whole function rather than through
    /// `decodeModifiers` alone.
    func testModifiersComeThroughWithTheKey() {
        XCTAssertEqual(decode(char: "s", mods: 0x00)?.0, [.command])
        XCTAssertEqual(decode(char: "s", mods: 0x08)?.0, [])
        XCTAssertEqual(decode(char: "\u{F702}", mods: 0x1C)?.0, [.function, .control])
    }
}
