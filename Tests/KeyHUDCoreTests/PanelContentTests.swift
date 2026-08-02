import XCTest
import ApplicationServices
@testable import KeyHUDCore

/// PanelContent is where the panel decides what is drawn and how many of each thing
/// exist. It was three separate passes that disagreed with each other, so these tests
/// pin the property that fix depends on: the counts and the rows come from one pass.
final class PanelContentTests: XCTestCase {

    /// AXUIElement cannot be constructed in a test, and PanelContent never touches it —
    /// a dummy application element stands in.
    fileprivate func shortcut(_ path: [String], _ mods: Shortcut.Mods, key: String = "S",
                          enabled: Bool = true) -> Shortcut {
        Shortcut(path: path, mods: mods, keyLabel: key, source: .char,
                 element: AXUIElementCreateApplication(0), enabled: enabled)
    }

    private func sections(_ items: [Shortcut]) -> [MenuSection] {
        [MenuSection(name: "ファイル", items: items)]
    }

    func testShowsOnlyTheHeldCombination() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: sections([
                shortcut(["ファイル", "保存"], [.command], key: "S"),
                shortcut(["ファイル", "別名で保存"], [.command, .shift], key: "S"),
            ]),
            learning: nil, hideDisabled: true, hideMastered: false)

        XCTAssertEqual(content.rows.count, 1)
        XCTAssertEqual(content.rows.first?.path.last, "保存")
    }

    /// The regression that motivated the type: the bar said five, the body listed three.
    func testCombinationCountsMatchWhatIsDrawable() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: sections([
                shortcut(["m", "a"], [.command], key: "A"),
                shortcut(["m", "b"], [.command], key: "B", enabled: false),
                shortcut(["m", "c"], [.command, .shift], key: "C"),
            ]),
            learning: nil, hideDisabled: true, hideMastered: false)

        let cmd = content.combinations.first { $0.mods == [.command] }
        XCTAssertEqual(cmd?.count, 1, "the disabled binding must not be counted")
        XCTAssertEqual(content.rows.count, 1)
        XCTAssertEqual(cmd?.count, content.rows.count)
    }

    /// Only ⌘/⌃/⌥ can begin a hold, so advertising anything else promises a page the
    /// user has no gesture to open.
    func testUnreachableCombinationsAreNotAdvertised() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: sections([
                shortcut(["m", "a"], [.command]),
                shortcut(["m", "b"], [.shift], key: "B"),
                shortcut(["m", "c"], [], key: "C"),
            ]),
            learning: nil, hideDisabled: true, hideMastered: false)

        XCTAssertEqual(content.combinations.map(\.mods), [[.command]])
    }

    func testEmptyWhenNothingMatchesTheHeldCombination() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.control, .option],
            sections: sections([shortcut(["m", "a"], [.command])]),
            learning: nil, hideDisabled: true, hideMastered: false)

        XCTAssertTrue(content.isEmpty, "an empty result must withdraw the panel, not draw a frame around nothing")
    }

    func testCombinationsAreOrderedByModifierCount() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: sections([
                shortcut(["m", "a"], [.command, .shift, .option], key: "A"),
                shortcut(["m", "b"], [.command], key: "B"),
                shortcut(["m", "c"], [.command, .shift], key: "C"),
            ]),
            learning: nil, hideDisabled: true, hideMastered: false)

        XCTAssertEqual(content.combinations.map { $0.mods.rawValue.nonzeroBitCount }, [1, 2, 3])
    }

    func testDisabledItemsAreKeptWhenHideDisabledIsOff() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: sections([shortcut(["m", "a"], [.command], enabled: false)]),
            learning: nil, hideDisabled: false, hideMastered: false)

        XCTAssertEqual(content.rows.count, 1)
    }
}

