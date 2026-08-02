import XCTest
@testable import KeyHUDCore

/// The system text-editing layer — readline/Emacs keys that live in AppKit, not in any
/// menu bar.
///
/// Holding Control used to show an empty panel. Not because Control does nothing, but
/// because every source the panel had was an application menu, and ⌃A / ⌃E / ⌃K appear in
/// none of them. On a board that puts Control under the left pinky by design, that is
/// half the keyboard invisible.
final class TextBindingsTests: XCTestCase {

    func testTheSystemDictionaryIsRead() {
        XCTAssertGreaterThan(TextBindings.all.count, 10,
                             "StandardKeyBinding.dict should yield a usable set")
    }

    // MARK: - displayed and countable are the same set

    /// `ChordMatch.credit`'s own tests hand it bindings they made up, so they prove the
    /// routing and nothing whatever about the table being routed to. Had `TextBindings`
    /// spelled its keys in a case `Trigger` never emits, all of them would still pass while
    /// ^A stayed exactly as uncountable as before — which is the shape of the bug this
    /// fixes, reintroduced one layer down. So this asks the real table, through the real
    /// normalisation, for every binding the panel is willing to print.
    func testEveryDisplayedBindingCanBeCredited() {
        XCTAssertFalse(TextBindings.all.isEmpty)
        for binding in TextBindings.all {
            // What the event carries: the key without its modifiers, then normalised the
            // one way Trigger normalises it.
            let typed = MenuScraper.normalizeTypedKey(binding.keyLabel.lowercased())
            let credit = ChordMatch.credit(mods: binding.mods, key: typed,
                                           menu: [], text: TextBindings.all)
            XCTAssertNotNil(credit, "\(binding.keys) is drawn on the panel and cannot be "
                            + "credited — displayed and countable have drifted apart")
            XCTAssertTrue(credit?.needsTextFocus ?? false,
                          "\(binding.keys) must still be gated on a text element having "
                          + "focus; ^A does nothing in a file list")
        }
    }

    /// The negative control: the chord has to be what does the matching. Without it the
    /// test above would hold for a `credit` that returns the first binding regardless.
    func testAChordNoBindingClaimsIsNotCredited() {
        let unclaimed = Shortcut.Mods([.control, .option, .command])
        XCTAssertNil(ChordMatch.credit(mods: unclaimed, key: "Q",
                                       menu: [], text: TextBindings.all))
    }

    /// The bindings a Unix user reaches for first.
    func testCoreReadlineKeysArePresent() {
        let byChord = Dictionary(grouping: TextBindings.all) { $0.keys }
        for chord in ["^ A", "^ E", "^ K", "^ D", "^ F", "^ B", "^ N", "^ P"] {
            XCTAssertNotNil(byChord[chord], "\(chord) is missing from the text layer")
        }
    }

    func testBindingsAreNamedInPlainLanguageNotBySelector() {
        for binding in TextBindings.all {
            XCTAssertFalse(binding.title.hasSuffix(":"),
                           "\(binding.title) is a raw selector, not something to read")
        }
    }

    /// Nothing here is a menu item, so nothing has an element to re-read enablement from.
    func testTextBindingsCarryNoAXElement() {
        XCTAssertTrue(TextBindings.all.allSatisfy { $0.element == nil })
        XCTAssertTrue(TextBindings.all.allSatisfy(\.enabled))
    }

    func testOnlyReachableChordsAreOffered() {
        XCTAssertTrue(TextBindings.all.allSatisfy { $0.mods.isReachable },
                      "a chord no hold can produce cannot be displayed")
    }

    /// Only where they fire. ^A moves to the start of a line in a text field and does
    /// nothing in a file list, so offering it everywhere is noise on exactly the modifier
    /// that had too little to show.
    ///
    /// This used to make both calls with the same argument and put its one real assertion
    /// inside `if !withGate.isEmpty` — a branch that never runs, because a test process is
    /// not Accessibility-trusted so the gate is always shut. It passed with the gate
    /// deleted. The decision is now the caller's and is passed in, which makes it a switch
    /// a test can actually throw.
    func testTheTextLayerAppearsOnlyWhenTheCallerSaysItApplies() {
        func resolve(_ applies: Bool) -> PanelContent {
            PanelContent.resolve(appName: "App", appKey: "app", mods: [.control], sections: [],
                                 learning: nil, hideDisabled: true, hideMastered: false,
                                 textBindings: applies ? TextBindings.all : [])
        }
        XCTAssertTrue(resolve(false).isEmpty, "no menu bindings were supplied and the layer is off")
        let on = resolve(true)
        XCTAssertFalse(on.isEmpty, "the layer is the only thing ⌃ has to show in most apps")
        XCTAssertTrue(on.rows.contains { $0.keys == "^ A" })
        XCTAssertEqual(on.combinations.first { $0.mods == [.control] }?.count,
                       on.rows.count,
                       "and it is counted the same way menu bindings are")
    }

    /// What the gate itself reads. It needs a focused AX element, which a test process
    /// cannot have, so this pins the roles it accepts rather than the answer it gives —
    /// the list is what decides whether ⌃ shows anything in a given window.
    func testTheGateAcceptsOnlyTextEditingRoles() {
        XCTAssertEqual(TextBindings.textRoles, [kAXTextFieldRole, kAXTextAreaRole,
                                                kAXComboBoxRole])
    }

    /// POSIX notation, not Apple's. ^C is what stty, man pages and every shell print.
    func testControlUsesCaretNotation() {
        let control = TextBindings.all.filter { $0.mods.contains(.control) }
        XCTAssertFalse(control.isEmpty)
        XCTAssertTrue(control.allSatisfy { $0.keys.contains("^") },
                      "a control chord must read as a terminal writes it")
        XCTAssertFalse(TextBindings.all.contains { $0.keys.contains("\u{2303}") },
                       "U+2303 is the Mac glyph, not the Unix one")
    }
}
