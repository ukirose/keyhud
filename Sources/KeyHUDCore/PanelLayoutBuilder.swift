import Cocoa

/// Turns resolved content into placed text.
///
/// Every x-position here is derived from a measured string width, so a label cannot be
/// narrower than what it draws — the failure that four rounds of Auto Layout constraints
/// could not remove is not expressible in this design.
struct PanelLayoutBuilder {
    let style: PanelStyle
    let learning: LearningStore?
    let showProgress: Bool
    let keymap: Bool
    let currentAppKey: String
    /// The frontmost app's icon. Recognised faster than its name is read, and it removes
    /// the need for the name to carry the weight of saying which app this is about.
    let appIcon: NSImage?
    /// Which physical modifier keys are down, when the events said which.
    var heldSides: Shortcut.Sides = .unknown
    /// How tall the panel may get before rows wrap into another column.
    ///
    /// There was no cap at all. `maxHeightFraction` existed in PanelStyle with zero call
    /// sites, and its own comment described a reflow that was never written. Measured on
    /// this display (999pt usable): Finder's twenty ⌘ bindings need 897pt at the default
    /// scale and 1373pt at 特大 — ten of the twenty rows off-screen, split top and bottom
    /// by the centring, with no scrollbar and nothing to say so.
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    /// How wide it may get. Reached by trading titles for fit, in that order: a shortened
    /// word is more readable than a column past the edge of the display, which is the same
    /// judgement `fit(_:within:font:)` already makes for one pathological title.
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    /// Set only by `build` while re-running a layout that came out too wide, which is
    /// what stops it recursing. Not private because a private stored property would make
    /// the memberwise initialiser private too.
    var titleCap: CGFloat?

    private var pad: CGFloat { style.px(18) }
    private var lineGap: CGFloat { style.px(5) }

    /// - Parameter minimum: the frame the panel is already committed to for this hold.
    ///   Blocks centre on the final width, so a page narrower than the frame must be told
    ///   the frame — otherwise it centres on itself and everything slides.
    func build(_ model: PanelContent, allSections: [MenuSection],
               minimum: CGSize = .zero) -> PanelLayout {
        var attempt = self
        var layout = attempt.place(model, allSections: allSections, minimum: minimum)
        guard titleCap == nil else { return layout }

        // Too wide. Give the overflow back out of the title column, split evenly across
        // the columns that are actually drawn — the bucket count is not that number once
        // the height cap has wrapped a bucket into several. Converges in one or two passes;
        // bounded regardless, and it says so when it cannot get there.
        let floor = style.px(60)
        var passes = 0
        while layout.size.width > maxWidth, passes < 3 {
            passes += 1
            let overflow = layout.size.width - maxWidth
            let next = max(floor, attempt.nameLimit - overflow / CGFloat(max(1, layout.columns)))
            guard next < attempt.nameLimit else { break }
            attempt.titleCap = next
            layout = attempt.place(model, allSections: allSections, minimum: minimum)
        }
        if passes > 0 {
            debugLog(String(format: "panel exceeded %.0fpt; titles capped at %.0f after %d pass(es), now %.0f",
                            maxWidth, attempt.nameLimit, passes, layout.size.width))
        }
        if layout.size.width > maxWidth {
            debugLog(String(format: "panel is still %.0fpt wide against a %.0fpt cap — "
                            + "titles are at their floor", layout.size.width, maxWidth))
        }
        return layout
    }

    private var nameLimit: CGFloat { titleCap ?? style.px(style.nameColumnMax) }

