import XCTest
@testable import KeyHUDCore

/// The hold decision, driven one event at a time.
///
/// Before this file there was no test of any kind over the trigger — layout, decoding,
/// scoring and chord matching all had suites and the thing that decides whether a panel
/// appears had none. An adversarial review then found two bugs in it in one pass. Both are
/// pinned below as the first two cases.
final class HoldMachineTests: XCTestCase {
    private var m = HoldMachine()

    /// A hand-wound clock. Starts well past zero so the very first press is not sitting
    /// inside the post-chord grace window by accident.
    private var now: TimeInterval = 1_000
    private func wait(_ seconds: TimeInterval) { now += seconds }

    private func press(_ mods: Shortcut.Mods, _ sides: Shortcut.Sides = .unknown) -> HoldMachine.Action {
        m.step(.modifiers(mods, sides), at: now)
    }
    private func type(_ mods: Shortcut.Mods) -> HoldMachine.Action { m.step(.key(mods), at: now) }
    private func release() -> HoldMachine.Action { m.step(.modifiers([], .unknown), at: now) }
    /// The 250ms timer arming this generation fires.
    @discardableResult private func timer() -> Bool { m.hold(generation: m.generation) }

    // MARK: - the two bugs the review found

    /// Roll from ⌘ to ⌃ before the threshold and the panel used to appear almost at once:
    /// the pending timer stayed keyed to ⌘, so it fired on schedule for a key that had
    /// already been let go, showing the ⌃ page after 10ms of ⌃. The threshold is the one
    /// constant the whole design rests on, and this walked straight past it.
    func testChangingWhatIsHeldRestartsTheClock() {
        XCTAssertEqual(press([.command]), .arm)
        let first = m.generation
        XCTAssertEqual(press([.command, .control]), .arm, "a new key means a new hold")
        XCTAssertNotEqual(m.generation, first)
        XCTAssertEqual(press([.control]), .arm, "and so does letting one go")

        // The timer from the ⌘ arming is stale and must do nothing.
        XCTAssertFalse(m.hold(generation: first))
        XCTAssertFalse(m.firing)
        XCTAssertTrue(timer(), "the current arming still fires on time")
    }

    /// "Do not re-arm until every modifier is released" was enforced only for the key that
    /// was already down — and that key emits no further events while held, so the rule was
    /// enforced by accident. Type ⌘A, keep ⌘ down, touch ⌃: a panel appeared mid-edit.
    func testAChordSuppressesUntilEverythingIsReleased() {
        _ = press([.command])
        _ = type([.command])                                  // ⌘A
        XCTAssertEqual(press([.command, .control]), .nothing, "still mid-chord")
        XCTAssertEqual(press([.command]), .nothing)
        XCTAssertFalse(m.armed)

        _ = release()
        XCTAssertEqual(press([.command]), .nothing,
                       "letting go is no longer enough on its own — the grace window below")
        _ = release()
        wait(HoldMachine.graceAfterChord)
        XCTAssertEqual(press([.command]), .arm, "a fresh press, once the board has been quiet")
    }

    // MARK: - a run of chords is one thought, not a series of requests for help

    /// ^A ^E ^K with Control let go between them — how the Emacs layer is actually typed.
    /// `suppressed` only covered a modifier that never came up, so every press in the run
    /// armed and the panel flashed between chords. The line above used to read
    /// "a fresh press after letting go is a hold", which is the gap, written down as the
    /// intended behaviour.
    ///
    /// The cost was not only noise. Everything the panel lists goes into `shownPaths`, and
    /// a press within ten seconds of that scores as looked-up rather than recalled — so the
    /// flash between two chords held the entire Control layer at zero. Two of the learning
    /// store's four text-editing records sat at 0 with their presses logged.
    func testARunOfChordsNeverArmsBetweenThem() {
        XCTAssertEqual(press([.control]), .arm, "the first hold has nothing before it")
        _ = type([.control])                                  // ^A
        _ = release()

        for chord in 2...5 {
            wait(0.2)                                         // the pace of a fast run
            XCTAssertEqual(press([.control]), .nothing, "chord \(chord) of the run")
            _ = type([.control])
            _ = release()
        }
    }

    /// The other half of the same rule. A run must not be able to lock the panel out for
    /// as long as the typing continues: stopping is what asking looks like.
    func testAPauseAfterARunStillArms() {
        _ = press([.control]); _ = type([.control]); _ = release()
        wait(HoldMachine.graceAfterChord)
        XCTAssertEqual(press([.control]), .arm)
    }

    /// The boundary, from the other side, so the two tests above cannot both be satisfied
    /// by a grace window of zero.
    func testJustInsideTheGraceStaysQuiet() {
        _ = press([.control]); _ = type([.control]); _ = release()
        wait(HoldMachine.graceAfterChord - 0.01)
        XCTAssertEqual(press([.control]), .nothing)
    }

    /// Plain typing must not start the grace, or a paragraph of prose would lock the panel
    /// out for a second after every letter.
    func testTypingWithoutModifiersDoesNotStartTheGrace() {
        _ = type([])
        XCTAssertEqual(press([.command]), .arm)
    }

