import Cocoa
import ApplicationServices

struct Shortcut {
    /// Which attribute the key came from. Recorded so the diagnostics can show whether
    /// the glyph path is actually carrying anything, rather than assuming it.
    enum Source: String { case char, glyph, virtualKey }

    /// Which modifiers the shortcut needs. Kept as a mask, not just the glyph prefix,
    /// so the keymap can light exactly the bindings reachable from the combination
    /// currently held down and re-light as modifiers are added.
    struct Mods: OptionSet {
        let rawValue: Int
        static let command = Mods(rawValue: 1 << 0)
        static let shift   = Mods(rawValue: 1 << 1)
        static let option  = Mods(rawValue: 1 << 2)
        static let control = Mods(rawValue: 1 << 3)
        /// The Globe/fn key. macOS 15 puts the whole window-tiling block behind it, and
        /// dropping the bit turned "Globe ⌃←" into "⌃←" — a chord that is not merely
        /// mislabelled but switches Spaces when pressed.
        static let function = Mods(rawValue: 1 << 4)

        /// What a hold can produce. fn is excluded: the HHKB resolves it in firmware and
        /// never tells the host, so no hold can ever report it.
        var isReachable: Bool { !intersection([.command, .control, .option]).isEmpty }

        /// Modifiers as a terminal writes them, spaced apart once there is more than one:
        /// "⌥⇧⌘" is a smear at a glance, "⌥ ⇧ ⌘" is three things.
        ///
        /// Control is "^", the POSIX notation — what stty, man pages and every shell
        /// print, and what an HHKB user already reads without thinking. Apple's "⌃"
        /// (U+2303) is a Mac convention, and this keyboard is not a Mac convention.
        /// "fn" likewise, because that is the legend on the key.
        var glyphs: String {
            var parts: [String] = []
            if contains(.function) { parts.append("fn") }
            if contains(.control) { parts.append("^") }
            if contains(.option) { parts.append("⌥") }
            if contains(.shift) { parts.append("⇧") }
            if contains(.command) { parts.append("⌘") }
            return parts.joined(separator: parts.count > 1 ? " " : "")
        }

        init(rawValue: Int) { self.rawValue = rawValue }

        init(_ flags: CGEventFlags) {
            var m = Mods()
            if flags.contains(.maskCommand) { m.insert(.command) }
            if flags.contains(.maskShift) { m.insert(.shift) }
            if flags.contains(.maskAlternate) { m.insert(.option) }
            if flags.contains(.maskControl) { m.insert(.control) }
            if flags.contains(.maskSecondaryFn) { m.insert(.function) }
            self = m
        }
    }

    /// Which physical key each held modifier came from.
    ///
    /// `CGEventFlags` carries device-dependent bits beside the generic ones — left ⌘ is
    /// 0x08 and right ⌘ is 0x10 — so the event does say which ⌘ is down. (An earlier note
    /// in this file claimed otherwise; it was wrong.)
    ///
    /// They are not guaranteed to arrive. A virtual keyboard may leave them clear, and
    /// every event here has passed through Karabiner's. So a clear bit means *unknown*,
    /// never "not held": unknown lights both caps, which is what the board did before any
    /// of this and is never a false picture of the user's hands.
    struct Sides: Equatable {
        enum Side { case unknown, left, right, both }
        var command: Side = .unknown
        var shift: Side = .unknown
        var option: Side = .unknown
        var control: Side = .unknown

        static let unknown = Sides()

        init() {}

        init(_ flags: CGEventFlags) {
            let raw = flags.rawValue
            func read(_ left: UInt64, _ right: UInt64) -> Side {
                switch (raw & left != 0, raw & right != 0) {
                case (true, true):   return .both
                case (true, false):  return .left
                case (false, true):  return .right
                case (false, false): return .unknown
                }
            }
            // NX_DEVICE*KEYMASK, from IOKit's ev_keymap.h.
            control = read(0x00000001, 0x00002000)
            shift   = read(0x00000002, 0x00000004)
            command = read(0x00000008, 0x00000010)
            option  = read(0x00000020, 0x00000040)
        }