    private func place(_ model: PanelContent, allSections: [MenuSection],
                       minimum: CGSize) -> PanelLayout {
        var layout = PanelLayout()
        var y = pad

        // Each piece is one block: placed left-aligned here, centred once the panel's
        // width is known. Nothing can compute its own centre yet — the width depends on
        // the widest of them, including pieces not yet placed.
        var m = layout.mark()
        y = header(model, into: &layout, y: y)
        layout.closeBlock(from: m)

        m = layout.mark()
        y = modifierBar(model, into: &layout, y: y)
        layout.closeBlock(from: m)

        if keymap {
            m = layout.mark()
            y = board(model, allSections: allSections, into: &layout, y: y)
            layout.closeBlock(from: m)
        }

        let columnsTop = y
        var x = pad
        // Seeded with the header/bar bottom, not zero: a panel with no rows — holding ⌃
        // where every ⌃ binding also needs ⌘ — otherwise computed a height of one pad and
        // drew as an empty pill.
        var widest: CGFloat = columnsTop
        // All the columns are one block, so they centre as a group and keep their
        // relative positions — each column's rows stay aligned to their own left edge.
        m = layout.mark()
        var placed = 0
        for group in wrapped(model.grouped(learning: learning), below: columnsTop) {
            let (used, bottom) = column(group, at: CGPoint(x: x, y: columnsTop), into: &layout)
            x += used + style.px(style.columnSpacing)
            widest = max(widest, bottom)
            placed += 1
        }
        layout.closeBlock(from: m)

        layout.columns = placed
        let width = max(minimum.width,
                        max(layout.contentRight + pad,
                            max(x - style.px(style.columnSpacing) + pad,
                                headerWidth(model) + pad * 2)))
        layout.centerBlocks(in: ceil(width))
        layout.finish(size: CGSize(width: ceil(width),
                                   height: max(minimum.height, ceil(widest + pad))))
        return layout
    }

    // MARK: - pieces

    private func headerWidth(_ model: PanelContent) -> CGFloat {
        let font = style.font(style.titleSize, .bold)
        var w = PanelLayout.width("\(model.appName)    \(model.mods.glyphs)", font)
            + (appIcon != nil ? style.px(26) : 0)
        if keymap { w = max(w, KeyboardLayout.widthUnits * style.px(style.keyUnit)) }
        return w
    }

