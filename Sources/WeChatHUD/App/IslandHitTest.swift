import AppKit

/// Hit testing for the island panel's frame.
///
/// The panel is pinned to the top edge of the display, so two things have to
/// hold at once:
///
/// 1. A cursor parked on the very top scanline sits exactly on the frame's
///    `maxY`. `NSRect.contains` treats that edge as exclusive and reports
///    "outside", which made the hover-expanded panel collapse on its own
///    under a pointer that never moved (reported as "鼠标放在顶部屏幕边缘的
///    时候，会弹出，然后又会自己缩掉"). Every edge here is therefore
///    inclusive, with no slack.
///
/// 2. A cursor any distance past an edge is genuinely outside. This is not
///    cosmetic: the mouse-exit path consults it, and AppKit delivers exactly
///    one exit per hover — so classifying "1 pt outside" as inside discards
///    the only notification that would ever collapse the panel. A slow,
///    deliberate move away crosses the boundary by a fraction of a point and
///    used to strand the panel open; only a fast flick, which crosses several
///    points within a single event, still collapsed.
///
/// Slack cannot buy (1) without breaking (2), so it is exactness — not a
/// tolerance — that makes both hold.
enum IslandHitTest {
    static func contains(frame: NSRect, point: NSPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }
}
