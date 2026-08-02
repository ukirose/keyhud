import Cocoa

/// The physical board, drawn.
///
/// A list teaches you the *name* of a command; a keymap teaches your fingers where to
/// go. Shortcuts are motor memory, so the spatial view is not decoration — it is the
/// better teaching surface. It also gives the clearest possible progress signal: as
/// bindings graduate the board goes dark, and an empty board is the goal.
///
/// The layout below is HHKB Professional US (60 keys), which is what this machine has.
/// Anything that has no keycap here — arrows, function keys, forward delete — is not
/// faked onto the board; it is listed separately by the panel, because putting a key
/// somewhere it physically is not would teach the wrong motion.
enum KeyboardLayout {
    struct Cap {
        let label: String       // what is printed on the key
        let match: [String]     // key labels from AX that land here
        let width: CGFloat      // in units, 1u = one alphanumeric key
        /// Reached by holding Fn. On a 60% board the arrows and function keys live here,
        /// so they are shown on the cap that actually produces them with a badge, rather
        /// than being banished to a list or — worse — drawn as keys that do not exist.
        let fnMatch: [String]
        /// The upper legend, where the physical keycap carries two — "+" over "=".
        /// Drawn as well as the base, because "− and +" is what makes a zoom pair legible
        /// while "− and =" is not, and because apps name the same key both ways.
        let shiftLabel: String
        init(_ label: String, _ match: [String]? = nil, _ width: CGFloat = 1,
             fnMatch: [String] = [], shiftLabel: String = "") {
            self.label = label
            self.match = match ?? [label]
            self.width = width
            self.fnMatch = fnMatch
            self.shiftLabel = shiftLabel
        }
    }

    struct Row {
        let caps: [Cap]
        let leadingGap: CGFloat
        init(_ caps: [Cap], leadingGap: CGFloat = 0) {
            self.caps = caps
            self.leadingGap = leadingGap
        }
    }

    /// The board actually drawn. Loaded from data/keyboard.json when present, which is
    /// written on first run from the default below.
    ///
    /// This is a file rather than a constant because the physical truth is the user's,
    /// not mine: HHKB ships several arrangements, the Keymap Tool rewrites the board in
    /// firmware, and a layout I guessed wrong teaches the wrong finger movement — which
    /// is worse than showing a list.
    static var current: [Row] = builtinHHKBUS