    private func header(_ model: PanelContent, into layout: inout PanelLayout, y: CGFloat) -> CGFloat {
        let font = style.font(style.titleSize, .bold)
        let lineHeight = PanelLayout.height(font)
        var x = pad

        if let appIcon {
            let side = lineHeight
            layout.add(icon: .init(image: appIcon,
                                   rect: CGRect(x: x, y: y, width: side, height: side)))
            x += side + style.px(8)
        }
        // No separator glyph between the name and the modifiers. It was decoration, and
        // at a glance it read as a stray full stop.
        x += layout.add("\(model.appName)    \(model.mods.glyphs)",
                        font: font, color: style.theme.text, at: CGPoint(x: x, y: y))

        if showProgress, let p = model.progress, p.total > 0 {
            x += style.px(14)
            let ratio = CGFloat(p.done) / CGFloat(p.total)
            if style.theme.retro {
                // Six squares, one per stripe, each filling from its left edge.
                //
                // Two earlier shapes each failed one requirement. Six squares that lit
                // whole only moved once every eighteen shortcuts, so most days showed no
                // change at all. A hundred thin cells moved constantly and stopped looking
                // like anything — at that width the gaps close up and it reads as a smear
                // of colour, not as counting. Filling *within* each square keeps the shape
                // that says "six", and still answers "did I get anywhere today".
                //
                // The unfilled part is not coloured at all — six pale stripes read as a
                // washed-out logo rather than as an empty meter, and the eye cannot tell a
                // faint colour from a filled one at this size. Empty is neutral; colour
                // means earned.
                let stripes = style.theme.rainbow
                let side = style.px(13), gap = style.px(4)
                let dotY = y + (PanelLayout.height(font) - side) / 2
                for (i, colour) in stripes.enumerated() {
                    let share = (ratio - CGFloat(i) / CGFloat(stripes.count)) * CGFloat(stripes.count)
                    let filled = min(max(share, 0), 1)
                    let box = CGRect(x: x, y: dotY, width: side, height: side)
                    layout.add(fill: .init(rect: box, color: style.ditheredSurface,
                                           radius: 0, border: style.outline))
                    // The fill is a grid of pixels that light in reading order, not a bar
                    // sliding across. A cell that fills by the pixel is how a machine with
                    // no partial pixels would have shown a fraction, and it makes a single
                    // shortcut learned a visible event rather than a sub-pixel nudge.
                    let grid = 4
                    let lit = Int((Double(filled) * Double(grid * grid)).rounded())
                    if lit > 0 {
                        let inner = box.insetBy(dx: 1, dy: 1)
                        let step = inner.width / CGFloat(grid)
                        let pixel = max(1, (step - style.px(0.6)).rounded())
                        for n in 0..<lit {
                            // Column-major: the leftmost column fills top to
                            // bottom before the next one starts, so the cell
                            // grows left to right like every other meter here.
                            let col = n / grid, row = n % grid
                            layout.add(fill: .init(
                                rect: CGRect(x: inner.minX + CGFloat(col) * step,
                                             y: inner.minY + CGFloat(row) * step,
                                             width: pixel, height: pixel),
                                color: colour, radius: 0))
                        }
                    }
                    x += side + gap
                }
                x += style.px(4)
            } else {
                let barWidth = style.px(90), barHeight = style.px(6)
                let barY = y + (PanelLayout.height(font) - barHeight) / 2
                layout.add(fill: .init(rect: CGRect(x: x, y: barY, width: barWidth, height: barHeight),
                                       color: style.theme.surface, radius: barHeight / 2))
                let filled = barWidth * ratio
                if filled > 0 {
                    layout.add(fill: .init(rect: CGRect(x: x, y: barY, width: max(filled, barHeight),
                                                        height: barHeight),
                                           color: style.theme.learning, radius: barHeight / 2))
                }
                x += barWidth + style.px(8)
            }
            let small = style.font(style.smallSize, .medium)
            _ = layout.add("\(p.done)/\(p.total)", font: small, color: style.theme.secondary,
                           at: CGPoint(x: x, y: y + (PanelLayout.height(font) - PanelLayout.height(small)) / 2))
        }
        return y + PanelLayout.height(font) + lineGap * 2
    }

    private func modifierBar(_ model: PanelContent, into layout: inout PanelLayout,
                             y: CGFloat) -> CGFloat {
        guard model.combinations.count > 1 || model.rows.isEmpty else { return y }
        let font = style.mono(style.bodySize, .bold)
        let h = PanelLayout.height(font) + style.px(6)
        var x = pad
        for entry in model.combinations {
            let label = " \(entry.mods.glyphs) \(entry.count) "
            let w = PanelLayout.width(label, font)
            // The held chip is inverted, matching the held keycaps on the board. It used
            // to be tinted with the learning colour, which made "what I am holding" and
            // "how well I know this" the same hue in the same panel.
            let current = entry.mods == model.mods
            layout.add(fill: .init(rect: CGRect(x: x, y: y, width: w, height: h),
                                   color: current ? style.theme.text : style.ditheredSurface,
                                   radius: style.radius(4), border: style.outline,
                                   bevel: style.theme.retro && !current))
            _ = layout.add(label, font: font,
                           color: current ? style.theme.background : style.theme.text,
                           at: CGPoint(x: x, y: y + style.px(3)))
            x += w + style.px(6)
        }
        return y + h + lineGap * 2
    }