        func side(of mod: Mods) -> Side {
            switch mod {
            case .command: return command
            case .shift:   return shift
            case .option:  return option
            case .control: return control
            default:       return .unknown
            }
        }

        /// True when nothing arrived — the keyboard, or something in the path, does not
        /// report sides at all.
        var isSilent: Bool {
            [command, shift, option, control].allSatisfy { $0 == .unknown }
        }

        var description: String {
            [("⌘", command), ("⇧", shift), ("⌥", option), ("⌃", control)]
                .filter { $0.1 != .unknown }
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: " ")
        }
    }

    let path: [String]      // e.g. ["File", "Save As…"]
    let mods: Mods
    /// The key itself, without modifiers: "S", "←", "F3". Matched against keycaps.
    let keyLabel: String
    /// Spaced throughout: "⇧ ⌘ S" reads as three keys to press, "⇧⌘S" as one word to
    /// decipher. The gap between the last modifier and the key is the same gap as between
    /// the modifiers, because it is the same kind of boundary.
    var keys: String { mods.glyphs.isEmpty ? keyLabel : mods.glyphs + " " + keyLabel }
    let source: Source
    /// nil for bindings that are not menu items — the system text-editing layer has no
    /// AX element to re-read, and needs none: it is the same on every app.
    let element: AXUIElement?
    /// Contextual: an item can be live now and dead a second later, depending on what
    /// has focus. Structure is cached; this is re-read on every invocation.
    var enabled: Bool
    var title: String { path.last ?? "" }

    /// Whether firing this needs "Use F1, F2, etc. keys as standard function keys" on.
    ///
    /// F1–F12 are the ones macOS claims for brightness, Mission Control, Spotlight and
    /// volume. F13 and up it leaves alone — they are not on this board, but the rule is
    /// about what macOS takes, not about what fits.
    var needsStandardFunctionKeys: Bool {
        guard keyLabel.first == "F", let n = Int(keyLabel.dropFirst()) else { return false }
        return (1...12).contains(n)
    }
}

struct MenuSection {
    let name: String        // top-level menu title
    var items: [Shortcut]
}

/// Walks the frontmost application's menu bar over the Accessibility API and pulls out
/// every item that has a key equivalent. This is the same source CheatSheet, KeyCue and
/// KeyClu read — parity, not differentiation.
///
/// The walk can be slow: asking for a menu's children makes the target app populate it,
/// and a large app can take hundreds of milliseconds. It therefore runs off the main
/// thread and results are cached per (bundle id, menu bar shape) until the app changes.
enum MenuScraper {

    static func scrape(pid: pid_t) -> [MenuSection] {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = copy(app, kAXMenuBarAttribute) else { return [] }
        guard let topLevel = children(menuBar) else { return [] }

        var sections: [MenuSection] = []
        // The first child is the Apple menu; skip it, every app shares it.
        for entry in topLevel.dropFirst() {
            guard let name = string(entry, kAXTitleAttribute), !name.isEmpty else { continue }
            // A top-level entry holds a single AXMenu child that holds the real items.
            guard let submenus = children(entry), let menu = submenus.first else { continue }
            var items: [Shortcut] = []
            collect(menu, path: [name], into: &items, depth: 0)
            if !items.isEmpty { sections.append(MenuSection(name: name, items: items)) }
        }
        return sections
    }

    private static func collect(_ menu: AXUIElement, path: [String],
                                into items: inout [Shortcut], depth: Int) {
        guard depth < 4, let entries = children(menu) else { return }
        for item in entries {
            guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { continue }
            if let (mods, keyLabel, source) = keyEquivalent(item) {
                items.append(Shortcut(path: path + [title], mods: mods, keyLabel: keyLabel,
                                      source: source, element: item, enabled: isEnabled(item)))
            }
            // Recurse into submenus, which appear as a single AXMenu child.
            if let sub = children(item), let inner = sub.first {
                collect(inner, path: path + [title], into: &items, depth: depth + 1)
            }
        }
    }

