import AppKit

/// Hit testing for the island panel's frame.
///
/// The panel is pinned to the top edge of the display, so the interesting
/// case is a cursor parked on the very top scanline: it sits exactly on the
/// frame's `maxY`, and `NSRect.contains` excludes that edge. Treating it as
/// "outside" made the hover-expanded panel collapse on its own under a
/// pointer that never moved (reported as "鼠标放在顶部屏幕边缘的时候，会弹出，
/// 然后又会自己缩掉").
enum IslandHitTest {
    /// Default slack, in points. Larger than the sub-pixel difference
    /// between the hardware notch edge and the reported screen top, small
    /// enough that a deliberate move away still reads as an exit.
    static let defaultTolerance: CGFloat = 2

    static func contains(frame: NSRect, point: NSPoint, tolerance: CGFloat = defaultTolerance) -> Bool {
        frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
}