    private func board(_ model: PanelContent, allSections: [MenuSection],
                       into layout: inout PanelLayout, y: CGFloat) -> CGFloat {
        let unit = style.px(style.keyUnit)
        var lit: [String: KeymapView.Lit] = [:]
        var litFn: [String: KeymapView.Lit] = [:]
        func rank(_ e: LearningStore.Emphasis) -> Int {
            switch e {
            case .learning: return 3
            case .none: return 1
            case .hallOfFame: return 0
            }
        }
        for item in model.rows {
            guard let hit = KeyboardLayout.locate(item.keyLabel) else { continue }
            let e = learning?.emphasis(app: currentAppKey, path: item.path) ?? .none
            let existing = hit.viaFn ? litFn[hit.cap] : lit[hit.cap]
            if let existing, rank(existing.emphasis) >= rank(e) { continue }
            let value = KeymapView.Lit(emphasis: e, enabled: item.enabled, shifted: hit.shifted)
            if hit.viaFn { litFn[hit.cap] = value } else { lit[hit.cap] = value }
        }
        let others = model.visibleElsewhere.subtracting(lit.keys).subtracting(litFn.keys)

        layout.add(board: .init(origin: CGPoint(x: pad, y: y), unit: unit,
                                lit: lit, litFn: litFn, hasOtherCombo: others,
                                held: KeyboardLayout.caps(holding: model.mods,
                                                          sides: heldSides)))
        return y + CGFloat(KeyboardLayout.current.count) * unit + lineGap * 3
    }

    /// Splits any group too tall for the screen into further columns of the same bucket.
    ///
    /// Going wider is the right answer here for the same reason it is for a long title:
    /// the panel is drawn once and thrown away, so it can be exactly as large as it needs
    /// to be — but not larger than the display, because past that edge the rows are simply
    /// gone and nothing says so.
    private func wrapped(_ groups: [PanelContent.Group],
                         below top: CGFloat) -> [PanelContent.Group] {
        // A column costs one heading-height offset once, plus one row height per row —
        // not a share of the offset per row. Amortising it over the *bucket count* charged
        // a whole extra body line to every row and cut the usable capacity to about 57%
        // of the truth: twenty bindings that fit in one column were split into 14 and 6.
        let rowHeight = PanelLayout.height(style.font(style.bodySize)) + lineGap
        let heading = PanelLayout.height(style.font(style.sectionSize, .bold)) + lineGap
        let room = maxHeight - top - pad - heading
        guard room > 0, rowHeight > 0 else { return groups }
        // Clamped before the conversion. `maxHeight` defaults to greatestFiniteMagnitude —
        // "no cap" — and `Int(1.8e308 / 26)` is not a large number, it is a trap: the test
        // process died on the first builder constructed without an explicit cap.
        var perColumn = max(1, Int(min(room / rowHeight, 10_000)))

        // Wrapping trades height for width, so the width budget sets a floor on how many
        // rows a column must hold. Without it the two caps fight: the height cap kept
        // adding columns and the width cap kept shrinking titles, and on a small screen at
        // 特大 neither ever won. Height is the one that gives — a panel taller than the
        // budget is still one panel, whereas the columns past the right edge are simply
        // not there.
        let widest = style.px(style.keyColumnWidth) + style.px(10) + nameLimit
            + style.px(style.columnSpacing)
        let columnBudget = max(1, Int(min(max(0, maxWidth - pad * 2) / max(widest, 1), 100)))
        let total = groups.reduce(0) { $0 + $1.items.count }
        if total > perColumn * columnBudget {
            perColumn = Int((Double(total) / Double(columnBudget)).rounded(.up))
            debugLog("panel: \(total) rows will not fit \(columnBudget) columns of "
                     + "\(Int(room / rowHeight)); columns are \(perColumn) rows tall "
                     + "and the panel is taller than its budget")
        }
        guard groups.contains(where: { $0.items.count > perColumn }) else { return groups }

        return groups.flatMap { $0.chunked(into: perColumn) }
    }

