import Cocoa

/// Colours, modelled as base16 slots.
///
/// base16 (tinted-theming) is the closest thing this space has to a real specification:
/// base00–base0F carry *fixed semantic meanings*, ~230 schemes exist, and ~70 apps ship
/// templates for it. That semantic guarantee is the whole reason to model on it rather
/// than on raw ANSI indices — "palette 3 is orange-ish" is a convention that happens to
/// hold in most themes, whereas base0A *is* the warning colour by definition. Mapping
/// the learning states onto slots therefore stays coherent across every scheme instead
/// of only the ones that happen to be conventional.
///
/// Loading works from three sources, in order of fidelity:
///   1. a base16 scheme file — exact, the slots are what the author wrote
///   2. a Ghostty theme file — approximate; see `fromANSI` for what is inferred
///   3. the built-in default
struct Theme {
    var name: String
    var slots: [String: NSColor]
    var fontFamily: String?
    /// Whether to draw in the idiom of the era this palette comes from: square corners,
    /// a hairline outline on every filled shape, and a one-pixel bevel instead of a blur.
    ///
    /// A flag rather than a second set of colour slots, because what makes a 1987 screen
    /// look like 1987 is not only its palette. The same six colours drawn with soft
    /// shadows and 8pt corner radii read as a modern app that likes beige.
    var retro = false

    /// The 1977 logo, top stripe first. Not derived from the base16 slots: those carry
    /// semantics ("this is the warning colour") and this carries an order, which is the
    /// whole point of it — the stripes only read as the logo when they run green to blue.
    var rainbow: [NSColor] {
        ["61bb46", "fdb827", "f5821f", "e03a3e", "963d97", "009ddc"]
            .compactMap { Theme.color(hex: $0) }
    }

    /// Which stripe a progress value falls on, 0 at green and 1 at blue.
    ///
    /// Snapped, not blended. Interpolating between the stops produced colours that are not
    /// on the logo at all — the midpoint of red and purple is a muddy magenta — so half of
    /// what the panel showed was off-palette and the whole thing read as washed out. Six
    /// steps also matches what the header meter counts in, so a row and a cell at the same
    /// progress are the same colour rather than nearly the same.
    func rainbowStop(_ t: Double) -> NSColor {
        let stops = rainbow
        guard !stops.isEmpty else { return .systemBlue }
        let i = Int(min(max(t, 0), 0.999) * Double(stops.count))
        return stops[min(i, stops.count - 1)]
    }

    // Semantic accessors. Everything the UI draws goes through these, so retheming is a
    // data change rather than a code change.
    var background: NSColor { slot("base00", .windowBackgroundColor) }
    var surface: NSColor { slot("base01", .controlBackgroundColor) }
    var dim: NSColor { slot("base03", .tertiaryLabelColor) }
    var secondary: NSColor { slot("base04", .secondaryLabelColor) }
    var text: NSColor { slot("base05", .labelColor) }
    /// base0D — blue, "in progress". Used by themes that are not drawn on the stripes.
    var learning: NSColor { slot("base0D", .controlAccentColor) }
    /// base0E — magenta. Reserved for rust; currently uncoloured by choice, kept here so
    /// the slot is claimed if that decision is revisited.
    var rusty: NSColor { slot("base0E", .systemPurple) }

    private func slot(_ key: String, _ fallback: NSColor) -> NSColor { slots[key] ?? fallback }

    // MARK: - built-in

    /// Tokyo Night, as base16. Chosen as the default because it is what this machine's
    /// Ghostty config already selects, so an unconfigured launch still matches.
    static let builtin = Theme(name: "Tokyo Night (built-in)", slots: hexSlots([
        "base00": "1a1b26", "base01": "15161e", "base02": "33467c", "base03": "414868",
        "base04": "787c99", "base05": "c0caf5", "base06": "cbccd1", "base07": "d5d6db",
        "base08": "f7768e", "base09": "ff9e64", "base0A": "e0af68", "base0B": "9ece6a",
        "base0C": "7dcfff", "base0D": "7aa2f7", "base0E": "bb9af7", "base0F": "d18616",
    ]), fontFamily: nil)

