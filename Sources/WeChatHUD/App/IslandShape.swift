import SwiftUI

/// SwiftUI `Shape` for the Dynamic Island silhouette — a pill whose
/// top edge has a notch-shaped cutout at the center. Rendered as the
/// black background of the whole HUD so the visual silhouette is the
/// same on every display:
///
///   - On a notched MacBook, the drawn notch aligns perfectly with
///     the hardware cutout (same width, same inner corner radius),
///     and the wings extend past the notch's left/right edges.
///   - On an external or non-notched display, the drawn notch is
///     the *only* way the user sees the island metaphor — without
///     rendering it explicitly, the middle just reads as empty
///     wasted space.
///
/// The shape is parameterised by the real notch geometry, so the
/// silhouette scales naturally from a 14" MBP notch (smaller) to a
/// 16" MBP notch (wider).
struct IslandShape: Shape {
    /// Horizontal width of the notch cutout at the top-center.
    let notchWidth: CGFloat
    /// Vertical depth of the notch cutout from the top edge.
    let notchHeight: CGFloat
    /// Corner radius of the pill's bottom-left / bottom-right.
    /// Top corners are always flat — the pill is flush with the
    /// screen's top edge.
    let pillCornerRadius: CGFloat
    /// Corner radius of the notch's inner bottom corners. Apple's
    /// notch uses ~10pt; matching it here makes the silhouette
    /// read as the same object regardless of display.
    let notchCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let nW = max(0, notchWidth)
        let nH = max(0, notchHeight)
        let nCR = min(notchCornerRadius, nH)
        let pCR = min(pillCornerRadius, min(w, h) / 2)

        let notchLeft = (w - nW) / 2
        let notchRight = (w + nW) / 2

        // Start at the top-left corner (flat — no rounding).
        p.move(to: CGPoint(x: 0, y: 0))

        // Top edge, heading right, stops at the notch's left lip.
        if nW > 0 {
            p.addLine(to: CGPoint(x: notchLeft, y: 0))
            // Down the left wall of the notch, leaving room for
            // the inner corner arc.
            p.addLine(to: CGPoint(x: notchLeft, y: nH - nCR))
            // Inner bottom-left arc — curves INTO the pill.
            p.addArc(
                center: CGPoint(x: notchLeft + nCR, y: nH - nCR),
                radius: nCR,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )
            // Bottom edge of the notch.
            p.addLine(to: CGPoint(x: notchRight - nCR, y: nH))
            // Inner bottom-right arc.
            p.addArc(
                center: CGPoint(x: notchRight - nCR, y: nH - nCR),
                radius: nCR,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true
            )
            // Up the right wall of the notch, back to the top edge.
            p.addLine(to: CGPoint(x: notchRight, y: 0))
        }

        // Top edge from the notch's right lip to the pill's top-right.
        p.addLine(to: CGPoint(x: w, y: 0))
        // Right edge down to where the bottom-right corner starts.
        p.addLine(to: CGPoint(x: w, y: h - pCR))
        // Bottom-right corner.
        p.addArc(
            center: CGPoint(x: w - pCR, y: h - pCR),
            radius: pCR,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge.
        p.addLine(to: CGPoint(x: pCR, y: h))
        // Bottom-left corner.
        p.addArc(
            center: CGPoint(x: pCR, y: h - pCR),
            radius: pCR,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Close up the left edge.
        p.closeSubpath()

        return p
    }
}