    /// Returns the column's width and the y it ended at.
    private func column(_ group: PanelContent.Group, at origin: CGPoint,
                        into layout: inout PanelLayout) -> (CGFloat, CGFloat) {
        let headerFont = style.font(style.sectionSize, .bold)
        let keyFont = style.mono(style.bodySize, .medium)
        let nameFont = style.font(style.bodySize)

        // No column heading. The gauges already say which column is which — full ones on
        // the left, empty ones on the right — and a word naming what the eye has already
        // understood is the same cost as the hint text that was removed for the same
        // reason. `headerFont` stays because the column's top still aligns to where a
        // heading would have sat, keeping the columns level with each other.
        var y = origin.y + PanelLayout.height(headerFont) + lineGap

        // Column geometry from the widest member of each part, measured up front. The
        // chord gets one sub-column per possible symbol so they line up down the list.
        let gapBetweenSegments = style.px(5)
        let segmentWidths: [CGFloat] = Self.segmentOrder.map { glyph in
            group.items.contains { chordSegments($0).contains(glyph) }
                ? PanelLayout.width(glyph, keyFont) : 0
        }
        let keyGlyphWidth = group.items.map { PanelLayout.width(chordSegments($0).last ?? "", keyFont) }
            .max() ?? 0
        let chordWidth = segmentWidths.filter { $0 > 0 }
            .reduce(0) { $0 + $1 + gapBetweenSegments } + keyGlyphWidth
        let keyWidth = max(style.px(style.keyColumnWidth), chordWidth + style.px(8))
        let nameWidth = min(group.items.map { PanelLayout.width($0.title, nameFont) }.max() ?? 0,
                            nameLimit)
        let gap = style.px(10)
        let rowHeight = PanelLayout.height(nameFont) + lineGap

        for item in group.items {

            let emphasis = learning?.emphasis(app: currentAppKey, path: item.path) ?? .none

            // The chip *is* the gauge. They were two things — a coloured background
            // saying "being learned" and a row of pips saying "3 of 5" — occupying the
            // same row and competing for its width. One element carries both: the track
            // marks the item, the fill is how far along it is.
            // One rule for every row: the track is how far there is to go, the fill is how
            // far you have come. The to-learn state used to paint the whole track solid at
            // a score of zero — a gauge reading full while meaning empty — which is why it
            // looked like an achievement instead of a prompt. Now it only tints the track,
            // and the fill still means what it means everywhere else.
            let track = CGRect(x: origin.x, y: y - style.px(2), width: keyWidth, height: rowHeight)
            // Mastered is drawn as ink, not as a colour: a solid black chip with the chord
            // reversed out of it. It used to be a saturated blue block — the loudest thing
            // on the panel, standing for the one row you never need to read. Black states
            // "settled" without competing, and the progress colours stay meaningful because
            // nothing that is finished is wearing one.
            let mastered: Bool = { if case .hallOfFame = emphasis { return true }; return false }()
            layout.add(fill: .init(rect: track,
                                   color: mastered ? style.theme.text
                                       : (style.theme.retro ? style.ditheredSurface
                                          : style.theme.surface.withAlphaComponent(0.55)),
                                   radius: style.radius(3)))
            if !mastered, let score = learning?.score(app: currentAppKey, path: item.path),
               score > 0 {
                let ratio = CGFloat(score) / 100
                // Which stripe this row is on. A single hue asks "why this one?" and has no
                // answer; a position answers it — green is just started, blue is nearly
                // done, and the header's meter counts in the same six.
                let gaugeColour = style.theme.retro
                    ? style.theme.rainbowStop(Double(ratio)) : style.theme.learning
                layout.add(fill: .init(rect: CGRect(x: track.minX, y: track.minY,
                                                    width: max(track.width * ratio, style.px(3)),
                                                    height: track.height),
                                       color: gaugeColour, radius: style.radius(3)))
            }
            // The outline goes on last, over both. Insetting the gauge to keep the hairline
            // visible left a one-pixel gap of track between fill and frame, so the border
            // read as twice as thick wherever the row had been filled and once as thick
            // where it had not — a line that changes weight along its own length.
            if let stroke = style.outline {
                layout.add(fill: .init(rect: track, color: .clear,
                                       radius: style.radius(3), border: stroke))
            }
            // Each symbol in its own sub-column, so ⌥ sits under ⌥ all the way down.
            let segments = chordSegments(item)
            var sx = origin.x + keyWidth - style.px(4) - keyGlyphWidth
            let chordInk = mastered ? style.theme.background : style.theme.text
            _ = layout.add(segments.last ?? "", font: keyFont, color: chordInk,
                           at: CGPoint(x: sx, y: y))
            for (index, glyph) in Self.segmentOrder.enumerated().reversed()
            where segmentWidths[index] > 0 {
                sx -= segmentWidths[index] + gapBetweenSegments
                guard segments.dropLast().contains(glyph) else { continue }
                _ = layout.add(glyph, font: keyFont, color: chordInk,
                               at: CGPoint(x: sx, y: y))
            }

            // Reachable at last: mastered rows used to be removed by `grouped()` before
            // this line could ever see one, so the "dimming is the softer default" that
            // the settings describe had no implementation.
            let dim: CGFloat = {
                if case .hallOfFame = emphasis { return style.masteredRow }
                return 1
            }()
            _ = layout.add(Self.fit(item.title, within: nameLimit, font: nameFont),
                           font: nameFont,
                           color: style.theme.text.withAlphaComponent(dim),
                           at: CGPoint(x: origin.x + keyWidth + gap, y: y))

            y += rowHeight
        }
        let width = keyWidth + gap + nameWidth
        return (width, y)
    }

