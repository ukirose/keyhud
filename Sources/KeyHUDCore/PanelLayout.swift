import Cocoa

/// The panel's geometry, computed arithmetically.
///
/// The body used to be a tree of nested NSStackViews. Four separate attempts to stop
/// "Minimize" drawing as "Minimi..." failed — compression resistance, hugging, explicit
/// containers, and finally an exact width constraint measured from the cell — because
/// Auto Layout was resolving the row differently from how it drew it, and every fix was a
/// negotiation rather than an instruction.
///
/// The panel is computed once per keypress, never receives a click, and is thrown away on
/// release. It has no need for a constraint solver. Measuring the text and placing it is
/// both exact and cheaper: the adversarial review measured the old path at 72ms for 27
/// rows and 338ms for 120, all of it constraint solving on the one path that must feel
/// instant.
struct PanelLayout {
    struct Text {
        let string: String
        let font: NSFont
        let color: NSColor
        /// Top-left, in a flipped coordinate space.
        let origin: CGPoint
        let width: CGFloat
    }

    struct Fill {
        var rect: CGRect
        let color: NSColor
        let radius: CGFloat
        /// A hairline around the shape. The era drew every box this way, and it is what
        /// separates two adjacent greys without needing a third one between them.
        var border: NSColor?
        /// A one-pixel light top-left and dark bottom-right, which is how a button was
        /// made to look raised before anyone could afford a blur.
        var bevel: Bool = false

        /// Moved, with everything else about it intact.
        ///
        /// Centring used to rebuild this value field by field, so adding `border` and
        /// `bevel` silently dropped both from every block that gets centred — which is
        /// every block. The outline was in the layout and never on the screen. Shifting a
        /// rectangle is not a reason to restate what it is.
        func offset(dx: CGFloat) -> Fill {
            var moved = self
            moved.rect = rect.offsetBy(dx: dx, dy: 0)
            return moved
        }
    }

    struct Icon {
        let image: NSImage
        let rect: CGRect
    }

    struct Board {
        let origin: CGPoint
        let unit: CGFloat
        let lit: [String: KeymapView.Lit]
        let litFn: [String: KeymapView.Lit]
        let hasOtherCombo: Set<String>
        let held: Set<KeyboardLayout.CapPosition>
    }

    private(set) var texts: [Text] = []
    private(set) var fills: [Fill] = []
    private(set) var board: Board?
    private(set) var icons: [Icon] = []
    private(set) var size: CGSize = .zero
    /// How many columns were placed. Needed to work out how much each title has to give
    /// back when the panel comes out wider than the display.
    var columns = 0

    /// A run of elements that moves as one unit.
    ///
    /// Everything is placed left-aligned first, because a block's width is only known once
    /// it is placed and the panel's width only once every block is. Centring is therefore
    /// a second pass over blocks recorded during the first.
    struct Mark {
        fileprivate let texts: Int, fills: Int, icons: Int, board: Bool
    }
    private var blocks: [(Range<Int>, Range<Int>, Range<Int>, Bool)] = []

    func mark() -> Mark {
        Mark(texts: texts.count, fills: fills.count, icons: icons.count, board: board != nil)
    }

    mutating func closeBlock(from m: Mark) {
        blocks.append((m.texts..<texts.count, m.fills..<fills.count,
                       m.icons..<icons.count, !m.board && board != nil))
    }

    /// Width a string occupies when drawn. Every position in the layout comes from this,
    /// so nothing can be placed somewhere it does not fit.
    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    static func height(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }

    mutating func add(_ string: String, font: NSFont, color: NSColor, at origin: CGPoint) -> CGFloat {
        let w = Self.width(string, font)
        texts.append(Text(string: string, font: font, color: color, origin: origin, width: w))
        return w
    }

    mutating func add(fill: Fill) { fills.append(fill) }
    mutating func add(board: Board) { self.board = board }
    mutating func add(icon: Icon) { icons.append(icon) }
    /// The rightmost edge of anything placed. The panel's width is taken from this rather
    /// than summed from the pieces: the modifier bar was left out of that sum and ran off
    /// the edge whenever it was wider than the columns beneath it. Asking the content
    /// cannot forget a component.
    var contentRight: CGFloat {
        max(texts.map { $0.origin.x + $0.width }.max() ?? 0,
            max(fills.map(\.rect.maxX).max() ?? 0,
                icons.map(\.rect.maxX).max() ?? 0))
    }