    /// Raw attribute dump for diagnosis. Reports what the app actually returns rather
    /// than what the parser made of it, so a wrong glyph can be told apart from a wrong
    /// mapping without guessing.
    static func dumpRaw(pid: pid_t) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for section in scrape(pid: pid) {
            for item in section.items {
                // keyLabel and mods are stored apart from the joined display string: a
                // test that has to un-join "⇧ ⌘S" is coupled to how the panel renders,
                // and broke the moment the glyphs gained spacing.
                var row: [String: Any] = ["path": item.path, "parsed": item.keys,
                                          "keyLabel": item.keyLabel,
                                          "mods": item.mods.rawValue,
                                          "source": item.source.rawValue]
                guard let element = item.element else { continue }
                if let ch = string(element, "AXMenuItemCmdChar") {
                    row["cmdChar"] = ch
                    row["cmdCharScalars"] = ch.unicodeScalars.map { String(format: "U+%04X", $0.value) }
                }
                if let g = int(element, "AXMenuItemCmdGlyph") { row["cmdGlyph"] = g }
                if let v = int(element, "AXMenuItemCmdVirtualKey") { row["cmdVirtualKey"] = v }
                if let m = int(element, "AXMenuItemCmdModifiers") { row["cmdModifiers"] = m }
                out.append(row)
            }
        }
        return out
    }

    /// Re-reads only the contextual bit, reusing the element references from the cached
    /// walk. Much cheaper than a rescan because it does not re-traverse or re-populate
    /// menus. Returns nil if the references have gone stale (the app rebuilt its menus),
    /// which is the caller's signal to do a full scrape again.
    static func refreshEnabled(_ sections: [MenuSection]) -> [MenuSection]? {
        var refreshed: [MenuSection] = []
        for section in sections {
            var items = section.items
            for i in items.indices {
                guard let element = items[i].element else { continue }
                var ref: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(
                    element, kAXEnabledAttribute as CFString, &ref)
                if err == .invalidUIElement || err == .cannotComplete { return nil }
                if let value = ref as? Bool { items[i].enabled = value }
            }
            refreshed.append(MenuSection(name: section.name, items: items))
        }
        return refreshed
    }

    private static func isEnabled(_ item: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &ref) == .success
        else { return true }   // unknown: show it rather than hide something usable
        return (ref as? Bool) ?? true
    }

    // MARK: - key equivalents

    /// `AXMenuItemCmdModifiers` is a bitmask over ⇧⌥⌃, plus a bit that means "no ⌘".
    /// A value of 0 therefore means a plain ⌘ shortcut, which is the common case.
    ///
    /// Three attributes can carry the key itself and they are not interchangeable:
    ///   - `AXMenuItemCmdChar` — a printable character. The common case.
    ///   - `AXMenuItemCmdGlyph` — a Carbon glyph constant, used for keys drawn as a
    ///     picture: arrows, ↩, ⌫, F-keys, and (relevant here) 英数 and かな. This is
    ///     what Hammerspoon has read for years; an earlier version of this file read
    ///     only the virtual key below and silently dropped every one of them.
    ///   - `AXMenuItemCmdVirtualKey` — a keycode. Kept as a fallback for items that
    ///     expose it but no glyph.
    /// `AXMenuItemCmdModifiers`, which is a bitmask with one inverted bit.
    ///
    /// Pulled out of the AX read so it can be exercised against the captured corpus:
    /// while it lived inside `keyEquivalent` the only way to test it was to have the app
    /// running and a menu bar to walk, which is why bit 0x10 went unnoticed for so long.
    static func decodeModifiers(_ raw: Int) -> Shortcut.Mods {
        var mods: Shortcut.Mods = []
        if raw & 0x04 != 0 { mods.insert(.control) }
        if raw & 0x02 != 0 { mods.insert(.option) }
        if raw & 0x01 != 0 { mods.insert(.shift) }
        if raw & 0x08 == 0 { mods.insert(.command) }   // inverted: the bit means "no ⌘"
        if raw & 0x10 != 0 { mods.insert(.function) }
        return mods
    }

    static func keyEquivalent(_ item: AXUIElement) -> (Shortcut.Mods, String, Shortcut.Source)? {
        keyEquivalent(cmdChar: string(item, "AXMenuItemCmdChar"),
                      cmdGlyph: int(item, "AXMenuItemCmdGlyph"),
                      cmdVirtualKey: int(item, "AXMenuItemCmdVirtualKey"),
                      cmdModifiers: int(item, "AXMenuItemCmdModifiers") ?? 0)
    }

    /// The same decision, over the four raw attribute values.
    ///
    /// Split from the AX read so the captured corpus can be *replayed* through it. The
    /// corpus tests were checking `keyLabel` — a field the corpus got from this decoder at
    /// capture time — so they compared the decoder against a frozen snapshot of its own
    /// answers and would have passed with the decoder deleted. Four decoding bugs shipped
    /// in a row here; the suite that exists to catch a fifth could not.
    static func keyEquivalent(cmdChar: String?, cmdGlyph: Int?, cmdVirtualKey: Int?,
                              cmdModifiers: Int) -> (Shortcut.Mods, String, Shortcut.Source)? {
        let mods = decodeModifiers(cmdModifiers)

        if let ch = cmdChar, !ch.isEmpty,
           let scalar = ch.unicodeScalars.first {
            // AppKit encodes arrows and function keys as NSEvent's private-use-area
            // constants (NSUpArrowFunctionKey = 0xF700 and friends). They are not text:
            // rendering one prints whatever the font shows for an unmapped codepoint,
            // which is where the stray "?" glyphs came from. Translate the ones that
            // have a symbol and otherwise fall through to the glyph attribute.
            // Control characters are the same kind of trap as the private-use range: an
            // app that sets its key equivalent to "\u{8}" means ⌫, and returning the raw
            // byte draws an empty key column and stops the cap from ever lighting.
            // Finder's ⌘⌫ and Chrome's ⌃⇥ both arrive this way.
            if let named = controlCharGlyphs[scalar.value] { return (mods, named, .char) }
            if (0xF700...0xF8FF).contains(scalar.value) {
                if let named = functionKeyGlyphs[scalar.value] { return (mods, named, .char) }
                if (0xF704...0xF726).contains(scalar.value) {
                    return (mods, "F\(scalar.value - 0xF704 + 1)", .char)
                }
            } else if scalar.value >= 0x20 {
                // Reported verbatim. Apps disagree about which legend of a key they name
                // — measured 2026-08-02, Zoom In is "=" in Antigravity IDE but "+" in
                // Claude, Safari and Ghostty, all with the shift flag clear — so rewriting
                // it would make the panel disagree with the app's own menu. The board
                // resolves the physical key separately, via `baseKey`.
                return (mods, ch.uppercased(), .char)
            }
        }
        // Comes back as an empty string rather than a number when unused.
        if let g = cmdGlyph, let name = menuGlyphs[g] { return (mods, name, .glyph) }
        if let vk = cmdVirtualKey, let name = virtualKeyNames[vk] {
            return (mods, name, .virtualKey)
        }
        return nil
    }

    /// Carbon menu glyph constants, from HIToolbox's Menus.h. Values transcribed from
    /// Hammerspoon's `hs.application.menuGlyphs`, which has been carrying this table
    /// against real applications for years.
    private static let menuGlyphs: [Int: String] = [
        2: "⇥", 3: "⇤", 4: "⌤", 5: "⇧", 6: "⌃", 7: "⌥", 9: "␣", 10: "⌦",
        11: "↩", 12: "↪", 16: "↓", 17: "⌘", 18: "✓", 19: "◇", 23: "⌫",
        24: "←", 25: "↑", 26: "→", 27: "⎋", 28: "⌧",
        97: "␢", 98: "⇞", 99: "⇪", 100: "←", 101: "→", 102: "↖", 103: "?",
        104: "↑", 105: "↘", 106: "↓", 107: "⇟", 110: "⌽",
        111: "F1", 112: "F2", 113: "F3", 114: "F4", 115: "F5", 116: "F6",
        117: "F7", 118: "F8", 119: "F9", 120: "F10", 121: "F11", 122: "F12",
        135: "F13", 136: "F14", 137: "F15", 138: "⎈", 140: "⏏",
        141: "英数", 142: "かな",
        143: "F16", 144: "F17", 145: "F18", 146: "F19",
    ]

    /// What a keystroke's character means, in the same alphabet the menus use.
    ///
    /// `charactersIgnoringModifiers` hands back the raw encoding — U+007F for Delete,
    /// U+0009 for Tab, U+F700 for Up — while `keyEquivalent` has already turned the menu's
    /// copy of those into ⌫, ⇥, ↑. Nothing reconciled the two, so every chord on a glyph
    /// key was compared against a string that appears in no cap's match list and was
    /// silently credited to nothing: ⌘⌫, ⌘⇥, ⌘↩, ⌘⎋ and every arrow shortcut earned no
    /// score, never graduated, and sat in the to-learn column forever while letter
    /// shortcuts advanced past them. Space worked, because "␣" and " " share a cap.
    static func normalizeTypedKey(_ typed: String) -> String {
        guard let scalar = typed.unicodeScalars.first else { return typed }
        if let named = controlCharGlyphs[scalar.value] { return named }
        if (0xF700...0xF8FF).contains(scalar.value) {
            if let named = functionKeyGlyphs[scalar.value] { return named }
            if (0xF704...0xF726).contains(scalar.value) {
                return "F\(scalar.value - 0xF704 + 1)"
            }
        }
        return typed.uppercased()
    }

    /// Shifted characters on a US board, mapped to the key they physically live on.
    private static let shiftedToBase: [String: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
        "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// The unshifted key a character physically lives on: "+" is Shift-"=", so it is
    /// found on the "=" cap. Used only for locating a key on the board — never for
    /// display, which keeps whatever the app called it.
    static func baseKey(for label: String) -> String? { shiftedToBase[label] }

    /// C0 control characters used as key equivalents. Verified present on live apps:
    /// Finder ファイル ▸ ゴミ箱に入れる (U+0008), Terminal 行をマークして改行を送信
    /// (U+000D), Chrome/Finder/Mail tab switching (U+0009), Mail 単語入力補完 (U+001B).
    private static let controlCharGlyphs: [UInt32: String] = [
        0x08: "⌫", 0x7F: "⌫", 0x09: "⇥", 0x19: "⇤", 0x0D: "↩", 0x03: "⌤",
        0x1B: "⎋", 0x20: "␣",
    ]

    /// NSEvent's function-key constants from NSText.h, which arrive through
    /// AXMenuItemCmdChar as single private-use-area characters.
    private static let functionKeyGlyphs: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
        0xF727: "Ins", 0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘",
        0xF72C: "⇞", 0xF72D: "⇟", 0xF739: "⌧", 0xF746: "?",
    ]

    private static let virtualKeyNames: [Int: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "␣", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]

    // MARK: - AX plumbing

    private static func copy(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    /// Walks up from a menu item to build its full path, e.g. ["編集", "取り消す"].
    /// The AX observer hands us a bare element with no context, and titles alone are not
    /// unique within an app — two menus can both hold "開く", and under the recall-chain
    /// model a collision means one item's mouse pick silently destroys the other's
    /// progress. Returns just the title if the app does not expose parents.
    static func path(of item: AXUIElement) -> [String] {
        var parts: [String] = []
        var node: AXUIElement? = item
        var depth = 0
        while let current = node, depth < 12 {
            depth += 1
            if let role = string(current, kAXRoleAttribute),
               role == kAXMenuItemRole || role == kAXMenuBarItemRole,
               let title = string(current, kAXTitleAttribute), !title.isEmpty {
                parts.append(title)
            }
            node = copy(current, kAXParentAttribute)
        }
        return parts.isEmpty ? [] : parts.reversed()
    }

    private static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func int(_ element: AXUIElement, _ attr: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }
}
