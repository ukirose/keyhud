import Cocoa

/// Every metric, weight and opacity the panel draws with.
///
/// These were inline literals scattered through the view code — 0.96 here, 0.35 there,
/// 0.10 + 0.25 × recency somewhere else — so tuning legibility meant hunting through 570
/// lines and the values could not be reasoned about together. Collected here they can be
/// read as a set, which is the only way to tell whether the contrast actually works.
struct PanelStyle {
    let scale: CGFloat
    let theme: Theme

    // Text sizes, before scaling.
    let titleSize: CGFloat = 13
    let bodySize: CGFloat = 12
    let sectionSize: CGFloat = 12
    let smallSize: CGFloat = 11

    // Layout metrics, before scaling.
    let keyColumnWidth: CGFloat = 52
    /// Generous on purpose. A title that does not fit is a title the user cannot read,
    /// and the panel is free to be wider — this exists only so one pathological menu
    /// entry cannot size the whole thing.
    let nameColumnMax: CGFloat = 520
    let keyUnit: CGFloat = 34
    let columnSpacing: CGFloat = 26

    /// Fraction of the screen the panel may occupy before it splits into more columns.
    let maxHeightFraction: CGFloat = 0.8
    /// And the other axis. Splitting a tall list into columns trades height for width, so
    /// capping only one of them moves the overflow rather than removing it: twenty
    /// bindings at 特大 on a 1440pt laptop became ten columns and 2500pt.
    let maxWidthFraction: CGFloat = 0.92

    // Opacities.
    let masteredRow: CGFloat = 0.35

    func px(_ value: CGFloat) -> CGFloat { value * scale }

    /// Corner radius, or none at all. A retro palette drawn with 8pt corners reads as a
    /// modern app that likes beige, so the shape follows the theme rather than the theme
    /// being only a set of colours.
    func radius(_ value: CGFloat) -> CGFloat { theme.retro ? 0 : px(value) }
    /// The hairline every filled box gets in the retro idiom, and nothing gets otherwise.
    var outline: NSColor? { theme.retro ? theme.text.withAlphaComponent(0.75) : nil }

    /// A checkerboard of two colours, which is how a one-bit screen made a grey.
    ///
    /// The Macintosh had two colours and got its greys by alternating them every other
    /// pixel; at the resolutions of the time the eye did the mixing. It is the single most
    /// recognisable mark of the era — more than the beige, more than the type — because no
    /// modern renderer produces it by accident.
    ///
    /// Cached: the pattern is an image, and building one per row per repaint would put
    /// allocation on the path between pressing a key and seeing the panel.
    private static var patterns: [String: NSColor] = [:]

    func dither(_ a: NSColor, _ b: NSColor) -> NSColor {
        guard theme.retro else { return a }
        let cell = max(1, (scale * 1.5).rounded())
        let key = "\(a.description)|\(b.description)|\(cell)"
        if let hit = Self.patterns[key] { return hit }
        let size = NSSize(width: cell * 2, height: cell * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        a.setFill()
        NSRect(origin: .zero, size: size).fill()
        b.setFill()
        NSRect(x: 0, y: 0, width: cell, height: cell).fill()
        NSRect(x: cell, y: cell, width: cell, height: cell).fill()
        image.unlockFocus()
        let colour = NSColor(patternImage: image)
        Self.patterns[key] = colour
        return colour
    }

    /// The surface colour as the era would have mixed it.
    var ditheredSurface: NSColor { dither(theme.surface, theme.background) }

    /// The theme's face is a single thin weight; at panel sizes on a dark background it
    /// vanishes. Anything semibold or heavier therefore falls back to the system face,
    /// which actually has weights.
    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let pt = (size * scale).rounded()
        if weight == .regular || weight == .medium, let family = theme.fontFamily,
           let f = NSFont(name: family, size: pt) { return f }
        return .systemFont(ofSize: pt, weight: weight)
    }

    func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        let pt = (size * scale).rounded()
        if weight == .regular || weight == .medium, let family = theme.fontFamily,
           let f = NSFont(name: family, size: pt) { return f }
        return .monospacedSystemFont(ofSize: pt, weight: weight)
    }
}