    /// The Macintosh, as it looked before it had colour to spare.
    ///
    /// The greys are System 7's Platinum — a warm beige-grey rather than a neutral one,
    /// which is most of why old screenshots read as "old" at a glance. The accents are the
    /// six stripes of the 1977 Apple logo, in their published order, so the one colour the
    /// panel spends on progress is a colour that belongs to this palette rather than a
    /// modern accent dropped into it.
    ///
    /// Geneva and Monaco ship with macOS to this day. Both are original Macintosh faces,
    /// so the type is period-correct without bundling anything.
    static let classicMac = Theme(name: "Classic Macintosh", slots: hexSlots([
        "base00": "e8e4d8", "base01": "d6d1c2", "base02": "b9b3a2", "base03": "8b8678",
        "base04": "56534a", "base05": "1c1c18", "base06": "f2efe6", "base07": "fbfaf5",
        "base08": "e03a3e", "base09": "f5821f", "base0A": "fdb827", "base0B": "61bb46",
        "base0C": "00a0b0", "base0D": "009ddc", "base0E": "963d97", "base0F": "7b5b3a",
    ]), fontFamily: "Geneva", retro: true)

    // MARK: - loading

    static func load(source: String) -> Theme {
        switch source {
        case "builtin": return builtin
        case "classic": return classicMac
        case "ghostty": return followingGhostty() ?? builtin
        default:
            // Anything else is the name of a Ghostty theme.
            if let t = fromGhosttyTheme(named: source) { return t }
            return builtin
        }
    }

    /// Reads ~/.config/ghostty/config and adopts whatever theme and font it selects, so
    /// the panel matches the terminal the user already looks at all day with no config
    /// of its own.
    static func followingGhostty() -> Theme? {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return nil }
        var themeName: String?
        var font: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard parts.count == 2 else { continue }
            if parts[0] == "theme" { themeName = parts[1] }
            if parts[0] == "font-family" { font = parts[1] }
        }
        guard let themeName, var theme = fromGhosttyTheme(named: themeName) else { return nil }
        theme.fontFamily = font
        theme.name = "\(themeName) (Ghostty)"
        return theme
    }

    static var ghosttyThemeDirectory: URL? {
        let url = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func availableGhosttyThemes() -> [String] {
        guard let dir = ghosttyThemeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    static func fromGhosttyTheme(named name: String) -> Theme? {
        guard let dir = ghosttyThemeDirectory,
              let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        else { return nil }
        var ansi: [Int: NSColor] = [:]
        var background: NSColor?
        var foreground: NSColor?
        var selection: NSColor?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "palette":
                // "palette = 3=#e0af68" arrives here as key "palette", value "3=#e0af68".
                let kv = parts[1].split(separator: "=", maxSplits: 1)
                if kv.count == 2, let idx = Int(kv[0].trimmingCharacters(in: .whitespaces)),
                   let c = color(hex: String(kv[1])) { ansi[idx] = c }
            case "background": background = color(hex: parts[1])
            case "foreground": foreground = color(hex: parts[1])
            case "selection-background": selection = color(hex: parts[1])
            default: break
            }
        }
        guard let background, let foreground, ansi.count >= 8 else { return nil }
        return Theme(name: name,
                     slots: fromANSI(ansi: ansi, background: background,
                                     foreground: foreground, selection: selection),
                     fontFamily: nil)
    }

    /// base16 → ANSI is well defined; this is the other direction, and it is a heuristic.
    /// base16 wants eight greys plus eight accents, while ANSI supplies eight colours and
    /// eight brighter variants, so the greyscale ramp and base09/base0F (orange, brown —
    /// colours ANSI simply does not have) are interpolated rather than read. Schemes
    /// loaded from a real base16 file skip all of this and are exact.
    private static func fromANSI(ansi: [Int: NSColor], background: NSColor,
                                 foreground: NSColor, selection: NSColor?) -> [String: NSColor] {
        func a(_ i: Int, _ fallback: NSColor) -> NSColor { ansi[i] ?? fallback }
        let black = a(0, background)
        let brightBlack = a(8, blend(background, foreground, 0.3))
        let white = a(7, foreground)
        let brightWhite = a(15, foreground)
        let red = a(1, .systemRed)
        let yellow = a(3, .systemYellow)

        return [
            "base00": background,
            "base01": black,
            "base02": selection ?? blend(background, foreground, 0.2),
            "base03": brightBlack,
            "base04": white,
            "base05": foreground,
            "base06": blend(foreground, brightWhite, 0.5),
            "base07": brightWhite,
            "base08": red,
            "base09": blend(red, yellow, 0.5),          // orange: no ANSI equivalent
            "base0A": yellow,
            "base0B": a(2, .systemGreen),
            "base0C": a(6, .systemTeal),
            "base0D": a(4, .systemBlue),
            "base0E": a(5, .systemPurple),
            "base0F": blend(red, background, 0.35),     // brown: no ANSI equivalent
        ]
    }

    // MARK: - colour helpers

    private static func hexSlots(_ dict: [String: String]) -> [String: NSColor] {
        dict.compactMapValues { color(hex: $0) }
    }

    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                       alpha: 1)
    }
}