extension PanelContentTests {
    /// Holding ⌃ finds nothing in most apps — across twelve captured, not one has a
    /// ⌃-only or ⌥-only binding. The panel withdrew, which read as the modifier being
    /// broken rather than as it only being used in combination.
    func testHeldCombinationIsListedEvenWhenItHasNothing() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.control],
            sections: [MenuSection(name: "m", items: [
                shortcut(["m", "a"], [.command]),
                shortcut(["m", "b"], [.control, .command], key: "B"),
            ])],
            learning: nil, hideDisabled: true, hideMastered: false)

        XCTAssertTrue(content.isEmpty, "nothing matches ⌃ alone")
        XCTAssertFalse(content.hasNothingToShow, "but there is somewhere to point")
        XCTAssertEqual(content.combinations.first { $0.mods == [.control] }?.count, 0)
        XCTAssertEqual(content.combinations.first { $0.mods == [.control, .command] }?.count, 1)
    }

    func testWithdrawsOnlyWhenThereIsTrulyNothing() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.control],
            sections: [MenuSection(name: "m", items: [shortcut(["m", "a"], [.shift], key: "A")])],
            learning: nil, hideDisabled: true, hideMastered: false)
        XCTAssertTrue(content.hasNothingToShow,
                      "only an unreachable ⇧ binding exists, so there is nothing to offer")
    }
}

extension PanelContentTests {
    /// Measured on this machine: pressing the HHKB's Fn five times produced zero events
    /// carrying the fn modifier, while Control and Command produced theirs. The key is
    /// resolved in the keyboard's firmware, so every fn-requiring shortcut — 絵文字と記号,
    /// the whole macOS 15 tiling block — is listed by apps and unpressable here.
    func testFunctionShortcutsAreHiddenOnAKeyboardThatCannotTypeThem() {
        let sections = [MenuSection(name: "m", items: [
            shortcut(["m", "emoji"], [.function], key: "E"),
            shortcut(["m", "tile"], [.function, .control], key: "F"),
            shortcut(["m", "save"], [.command], key: "S"),
        ])]

        let hidden = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command], sections: sections,
            learning: nil, hideDisabled: true, hideMastered: false,
            canTypeFunctionModifier: false)
        XCTAssertEqual(hidden.combinations.map(\.mods), [[.command]],
                       "fn combinations must not be advertised when fn cannot be typed")

        let shown = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command], sections: sections,
            learning: nil, hideDisabled: true, hideMastered: false,
            canTypeFunctionModifier: true)
        XCTAssertTrue(shown.combinations.contains { $0.mods.contains(.function) },
                      "plug in a keyboard that has fn and they come back")
    }

    /// The separate half of the same problem. macOS spends F1–F12 on brightness, Mission
    /// Control and volume unless "Use F1, F2, etc. keys as standard function keys" is on.
    /// A laptop escapes that by holding fn; this board's fn is resolved in firmware and
    /// never reaches macOS, so with the setting off the key cannot be sent at all — and
    /// ⌥ on top of a media key opens the matching System Settings pane, which is what an
    /// IDE's ⌥F3 did instead of jumping to the next change.
    func testFunctionKeyBindingsAreHiddenWhileMacOSIsSpendingThoseKeys() {
        let sections = [MenuSection(name: "m", items: [
            shortcut(["m", "定義に移動"], [], key: "F12"),
            shortcut(["m", "次の変更箇所"], [.control, .command], key: "F3"),
            shortcut(["m", "遠いF"], [.command], key: "F13"),
            shortcut(["m", "保存"], [.command], key: "S"),
        ])]

        let hidden = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command], sections: sections,
            learning: nil, hideDisabled: true, hideMastered: false,
            canTypeFunctionKeys: false)
        XCTAssertFalse(hidden.combinations.contains { $0.mods == [.control, .command] },
                       "⌃⌘F3 cannot fire here, so the bar must not offer it")
        XCTAssertEqual(hidden.rows.map(\.keyLabel).sorted(), ["F13", "S"],
                       "F13 is not one macOS claims, so it stays")

        let shown = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command], sections: sections,
            learning: nil, hideDisabled: true, hideMastered: false,
            canTypeFunctionKeys: true)
        XCTAssertTrue(shown.combinations.contains { $0.mods == [.control, .command] },
                      "turn the setting on and the IDE's F-keys are real shortcuts again")
    }
}

