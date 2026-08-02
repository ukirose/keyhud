import XCTest
@testable import KeyHUDCore

/// AXMenuItemCmdModifiers is a bitmask with one inverted bit and one that was missed
/// entirely. Both mistakes shipped, and both showed the user a chord that does not fire.
final class ModifierDecodingTests: XCTestCase {

    /// Spaced once there is more than one: "⌥⇧⌘" is a smear at a glance.
    func testGlyphOrderIsStableAndSpacedWhenCombined() {
        XCTAssertEqual(Shortcut.Mods([.command]).glyphs, "⌘")
        XCTAssertEqual(Shortcut.Mods([.command, .shift]).glyphs, "⇧ ⌘")
        XCTAssertEqual(Shortcut.Mods([.command, .shift, .option, .control]).glyphs, "^ ⌥ ⇧ ⌘")
    }

    /// macOS 15 puts window tiling behind Globe. Dropping bit 0x10 turned "🌐⌃←" into
    /// "⌃←", which switches Spaces instead of tiling — a label that is not merely wrong
    /// but actively harmful to follow.
    func testFunctionModifierIsRepresented() {
        // "fn" is what is printed on this keyboard; Apple's Globe symbol is not.
        XCTAssertEqual(Shortcut.Mods([.function]).glyphs, "fn")
        XCTAssertEqual(Shortcut.Mods([.function, .control]).glyphs, "fn ^")
    }

    /// What a hold can produce. fn is not on the list: the HHKB resolves it in firmware
    /// and the host is never told it is down — measured, five presses, zero events — so
    /// no hold can report it.
    func testReachability() {
        XCTAssertTrue(Shortcut.Mods([.command]).isReachable)
        XCTAssertTrue(Shortcut.Mods([.control]).isReachable)
        XCTAssertTrue(Shortcut.Mods([.option]).isReachable)
        XCTAssertFalse(Shortcut.Mods([.shift]).isReachable)
        XCTAssertFalse(Shortcut.Mods([]).isReachable)
        XCTAssertFalse(Shortcut.Mods([.function]).isReachable)
        XCTAssertTrue(Shortcut.Mods([.function, .control]).isReachable)
    }

    /// The bitmask itself. Bit 0x08 is inverted — it means *no* Command — so a value of 0,
    /// which reads like "no modifiers", is ⌘.
    func testAXBitmaskDecoding() {
        XCTAssertEqual(MenuScraper.decodeModifiers(0), [.command])
        XCTAssertEqual(MenuScraper.decodeModifiers(0x08), [])
        XCTAssertEqual(MenuScraper.decodeModifiers(0x01), [.command, .shift])
        XCTAssertEqual(MenuScraper.decodeModifiers(0x04), [.command, .control])
        XCTAssertEqual(MenuScraper.decodeModifiers(0x06), [.command, .control, .option])
        XCTAssertEqual(MenuScraper.decodeModifiers(0x18), [.function])
    }

    func testShiftedCharactersMapToTheirBaseKey() {
        XCTAssertEqual(MenuScraper.baseKey(for: "+"), "=")
        XCTAssertEqual(MenuScraper.baseKey(for: "_"), "-")
        XCTAssertEqual(MenuScraper.baseKey(for: ":"), ";")
        XCTAssertEqual(MenuScraper.baseKey(for: "?"), "/")
        XCTAssertNil(MenuScraper.baseKey(for: "S"))
    }
}
