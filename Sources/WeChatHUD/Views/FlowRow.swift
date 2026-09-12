import SwiftUI

/// Minimal wrapping row: lays subviews left-to-right and starts a new line
/// when the next one would cross the proposed width.
///
/// `HStack` never wraps, so a row of actions that has to survive a narrow
/// window either overflows — and gets clipped, taking controls out of reach —
/// or has to be spelled as an explicit grid that wastes space when there are
/// only two or three items. This keeps one wrapping implementation for the
/// whole app instead of a private copy per screen.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var usedWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                usedWidth = max(usedWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += rowWidth > 0 ? spacing + size.width : size.width
            rowHeight = max(rowHeight, size.height)
        }
        usedWidth = max(usedWidth, rowWidth)
        return CGSize(width: usedWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
