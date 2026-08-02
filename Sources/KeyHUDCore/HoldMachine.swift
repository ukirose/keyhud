import Foundation

/// Decides whether a modifier is being *held* rather than *used*.
///
/// This lived inside the event-tap callback, which meant the only way to exercise it was
/// to press keys on a real keyboard and watch. Two bugs survived there for exactly that
/// reason, and an adversarial review found both in one pass while the test suite — which
/// covers layout, decoding and scoring — had nothing to say:
///
/// - the 250ms timer stayed keyed to the *first* key pressed, so rolling from ⌘ to ⌃ mid
///   chord fired the panel after 10ms of ⌃, defeating the one constant the design is
///   built around;
/// - "do not re-arm until every modifier is released" was enforced only for the same
///   physical key, so typing ⌘A and then resting a finger on ⌃ — with ⌘ still down —
///   armed a fresh hold and popped a panel mid-edit.
///
/// So the decision is a value type with no timers, no AppKit and no I/O. `Trigger` keeps
/// the tap, the clock and the callbacks; everything that can be wrong about *when* a panel
/// should appear is here, where a test can drive it one event at a time.
struct HoldMachine {
    /// What arrived.
    enum Event: Equatable {
        /// A modifier went down or up. `mods`/`sides` are the whole state afterwards, not
        /// a delta — that is what the event carries.
        case modifiers(Shortcut.Mods, Shortcut.Sides)
        /// A non-modifier key went down.
        case key(Shortcut.Mods)
    }

    /// What the owner should do about it.
    enum Action: Equatable {
        case nothing
        /// Start the hold timer over. Always start it over: an armed timer that outlives
        /// the key it was armed for is the first bug above.
        case arm
        /// The panel is up and what is held changed.
        case refine
        /// Take the panel down.
        case dismiss
    }

    /// Everything currently held, and which side of the board each came from.
    private(set) var mods: Shortcut.Mods = []
    private(set) var sides: Shortcut.Sides = .unknown
    /// True between `hold()` and the next dismissal.
    private(set) var firing = false
    private(set) var armed = false
    /// Latched when a chord is typed and cleared only when every trigger modifier is up.
    ///
    /// A plain "cancel" is not enough: it clears the armed key, and the next modifier
    /// press then looks like the start of a fresh hold even though the user never let go.
    private(set) var suppressed = false
    /// Bumped on every `.arm`, so a timer can tell whether it is still the current one.
    private(set) var generation = 0
    /// When the last chord was typed. `suppressed` covers a modifier that stays down;
    /// this covers the gap after it comes back up.
    private(set) var lastChordAt = -Double.infinity

    /// How long the keyboard has to be quiet, after a chord, before a hold can arm again.
    ///
    /// ^A ^E ^K in an editor is one thought, not three requests for help, and the middle
    /// of it is the worst possible moment to cover the screen. `suppressed` only ever
    /// covered the case where the modifier never came up — so releasing Control between
    /// chords re-armed on every press, which the test for `suppressed` recorded as correct
    /// behaviour ("a fresh press after letting go is a hold").
    ///
    /// It is not only noise. The panel lists every binding it shows in `shownPaths`, and
    /// anything pressed within ten seconds of that is scored as looked-up rather than
    /// recalled — so a panel that flashes between chords silently holds the whole Control
    /// layer at zero, which is what the learning store measured: two of its four
    /// text-editing records stuck at 0 with the presses logged.
    ///
    /// One second is a placeholder. It has to be long enough to bridge consecutive chords
    /// and short enough that a genuine pause still gets help, and the honest way to set it
    /// is from a measured distribution of this user's chord-to-chord intervals, which is
    /// not collected yet.
    static let graceAfterChord: TimeInterval = 1.0

    mutating func step(_ event: Event, at now: TimeInterval) -> Action {
        switch event {
        case .key(let held):
            let action = stop()
            // Only a chord suppresses. A bare keystroke with no modifier down is just
            // typing, and the next ⌘ press after it is a legitimate hold.
            if !held.intersection(.triggers).isEmpty {
                suppressed = true
                lastChordAt = now
            }
            return action

        case .modifiers(let newMods, let newSides):
            guard !newMods.intersection(.triggers).isEmpty else {
                // Every trigger modifier is up: this is the release, whatever came before.
                suppressed = false
                return stop()
            }
            let changed = newMods != mods || newSides != sides
            mods = newMods
            sides = newSides

            if firing { return changed ? .refine : .nothing }
            guard !suppressed else { return .nothing }
            guard now - lastChordAt >= Self.graceAfterChord else { return .nothing }
            guard changed || !armed else { return .nothing }
            armed = true
            generation += 1
            return .arm
        }
    }

    /// The timer fired. Returns whether the panel should be shown — false when the arming
    /// it belonged to has already been superseded or cancelled.
    mutating func hold(generation: Int) -> Bool {
        guard armed, generation == self.generation else { return false }
        firing = true
        return true
    }

    /// Forget everything, as if the keyboard had gone quiet. Used when the event stream
    /// itself is interrupted — a tap disabled mid-hold loses the release event, and
    /// without this the panel stays up until some unrelated modifier is pressed.
    mutating func reset() -> Action {
        suppressed = false
        return stop()
    }

    private mutating func stop() -> Action {
        let wasFiring = firing
        firing = false
        armed = false
        generation += 1
        mods = []
        sides = .unknown
        return wasFiring ? .dismiss : .nothing
    }
}

extension Shortcut.Mods {
    /// The modifiers a hold can start with.
    ///
    /// ⇧ is excluded on purpose: it is held constantly while typing capitals, and no
    /// shortcut anywhere is ⇧ plus a key alone, so a panel for it would fire dozens of
    /// times a day with nothing to show. It can still *refine* a hold that is already up.
    ///
    /// fn is excluded because this keyboard cannot send it — measured, five presses, zero
    /// events. It is resolved in the HHKB's firmware and the host is never told.
    static let triggers: Shortcut.Mods = [.command, .control, .option]
}