    /// Centres each recorded block on the finished panel width.
    ///
    /// The keyboard is a picture of an object, and a picture sitting against the left edge
    /// of a panel wider than itself reads as a mistake. The rest of the panel is centred
    /// with it rather than left alone, because one centred block among left-aligned ones
    /// looks like the accident, not the intent.
    mutating func centerBlocks(in width: CGFloat) {
        for (textRange, fillRange, iconRange, hasBoard) in blocks {
            var left = CGFloat.greatestFiniteMagnitude
            var right = -CGFloat.greatestFiniteMagnitude
            for i in textRange {
                left = min(left, texts[i].origin.x)
                right = max(right, texts[i].origin.x + texts[i].width)
            }
            for i in fillRange {
                left = min(left, fills[i].rect.minX); right = max(right, fills[i].rect.maxX)
            }
            for i in iconRange {
                left = min(left, icons[i].rect.minX); right = max(right, icons[i].rect.maxX)
            }
            if hasBoard, let board {
                left = min(left, board.origin.x)
                right = max(right, board.origin.x + KeyboardLayout.widthUnits * board.unit)
            }
            guard left < right else { continue }
            let dx = (((width - (right - left)) / 2) - left).rounded()
            guard abs(dx) >= 1 else { continue }

            for i in textRange {
                let t = texts[i]
                texts[i] = Text(string: t.string, font: t.font, color: t.color,
                                origin: CGPoint(x: t.origin.x + dx, y: t.origin.y), width: t.width)
            }
            for i in fillRange { fills[i] = fills[i].offset(dx: dx) }
            for i in iconRange { icons[i] = Icon(image: icons[i].image,
                                                 rect: icons[i].rect.offsetBy(dx: dx, dy: 0)) }
            if hasBoard, let b = board {
                board = Board(origin: CGPoint(x: b.origin.x + dx, y: b.origin.y), unit: b.unit,
                              lit: b.lit, litFn: b.litFn, hasOtherCombo: b.hasOtherCombo,
                              held: b.held)
            }
        }
    }

    mutating func finish(size: CGSize) { self.size = size }
}

/// Draws a computed layout. Holds no layout logic of its own, so what is measured in a
/// test is exactly what reaches the screen.
final class PanelView: NSView {
    var layout = PanelLayout()
    var theme: Theme = .builtin
    var cornerRadius: CGFloat = 14

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        theme.surface.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1
        border.stroke()

        // A rainbow band ran across the top here. It was decoration — it carried no
        // information and sat in the reader's eye on every single hold — so it is gone.
        // The stripes now live in the progress meter, where their order means something.

        for fill in layout.fills {
            fill.color.setFill()
            NSBezierPath(roundedRect: fill.rect, xRadius: fill.radius, yRadius: fill.radius).fill()
            if fill.bevel {
                // Drawn before the outline so the outline closes over its ends.
                let r = fill.rect
                NSColor.white.withAlphaComponent(0.55).setFill()
                NSRect(x: r.minX, y: r.minY, width: r.width, height: 1).fill()
                NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
                NSColor.black.withAlphaComponent(0.22).setFill()
                NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
                NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
            }
            if let stroke = fill.border {
                stroke.setStroke()
                let path = NSBezierPath(roundedRect: fill.rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: fill.radius, yRadius: fill.radius)
                path.lineWidth = 1
                path.stroke()
            }
        }
        for icon in layout.icons {
            icon.image.draw(in: icon.rect)
        }
        for text in layout.texts {
            NSAttributedString(string: text.string,
                               attributes: [.font: text.font, .foregroundColor: text.color])
                .draw(at: text.origin)
        }
        if let board = layout.board {
            let view = KeymapView(frame: NSRect(origin: board.origin,
                                                size: NSSize(width: bounds.width, height: bounds.height)))
            view.theme = theme
            view.unit = board.unit
            view.lit = board.lit
            view.litFn = board.litFn
            view.hasOtherCombo = board.hasOtherCombo
            view.held = board.held
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: board.origin.x, yBy: board.origin.y)
            transform.concat()
            view.drawBoard()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