    /// Shortens a title only if it exceeds the column cap.
    ///
    /// Ordinary menu titles never reach it — the cap is generous precisely so that
    /// widening the panel, not shortening the text, is the normal answer. But a single
    /// pathological entry would otherwise size the panel past the screen, and a panel
    /// wider than the display is less readable than one clipped word.
    private static func fit(_ title: String, within limit: CGFloat, font: NSFont) -> String {
        guard PanelLayout.width(title, font) > limit else { return title }
        var text = title
        while !text.isEmpty, PanelLayout.width(text + "…", font) > limit {
            text.removeLast()
        }
        return text + "…"
    }

    /// The chord, split into one segment per key held.
    ///
    /// There are two different things called fn and this column used to print both as the
    /// same word, at the same place, in the same weight:
    ///
    /// - the fn *modifier*, which macOS puts in chords like fn⌃2 and which this keyboard
    ///   can never send, because it resolves fn in firmware;
    /// - the HHKB's fn *layer*, which is how ↑ is typed here — fn and `[` together produce
    ///   an ordinary Up Arrow, and the host is never told fn was involved.
    ///
    /// The second one works. Printing "fn ⌥ ⌘ [" made it look like the first, because
    /// anything in the run before the key reads as something you hold. So the layer is no
    /// longer written here at all: the row says ⌥ ⌘ ↑, which is what macOS, VS Code and
    /// every other reference call it, and *where* ↑ lives is the board's job — it prints
    /// the fn legend on the `[` cap exactly as the physical keycap does.
    ///
    /// Returned as segments rather than one string so each symbol gets its own column:
    /// ⌥ under ⌥. Right-aligning a single run left every row's glyphs at a different x.
    private func chordSegments(_ item: PanelContent.Visible) -> [String] {
        var out: [String] = []
        if item.mods.contains(.function) { out.append("fn") }
        if item.mods.contains(.control) { out.append("^") }
        if item.mods.contains(.option) { out.append("⌥") }
        if item.mods.contains(.shift) { out.append("⇧") }
        if item.mods.contains(.command) { out.append("⌘") }
        out.append(item.keyLabel)
        return out
    }

    /// Fixed order, so a given symbol always lands in the same column.
    private static let segmentOrder = ["fn", "^", "⌥", "⇧", "⌘"]
}
