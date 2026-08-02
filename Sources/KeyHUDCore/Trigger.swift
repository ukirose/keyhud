import Cocoa

/// Detects "a modifier is being held down on its own".
///
/// This is a listen-only tap: it never modifies or swallows an event, so it cannot
/// break typing even if this process hangs or crashes. That safety property is why
/// the design does not take ownership of the Command key — measured on 2026-08-02,
/// a lone ⌘ hold is already visible here even with Karabiner's `lazy: true` rule
/// active, so there is nothing to work around.
///
/// The threshold exists because a *tap* also emits a brief cmd down/up before
/// Karabiner's `to_if_alone` fires 英数/かな. Measured tap lengths on this machine
/// were 46ms (Karabiner on) and 133ms (Karabiner off), so 250ms clears the slowest
/// observed tap by ~2x without delaying the panel noticeably.
final class Trigger {
    enum Modifier: Int64 {
        case leftCommand = 55, rightCommand = 54
        case leftControl = 59, rightControl = 62
        case leftOption = 58, rightOption = 61

        var label: String {
            switch self {
            case .leftCommand, .rightCommand: return "⌘"
            case .leftControl, .rightControl: return "⌃"
            case .leftOption, .rightOption: return "⌥"
            }
        }

        var eventFlag: CGEventFlags {
            switch self {
            case .leftCommand, .rightCommand: return .maskCommand
            case .leftControl, .rightControl: return .maskControl
            case .leftOption, .rightOption: return .maskAlternate
            }
        }
    }

    var holdThreshold: TimeInterval = 0.25

    /// Monotonic, so the hold decision cannot be moved by an NTP correction or a daylight
    /// saving change landing between two keystrokes. `Date()` would have been either.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// The hold has lasted long enough. It carries no argument: it used to pass the
    /// Modifier it was armed for, which nothing read and which could name a key that had
    /// already been released. What is held is `currentMods`, read at draw time.
    var onHold: (() -> Void)?
    /// Fired when the held combination changes while the panel is up, so adding ⇧ to a
    /// held ⌘ narrows the display to ⇧⌘ bindings instead of dismissing it. ⇧ alone never
    /// triggers — only ⌘/⌃/⌥ start a hold, shift can only refine one.
    var onModifiersChanged: ((Shortcut.Mods) -> Void)?
    var onRelease: (() -> Void)?
    /// Every chord actually typed: the modifiers held and the character the key produces
    /// ignoring them ("=" for Shift-"="). Usage was previously inferred only from
    /// kAXMenuItemSelected, which an app need not emit — Electron binds several
    /// accelerators per command and only one of them is the menu item, so ⌘− registered
    /// while ⌘+ never did.
    var onChord: ((Shortcut.Mods, String) -> Void)?

    /// Everything about *when* to show a panel. Tested on its own; see HoldMachine.swift.
    private(set) var machine = HoldMachine()
    var currentMods: Shortcut.Mods { machine.mods }
    var currentSides: Shortcut.Sides { machine.sides }

    private var tap: CFMachPort?
    private var pending: DispatchWorkItem?

    /// A listen-only tap is gated by Input Monitoring, not Accessibility — and it is
    /// created successfully even when unpermitted, then silently receives nothing.
    /// So creation is never reported as success; `isReceiving` is the honest signal.
    private(set) var isReceiving = false

    /// When the fn modifier was last seen on a modifier event.
    ///
    /// This was a latch, and a latch is wrong on a laptop with a second keyboard attached:
    /// press fn once on the built-in board and the panel advertises fn shortcuts — the
    /// whole macOS tiling block — for the rest of the process's life, which for a menu-bar
    /// agent is weeks. It is a property of the keyboard being typed on right now, so it
    /// expires.
    /// Not private so a test can place it in the past; the alternative is waiting five
    /// minutes with an Apple keyboard plugged in.
    var lastFunctionModifier: Date?

    /// Whether fn can currently be typed. A keyboard that has one is used with it; go this
    /// long without seeing it and the keyboard in hand is a different one.
    var sawFunctionModifier: Bool {
        guard let lastFunctionModifier else { return false }
        return Clock.now().timeIntervalSince(lastFunctionModifier) < functionModifierMemory
    }
    var functionModifierMemory: TimeInterval = 300

    /// Whether the device-dependent left/right bits ever arrived. Every event here has
    /// passed through Karabiner's virtual keyboard, so whether they survive that trip is a
    /// question about someone else's software; this answers it from observation. Nothing
    /// depends on it — an absent side is already `.unknown`, which lights both caps — so
    /// it exists to be logged, once.
    private(set) var sawSides = false

    /// True between onHold and onRelease. The scrape runs off the main thread, so by the
    /// time results land the user may already have let go; drawing then would flash a
    /// panel after the gesture ended.
    var isHolding: Bool { machine.firing }

    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, ctx in
            guard let ctx else { return Unmanaged.passUnretained(event) }
            Unmanaged<Trigger>.fromOpaque(ctx).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        isReceiving = true

        // macOS disables a tap that takes too long. Nothing here should be slow, but a
        // disabled tap is silent in exactly the way an unpermitted one is, so re-arm it —
        // and throw away the hold, because the events lost during the gap may well have
        // included the release, which would otherwise strand the panel on screen.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            debugLog("event tap was disabled (\(type.rawValue)) — re-enabled, hold dropped")
            apply(machine.reset())
            return
        }

        // Only a modifier change can tell us fn is held. macOS also sets maskSecondaryFn
        // on the key events of arrows, page keys and F-keys — it marks the *class of key*,
        // not a held modifier — so watching every event flipped this true the first time
        // an arrow was pressed, and the fn shortcuts this is meant to hide came straight
        // back. Measured: flagsChanged never carries it on this keyboard.
        if type == .flagsChanged, event.flags.contains(.maskSecondaryFn) {
            lastFunctionModifier = Clock.now()
        }

        let mods = Shortcut.Mods(event.flags)

        if type == .keyDown {
            // fn is dropped here on purpose. macOS sets maskSecondaryFn on the key events
            // of arrows, page keys and F-keys — it marks the *class of key*, not a held
            // modifier, which is why `lastFunctionModifier` above only trusts
            // flagsChanged. Passing the polluted mask on meant ⌘↑ arrived as ⌘fn↑ and
            // matched no menu binding, so every arrow shortcut was credited to nothing.
            let typed = mods.subtracting(.function)
            if typed.isReachable, let ns = NSEvent(cgEvent: event),
               let chars = ns.charactersIgnoringModifiers, !chars.isEmpty {
                onChord?(typed, MenuScraper.normalizeTypedKey(chars))
            }
            apply(machine.step(.key(mods), at: Self.now))
            return
        }

        let sides = Shortcut.Sides(event.flags)
        if !sides.isSilent && !sawSides {
            sawSides = true
            debugLog("modifier sides are reported: \(sides)")
        }
        apply(machine.step(.modifiers(mods, sides), at: Self.now))
    }

    private func apply(_ action: HoldMachine.Action) {
        switch action {
        case .nothing:
            break
        case .arm:
            let generation = machine.generation
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.machine.hold(generation: generation) else { return }
                self.onHold?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
        case .refine:
            onModifiersChanged?(machine.mods)
        case .dismiss:
            pending?.cancel()
            pending = nil
            onRelease?()
        }
    }
}