    static func load() {
        let url = DataDir.url.appendingPathComponent("keyboard.json")
        guard let data = try? Data(contentsOf: url) else { writeDefault(to: url); return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["rows"] as? [[String: Any]] else {
            debugLog("keyboard.json unreadable — keeping the built-in layout")
            return
        }
        var parsed: [Row] = []
        for row in rows {
            guard let keys = row["keys"] as? [[String: Any]] else { continue }
            let caps: [Cap] = keys.compactMap { k in
                guard let label = k["label"] as? String else { return nil }
                let width = (k["w"] as? NSNumber)?.doubleValue ?? 1
                let match = (k["match"] as? [String]) ?? [label]
                return Cap(label, match, CGFloat(width),
                           fnMatch: (k["fnMatch"] as? [String]) ?? [],
                           shiftLabel: (k["shiftLabel"] as? String) ?? "")
            }
            parsed.append(Row(caps, leadingGap: CGFloat((row["leadingGap"] as? NSNumber)?.doubleValue ?? 0)))
        }
        if !parsed.isEmpty {
            current = parsed
            debugLog("keyboard.json loaded: \(parsed.count) rows")
        }
    }

    private static func writeDefault(to url: URL) {
        let rows: [[String: Any]] = builtinHHKBUS.map { row in
            ["leadingGap": row.leadingGap,
             "keys": row.caps.map { ["label": $0.label, "match": $0.match, "w": $0.width,
                                     "fnMatch": $0.fnMatch] }]
        }
        let doc: [String: Any] = [
            "_comment": "Fallback layout. Run tools/gen-layout.py to regenerate this from "
                + "qmk_firmware, which is where the measured geometry lives.",
            "name": "HHKB ANSI (fallback)",
            "rows": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: doc,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// 15u wide, five rows. The bottom row is inset by 1u on each side, which is what
    /// gives an HHKB its distinctive silhouette.
    static let builtinHHKBUS: [Row] = [
        Row([Cap("esc", ["⎋", "ESC"]), Cap("1"), Cap("2"), Cap("3"), Cap("4"), Cap("5"),
             Cap("6"), Cap("7"), Cap("8"), Cap("9"), Cap("0"), Cap("-"), Cap("="),
             Cap("\\"), Cap("`")]),
        Row([Cap("tab", ["⇥"], 1.5), Cap("Q"), Cap("W"), Cap("E"), Cap("R"), Cap("T"),
             Cap("Y"), Cap("U"), Cap("I"), Cap("O"), Cap("P"), Cap("["), Cap("]"),
             Cap("delete", ["⌫"], 1.5)]),
        Row([Cap("control", ["⌃"], 1.75), Cap("A"), Cap("S"), Cap("D"), Cap("F"), Cap("G"),
             Cap("H"), Cap("J"), Cap("K"), Cap("L"), Cap(";"), Cap("'"),
             Cap("return", ["↩", "⌤"], 2.25)]),
        Row([Cap("shift", ["⇧"], 2.25), Cap("Z"), Cap("X"), Cap("C"), Cap("V"), Cap("B"),
             Cap("N"), Cap("M"), Cap(","), Cap("."), Cap("/"),
             Cap("shift", ["⇧"], 1.75), Cap("fn", ["fn"])]),
        Row([Cap("◇", ["◇"]), Cap("⌥"), Cap("⌘", ["⌘"], 1.5), Cap("space", ["␣", " "], 6),
             Cap("⌘", ["⌘"], 1.5), Cap("⌥"), Cap("◇", ["◇"])], leadingGap: 1),
    ]

    /// Where a key equivalent sits on this board.
    ///
    /// This lived in HUDPanel, which meant the view knew how keycaps are laid out and how
    /// shifted characters map onto them. It is keyboard knowledge, so it belongs to the
    /// keyboard — and putting it here lets it be tested without an NSView.
    struct Placement {
        let cap: String
        /// The binding names the cap's upper legend ("⌘+" rather than "⌘=").
        let shifted: Bool
        /// Reached by holding Fn — arrows and function keys on a 60% board.
        let viaFn: Bool
    }

    static func locate(_ keyLabel: String) -> Placement? {
        for row in current {
            for c in row.caps {
                if c.match.contains(keyLabel) { return Placement(cap: c.label, shifted: false, viaFn: false) }
                if !c.shiftLabel.isEmpty && c.shiftLabel == keyLabel {
                    return Placement(cap: c.label, shifted: true, viaFn: false)
                }
            }
        }
        // "+" is printed on no cap's match list, but it is Shift-"=" and belongs there.
        if let base = MenuScraper.baseKey(for: keyLabel) {
            for row in current {
                for c in row.caps where c.match.contains(base) {
                    return Placement(cap: c.label, shifted: true, viaFn: false)
                }
            }
        }
        for row in current {
            for c in row.caps where c.fnMatch.contains(keyLabel) {
                return Placement(cap: c.label, shifted: false, viaFn: true)
            }
        }
        return nil
    }

    /// What is drawn on a cap, which is not always the name the code knows it by.
    ///
    /// The chord column writes Control as "^" and Shift as "⇧". A board that spells those
    /// same keys out in English makes the reader translate between two alphabets to get
    /// from "^ H" in the list to the key under their finger — and the board already uses
    /// ⌘ and ⌥ as symbols, so the words were the odd ones out rather than a convention.
    ///
    /// The label stays as it is printed in the layout file, because that is the identity
    /// everything else keys on; only what is painted changes.
    static func legend(for label: String) -> String {
        switch label {
        case "control", "ctrl": return "^"
        case "shift": return "⇧"
        default: return label
        }
    }

    /// Where a cap sits, since a label does not identify one: a board has two ⌘ caps and
    /// they are both called ⌘.
    struct CapPosition: Hashable {
        let row: Int
        let index: Int
    }

    private static let modifierCaps: [(Shortcut.Mods, Set<String>)] = [
        (.function, ["fn"]),
        (.control,  ["control", "ctrl", "⌃"]),
        (.option,   ["⌥", "option", "alt"]),
        (.shift,    ["shift", "⇧"]),
        (.command,  ["⌘", "command", "cmd"]),
    ]

    /// The caps a held combination is pressing down.
    ///
    /// When the event named a side, only that key lights — pressing the right ⌘ should
    /// look like pressing the right ⌘. When it did not, both light: an unknown side is
    /// not evidence that the other one is up, and inventing a hand is worse than showing
    /// two candidates.
    static func caps(holding mods: Shortcut.Mods,
                     sides: Shortcut.Sides = .unknown) -> Set<CapPosition> {
        var out: Set<CapPosition> = []
        for (mod, labels) in modifierCaps where mods.contains(mod) {
            var found: [CapPosition] = []
            for (r, row) in current.enumerated() {
                for (i, cap) in row.caps.enumerated() where labels.contains(cap.label) {
                    found.append(CapPosition(row: r, index: i))
                }
            }
            switch sides.side(of: mod) {
            case .left  where found.count > 1: out.insert(found.first!)
            case .right where found.count > 1: out.insert(found.last!)
            default: out.formUnion(found)
            }
        }
        return out
    }

    /// Whether F1–F12 reach applications as function keys.
    ///
    /// macOS spends F1–F12 on brightness, Mission Control and volume unless "Use F1, F2,
    /// etc. keys as standard function keys" is on. A laptop escapes that by holding fn —
    /// but this board resolves fn in its own firmware and never tells macOS (measured:
    /// five presses, zero events), so with the setting off there is no way to send F3 at
    /// all. Fn+3 arrives as Mission Control, and ⌥ on top of it opens System Settings,
    /// which is exactly what pressing what the panel called "⌥F3" did.
    ///
    /// Read each time rather than cached: it is a checkbox the user can flip mid-session,
    /// and cfprefsd invalidates the value across processes when they do.
    static var functionKeysAreStandard: Bool {
        CFPreferencesGetAppBooleanValue("com.apple.keyboard.fnState" as CFString,
                                        kCFPreferencesAnyApplication, nil)
    }

    /// Total width in units, derived rather than assumed: an edited layout may differ.
    static var widthUnits: CGFloat {
        current.reduce(0) { w, row in
            max(w, row.leadingGap + row.caps.reduce(0) { $0 + $1.width })
        }
    }
}

/// Draws the board and lights the caps that currently do something.
final class KeymapView: NSView {
    struct Lit {
        let emphasis: LearningStore.Emphasis
        let enabled: Bool
        /// True when the binding names the upper legend ("⌘+" rather than "⌘="), so the
        /// cap can emphasise the half that is actually in play.
        var shifted = false
    }

    var theme: Theme = .builtin
    /// keycap label (as printed) -> strongest state among the shortcuts on that key.
    var lit: [String: Lit] = [:]
    /// Same, for bindings reached through Fn. Drawn as a corner badge so the cap can show
    /// both at once — ⌘F and ⌘F5 live on different layers of the same key.
    var litFn: [String: Lit] = [:]
    /// Caps that carry a binding under some *other* modifier combination. Drawn as a thin
    /// outline: a dark key that means "nothing here" and a dark key that means "something
    /// here, but not with what you are holding" are different answers, and collapsing
    /// them forces the user to try every combination to find anything.
    var hasOtherCombo: Set<String> = []
    /// The modifier caps currently down, by position — a label cannot name one of two
    /// ⌘ caps. Drawn inverted, the way a pressed key is drawn everywhere: the board should
    /// show the hand that is on it, not just what that hand unlocked.
    var held: Set<KeyboardLayout.CapPosition> = []
    var unit: CGFloat = 30

    override var isFlipped: Bool { true }

    /// Derived from the loaded rows, not a constant: an edited layout may be a different
    /// width, and a fixed 15u would clip it.
    var boardSize: NSSize {
        let widest = KeyboardLayout.current.reduce(CGFloat(0)) { w, row in
            max(w, row.leadingGap + row.caps.reduce(0) { $0 + $1.width })
        }
        return NSSize(width: max(widest, 1) * unit,
                      height: CGFloat(KeyboardLayout.current.count) * unit)
    }

    override var intrinsicContentSize: NSSize { boardSize }

    override func draw(_ dirtyRect: NSRect) { drawBoard() }

    /// Callable without being installed in a view hierarchy, so the panel can
    /// draw the board as part of one computed layout.
    func drawBoard() {
        let gap: CGFloat = max(2, unit * 0.06)
        var y: CGFloat = 0

        for (r, row) in KeyboardLayout.current.enumerated() {
            var x = row.leadingGap * unit
            for (i, cap) in row.caps.enumerated() {
                let rect = NSRect(x: x + gap / 2, y: y + gap / 2,
                                  width: cap.width * unit - gap, height: unit - gap)
                draw(cap: cap, at: KeyboardLayout.CapPosition(row: r, index: i), in: rect)
                x += cap.width * unit
            }
            y += unit
        }
    }

    private func draw(cap: KeyboardLayout.Cap, at position: KeyboardLayout.CapPosition,
                      in rect: NSRect) {
        // A binding on the Fn layer lights the cap exactly as a base-layer one does. It
        // used to tint only the small legend, so ⌥Z filled a key while ⌥↑ — which is the
        // same press away — left `[` looking dark. Two bindings equally available should
        // be equally findable; which layer they happen to sit on is the legend's business,
        // not the fill's.
        let base = lit[cap.label]
        let viaFn = litFn[cap.label]
        let onFnLayer = base == nil && viaFn != nil
        let state = base ?? viaFn
        // Square, outlined and bevelled in the retro idiom. A keycap of the era was a
        // rectangle with a hairline round it and one pixel of highlight and shadow — the
        // whole of its three-dimensionality — and that reads as a key far more strongly
        // than a soft rounded rectangle does.
        let corner: CGFloat = theme.retro ? 0 : 4
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

        // Unlit caps are drawn, not omitted: the shape of the board is what makes the
        // lit ones locatable, and the darkness is the progress signal.
        var fill = theme.surface
        var textColor = theme.dim
        var weight: NSFont.Weight = .regular

        // A held modifier is drawn inverted — the brightest thing on the board, because
        // it is the one key the eye should be able to find without looking for it. It is
        // deliberately not one of the learning colours: those say how well you know a
        // binding, and this says nothing about knowledge, only about what is down right
        // now. Reusing orange here would make the board tell two different stories in the
        // same hue.
        let isHeld = held.contains(position)
        if isHeld {
            fill = theme.text
            textColor = theme.background
            weight = .bold
        } else if let state {
            switch state.emphasis {
            case .learning(let recency):
                // Same ramp as the header meter: the cap's colour is how far along it is.
                let hue = theme.retro ? theme.rainbowStop(recency) : theme.learning
                fill = hue.withAlphaComponent((0.25 + 0.6 * recency) * (state.enabled ? 1 : 0.4))
                textColor = theme.text
                weight = .semibold
            case .hallOfFame:
                // Graduated keys sink back into the board. This is the whole point.
                fill = theme.surface
                textColor = theme.dim
            case .none:
                fill = theme.secondary.withAlphaComponent(state.enabled ? 0.28 : 0.12)
                textColor = theme.text
            }
        }

        fill.setFill()
        path.fill()

        if theme.retro {
            NSColor.white.withAlphaComponent(isHeld ? 0.18 : 0.5).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
            NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            NSColor.black.withAlphaComponent(0.2).setFill()
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
            theme.text.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: corner, yRadius: corner)
            outline.lineWidth = 1
            outline.stroke()
        }

        // A cap carrying a binding under some *other* combination is drawn as a fainter
        // version of a lit one, not outlined. An outline is a third visual language the
        // reader has to be taught; brightness is already the language of this board —
        // brighter means more relevant to what you are holding.
        if state == nil && !isHeld && hasOtherCombo.contains(cap.label) {
            theme.secondary.withAlphaComponent(0.14).setFill()
            path.fill()
        }

        let printed = KeyboardLayout.legend(for: cap.label)
        let size = min(unit * 0.34, printed.count > 2 ? unit * 0.24 : unit * 0.38)
        // The theme's face is used at the regular weight and the system face for anything
        // heavier — the same rule PanelStyle applies, and for the same reason: a themed
        // terminal face has one thin weight, so asking it for bold silently returned
        // regular. Every held cap, the brightest thing on the board by design, was drawing
        // in the same weight as the dark ones around it.
        func makeFont(_ pt: CGFloat) -> NSFont {
            guard weight == .regular, let family = theme.fontFamily,
                  let themed = NSFont(name: family, size: pt) else {
                return .systemFont(ofSize: pt, weight: weight)
            }
            return themed
        }

        // When the binding in play is on the Fn layer, the printed legends step back: the
        // answer to "what do I press" is the Fn legend, and `/` beside a live `↓` competes
        // with it. Same rule the two printed legends already follow — the one the binding
        // names is strong, the others are muted — extended to the third legend.
        let baseTint: CGFloat = onFnLayer ? 0.35 : 1

        if cap.shiftLabel.isEmpty {
            let str = NSAttributedString(string: printed, attributes: [
                .font: makeFont(size),
                .foregroundColor: textColor.withAlphaComponent(baseTint)])
            let s = str.size()
            // Out of the middle when the Fn legend is taking it.
            str.draw(at: NSPoint(x: rect.midX - s.width / 2,
                                 y: onFnLayer ? rect.minY + unit * 0.10
                                              : rect.midY - s.height / 2))
        } else {
            // Both legends, stacked as they are printed on the keycap. Whichever one the
            // current binding names is drawn at full strength and the other is muted, so
            // "⌘+" reads off the board as the pair beside "⌘−" instead of as a bare "=".
            let usingShift = state?.shifted ?? false
            let strong = textColor.withAlphaComponent(baseTint)
            let weak = textColor.withAlphaComponent(0.4 * baseTint)
            let upper = NSAttributedString(string: cap.shiftLabel, attributes: [
                .font: makeFont(size * 0.8),
                .foregroundColor: state == nil ? weak : (usingShift ? strong : weak)])
            let lower = NSAttributedString(string: printed, attributes: [
                .font: makeFont(size * 0.8),
                .foregroundColor: state == nil ? textColor.withAlphaComponent(baseTint)
                    : (usingShift ? weak : strong)])
            let us = upper.size(), ls = lower.size()
            upper.draw(at: NSPoint(x: rect.midX - us.width / 2, y: rect.minY + unit * 0.10))
            lower.draw(at: NSPoint(x: rect.midX - ls.width / 2, y: rect.maxY - ls.height - unit * 0.10))
        }

        // The Fn layer, printed on the cap the way HHKB prints it on the keycap's front
        // face. It used to be an unnamed dot, which said "something is here" without
        // saying what — and the list compensated by writing "fn ⌥ ⌘ [", which read as a
        // modifier you hold and raised the exact question it was trying to answer.
        //
        // Printing the legend answers both at once: ↑ on the `[` cap says where ↑ is, and
        // the drawing now matches what is physically under the user's fingers, so a wrong
        // layout is visible rather than merely suspected.
        //
        // The Fn layer is drawn only while it is the answer to something.
        //
        // It was printed on every cap that has one, the way HHKB prints it on the keycap's
        // front face. That put ↖ on K and ⇞ on L — glyphs that read as arrows on keys that
        // have none — a ⌦ on the backtick and a ⌫ on delete: two dozen marks, almost none
        // of them ever relevant. The reason for printing them all was that it let me check
        // my layout data against the real keycaps, which is my problem, not something to
        // charge the reader for on every keypress.
        //
        // When it is live it becomes the cap's main legend, because a lit `/` with nothing
        // to explain it is a riddle: the list says ↓ and the board has to be the sentence
        // that connects ↓ to that key.
        if viaFn != nil, let fnLegend = cap.fnMatch.first, !fnLegend.isEmpty {
            // Both layers can be live on one cap: in Finder, ⌘[ is 戻る and ⌘↑ is
            // 内包しているフォルダ, and they share the `[` key. Drawing the Fn legend only
            // when the base layer was *empty* meant the list showed a "⌘ ↑" row and the
            // board had no ↑ anywhere on it — the exact riddle this legend exists to
            // prevent. When both are live the Fn legend moves to the corner so it does not
            // sit on top of the printed one.
            let both = base != nil
            let legend = NSAttributedString(string: fnLegend, attributes: [
                .font: makeFont(both ? size * 0.55 : size), .foregroundColor: textColor])
            let ls = legend.size()
            legend.draw(at: both
                ? NSPoint(x: rect.maxX - ls.width - unit * 0.08, y: rect.maxY - ls.height - unit * 0.02)
                : NSPoint(x: rect.midX - ls.width / 2, y: rect.midY - ls.height / 2))
        }
    }
}
