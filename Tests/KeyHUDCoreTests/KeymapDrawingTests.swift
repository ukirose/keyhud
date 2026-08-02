import XCTest
import Cocoa
@testable import KeyHUDCore

/// Assertions against the pixels the board actually draws.
///
/// Everything else about the panel is checked from the computed layout, but the keycaps
/// are drawn by `KeymapView` directly and nothing computed describes them. That gap is
/// where an Fn-layer binding ended up tinting a corner legend while a base-layer one
/// filled a whole key — two bindings equally available, one far harder to find, and no
/// test able to tell.
final class KeymapDrawingTests: XCTestCase {
    private let unit: CGFloat = 40

    override func setUp() {
        super.setUp()
        KeyboardLayout.load()
    }

    /// Mirrors `drawBoard`'s walk so a cap can be sampled by name.
    private func rect(ofCap label: String) -> NSRect? {
        var y: CGFloat = 0
        for row in KeyboardLayout.current {
            var x = row.leadingGap * unit
            for cap in row.caps {
                if cap.label == label {
                    return NSRect(x: x, y: y, width: cap.width * unit, height: unit)
                }
                x += cap.width * unit
            }
            y += unit
        }
        return nil
    }

    private func render(lit: [String: KeymapView.Lit] = [:],
                        litFn: [String: KeymapView.Lit] = [:]) -> NSBitmapImageRep {
        let view = KeymapView(frame: NSRect(origin: .zero, size: .zero))
        view.unit = unit
        view.lit = lit
        view.litFn = litFn
        view.frame = NSRect(origin: .zero, size: view.boardSize)
        // Drawn straight into a bitmap context rather than through cacheDisplay: the same
        // entry point the panel itself uses, and it does not need the view in a window.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(view.boardSize.width),
                                   pixelsHigh: Int(view.boardSize.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // The view is flipped; the bitmap context is not, so mirror it to match.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: view.boardSize.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        view.drawBoard()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A point inside the cap but clear of every legend, so only a fill can change it.
    private func fillSample(_ rect: NSRect) -> NSPoint {
        NSPoint(x: rect.minX + rect.width * 0.18, y: rect.midY)
    }

    private func colour(_ rep: NSBitmapImageRep, _ p: NSPoint) -> NSColor {
        rep.colorAt(x: Int(p.x), y: Int(p.y))!
    }

    private func differs(_ a: NSColor, _ b: NSColor) -> Bool {
        let x = a.usingColorSpace(.deviceRGB)!, y = b.usingColorSpace(.deviceRGB)!
        return abs(x.redComponent - y.redComponent)
            + abs(x.greenComponent - y.greenComponent)
            + abs(x.blueComponent - y.blueComponent) > 0.02
    }

    private let bindingHere = KeymapView.Lit(emphasis: .learning(1), enabled: true)

    func testAnFnLayerBindingLightsTheWholeCapLikeABaseLayerOne() {
        guard let bracket = rect(ofCap: "["), let z = rect(ofCap: "Z") else {
            return XCTFail("the loaded layout has no [ or Z cap")
        }
        let dark = render()
        let viaFn = render(litFn: ["[": bindingHere])       // ⌥↑ — fn and [
        let direct = render(lit: ["Z": bindingHere])        // ⌥Z — one key

        XCTAssertTrue(differs(colour(dark, fillSample(bracket)), colour(viaFn, fillSample(bracket))),
                      "an Fn-layer binding must fill the cap, not only tint its legend")
        XCTAssertFalse(differs(colour(dark, fillSample(z)), colour(viaFn, fillSample(z))),
                       "and must not light anything else")

        // The same emphasis reaches the same colour either way, so the eye cannot tell one
        // is somehow lesser.
        XCTAssertFalse(differs(colour(viaFn, fillSample(bracket)), colour(direct, fillSample(z))),
                       "both layers light to the same colour for the same emphasis")
    }

    /// An Fn legend is drawn only while it is usable.
    ///
    /// Printing all twenty-four of them the way the physical keycaps do put ↖ on K and ⇞
    /// on L — glyphs that read as arrows, on keys with no arrow — plus a ⌦ on the backtick
    /// and a ⌫ on delete. Two dozen marks, almost none of them ever relevant. Verifying my
    /// layout data against the real keycaps was my problem, not something to spend the
    /// user's attention on every time the panel opens.
    func testAnUnusedFnLegendIsNotDrawnAtAll() {
        guard let bracket = rect(ofCap: "["), let brace = rect(ofCap: "]") else {
            return XCTFail("no bracket caps")
        }
        // `[` carries an Fn layer and `]` does not; both are 1u with two printed legends.
        // Away from the centre line where those legends sit, an unlit pair must match.
        func corner(_ r: NSRect) -> NSPoint {
            NSPoint(x: r.maxX - unit * 0.18, y: r.maxY - unit * 0.12)
        }
        let dark = render()
        XCTAssertFalse(differs(colour(dark, corner(bracket)), colour(dark, corner(brace))),
                       "an Fn legend nothing is bound to must leave no mark")
    }

    /// It comes back the moment it is the answer to something.
    func testTheFnLegendAppearsWhenItIsUsable() {
        guard let bracket = rect(ofCap: "[") else { return XCTFail("no [ cap") }
        let centre = NSPoint(x: bracket.midX, y: bracket.midY)
        XCTAssertTrue(differs(colour(render(), centre),
                              colour(render(litFn: ["[": bindingHere]), centre)),
                      "a lit cap has to say what it produces, or a lit `[` for ⌥↓ is a riddle")
    }
}