extension PanelContentTests {
    func testFunctionKeyRangeIsExactlyWhatMacOSClaims() {
        func needs(_ key: String) -> Bool {
            shortcut(["m", "x"], [.command], key: key).needsStandardFunctionKeys
        }
        XCTAssertTrue(needs("F1"))
        XCTAssertTrue(needs("F12"))
        XCTAssertFalse(needs("F13"))
        XCTAssertFalse(needs("F"), "a bare F is the letter")
        XCTAssertFalse(needs("Fn"))
        XCTAssertFalse(needs("S"))
    }
}

extension PanelContentTests {
    /// The chip count and the drawn rows come from one pass — including the finished ones.
    ///
    /// Hall-of-famers were counted in the bar and then dropped by `grouped()`, so a chip
    /// read "⌘ 3" above two rows. An app where everything had graduated drew a header, a
    /// chip claiming bindings, and an empty rectangle where the list should be.
    func testMasteredBindingsAreCountedAndDrawn() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyhud-mastered-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LearningStore(directory: dir)
        Clock.override = Date(timeIntervalSince1970: 1_800_000_000)
        defer { Clock.override = nil }

        let learned = ["ファイル", "保存"]
        for day in 0..<8 {
            Clock.override = Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400)
            store.noteKeyboardUse(app: "app", path: learned, assisted: false)
            store.noteKeyboardUse(app: "app", path: learned, assisted: false)
        }
        guard case .hallOfFame = store.emphasis(app: "app", path: learned) else {
            return XCTFail("setup did not reach the hall of fame")
        }

        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: [MenuSection(name: "ファイル", items: [
                shortcut(learned, [.command], key: "S"),
                shortcut(["ファイル", "開く"], [.command], key: "O"),
            ])],
            learning: store, hideDisabled: true, hideMastered: false)

        let drawn = content.grouped(learning: store).flatMap(\.items).count
        XCTAssertEqual(content.combinations.first { $0.mods == [.command] }?.count, drawn,
                       "the chip must equal what is drawn, mastered rows included")
        XCTAssertEqual(drawn, 2)
        XCTAssertEqual(content.grouped(learning: store).last?.bucket, .mastered,
                       "and finished ones go last, where they cost the least attention")
    }

    /// The board's "bound under some other combination" marks come from the same pass as
    /// the rows, so a cap can never light for something no chip will explain.
    func testCapsMarkedElsewhereAreOnlyEverVisibleBindings() {
        let content = PanelContent.resolve(
            appName: "App", appKey: "app", mods: [.command],
            sections: [MenuSection(name: "m", items: [
                shortcut(["m", "保存"], [.command], key: "S"),
                shortcut(["m", "他"], [.option, .command], key: "K"),
                shortcut(["m", "F系"], [.control, .command], key: "F5"),
                shortcut(["m", "fn要"], [.function, .control], key: "J"),
                shortcut(["m", "無効"], [.option, .command], key: "P", enabled: false),
            ])],
            learning: nil, hideDisabled: true, hideMastered: false,
            canTypeFunctionModifier: false, canTypeFunctionKeys: false)

        XCTAssertTrue(content.visibleElsewhere.contains("K"), "⌥⌘K is real and reachable")
        XCTAssertFalse(content.visibleElsewhere.contains("5"),
                       "⌃⌘F5 was filtered out of every chip, so its cap must stay dark")
        XCTAssertFalse(content.visibleElsewhere.contains("J"), "so must a chord needing fn")
        XCTAssertFalse(content.visibleElsewhere.contains("P"), "and a disabled one")
        XCTAssertFalse(content.visibleElsewhere.contains("S"),
                       "the held combination's own key is not 'elsewhere'")

        // Every marked cap belongs to a combination the bar advertises.
        let advertised = content.combinations.filter { $0.count > 0 }.map(\.mods)
        XCTAssertFalse(advertised.isEmpty)
        XCTAssertTrue(advertised.contains(Shortcut.Mods([.option, .command])))
        XCTAssertFalse(advertised.contains(Shortcut.Mods([.control, .command])),
                       "the filtered-out F-key chord must not be advertised either")
    }
}