    // MARK: - the ordinary path

    func testHoldingThenReleasing() {
        XCTAssertEqual(press([.command]), .arm)
        XCTAssertTrue(timer())
        XCTAssertTrue(m.firing)
        XCTAssertEqual(release(), .dismiss)
        XCTAssertFalse(m.firing)
    }

    func testReleasingBeforeTheThresholdShowsNothing() {
        XCTAssertEqual(press([.command]), .arm)
        XCTAssertEqual(release(), .nothing, "nothing was showing, so nothing is dismissed")
        XCTAssertFalse(timer(), "and the timer that is now in flight must not fire")
    }

    /// ⇧ cannot start a hold — it is down constantly while typing capitals — but it
    /// refines one that is already up.
    func testShiftRefinesButNeverStarts() {
        XCTAssertEqual(press([.shift]), .nothing)
        XCTAssertFalse(m.armed)

        _ = press([.command])
        timer()
        XCTAssertEqual(press([.command, .shift]), .refine)
        XCTAssertEqual(m.mods, [.command, .shift])
    }

    func testFnAloneCannotStartAHold() {
        XCTAssertEqual(press([.function]), .nothing)
    }

    /// A repeat of the same state is not a change, and repainting for it would be waste on
    /// the one path that has to stay instant.
    func testAnUnchangedFlagsEventDoesNothing() {
        _ = press([.command])
        timer()
        XCTAssertEqual(press([.command]), .nothing)
    }

    /// Pressing the other ⌘ leaves the mask identical — it is still just Command — so a
    /// mask-only comparison left the board lighting the first key while a second was
    /// plainly down.
    func testTheOtherSideOfTheSameModifierCountsAsAChange() {
        var left = Shortcut.Sides(); left.command = .left
        var both = Shortcut.Sides(); both.command = .both

        _ = press([.command], left)
        timer()
        XCTAssertEqual(press([.command], both), .refine)
        XCTAssertEqual(m.sides.command, .both)
    }

    /// Typing with no modifier down is not a chord, and must not lock out the next hold.
    func testPlainTypingDoesNotSuppress() {
        XCTAssertEqual(type([]), .nothing)
        XCTAssertEqual(press([.command]), .arm)
    }

    /// A chord typed while the panel is up takes it down.
    func testAChordWhileShowingDismisses() {
        _ = press([.command])
        timer()
        XCTAssertEqual(type([.command]), .dismiss)
        XCTAssertFalse(m.firing)
    }

    /// A tap disabled mid-hold loses whatever arrived during the gap, and that may be the
    /// release. Without a way to throw the hold away the panel stays up until some
    /// unrelated modifier is pressed.
    func testResetTakesDownAStrandedPanel() {
        _ = press([.command])
        timer()
        XCTAssertEqual(m.reset(), .dismiss)
        XCTAssertFalse(m.firing)
        XCTAssertEqual(m.mods, [])
        XCTAssertEqual(press([.command]), .arm, "and the next hold works normally")
    }

    /// State does not leak from one hold into the next.
    func testReleaseClearsEverything() {
        var left = Shortcut.Sides(); left.command = .left
        _ = press([.command, .option], left)
        timer()
        _ = release()
        XCTAssertEqual(m.mods, [])
        XCTAssertEqual(m.sides, .unknown)
        XCTAssertFalse(m.armed)
        XCTAssertFalse(m.suppressed)
    }
}

/// The fn modifier's availability, which is a property of the keyboard in hand.
final class FunctionModifierMemoryTests: XCTestCase {
    private var trigger: Trigger!

    override func setUp() {
        super.setUp()
        trigger = Trigger()
        Clock.override = Date(timeIntervalSince1970: 1_800_000_000)
    }
    override func tearDown() { Clock.override = nil; super.tearDown() }

    func testUnseenMeansUnavailable() {
        XCTAssertFalse(trigger.sawFunctionModifier)
    }

    /// This used to be a one-way latch. On a laptop with a second keyboard attached that
    /// is wrong in the worst direction: press fn once on the built-in board and the panel
    /// advertises the whole macOS tiling block forever after, on a keyboard that cannot
    /// send fn at all. "Forever" for a menu-bar agent means weeks.
    func testItExpiresSoAnotherKeyboardDoesNotPoisonTheSession() {
        trigger.lastFunctionModifier = Clock.now()
        XCTAssertTrue(trigger.sawFunctionModifier)

        Clock.override = Clock.now().addingTimeInterval(trigger.functionModifierMemory - 1)
        XCTAssertTrue(trigger.sawFunctionModifier, "still the same keyboard")

        Clock.override = Clock.now().addingTimeInterval(2)
        XCTAssertFalse(trigger.sawFunctionModifier,
                       "long enough without it means the board in hand does not have one")
    }

    /// A keyboard that does have fn keeps it, because using it renews the memory.
    func testUsingFnKeepsItAvailable() {
        for _ in 0..<5 {
            trigger.lastFunctionModifier = Clock.now()
            Clock.override = Clock.now().addingTimeInterval(trigger.functionModifierMemory / 2)
            XCTAssertTrue(trigger.sawFunctionModifier)
        }
    }
}
