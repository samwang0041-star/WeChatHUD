import AppKit

/// Geometry of the target screen's notch (or a sensible fake for
/// external / non-notched displays). The pill uses this to decide
/// where to sit, how wide the middle void should be, and how tall the
/// resting bar renders — so the left/right wings flanking the notch
/// always line up with the hardware cutout on notched Macs and with a
/// consistent visual on everything else.
struct NotchGeometry {
    /// True when the target screen actually has a physical notch
    /// (reported via `safeAreaInsets.top > 0`). False on external
    /// monitors, older MacBooks, iMacs, and Mac mini — those fall
    /// back to a fake-notch metric.
    let hasRealNotch: Bool

    /// Horizontal extent of the notch in screen-space points. On
    /// notched Macs this is the gap between the auxiliaryTopLeftArea
    /// and auxiliaryTopRightArea. Fake: 200pt (roughly matches real
    /// 14"/16" MBP dimensions so the bar's middle void looks
    /// proportionally similar).
    let notchWidth: CGFloat

    /// Vertical extent of the notch in points. On notched Macs this
    /// is `safeAreaInsets.top` (typically 32-38pt depending on the
    /// display). Fake: 32pt.
    let notchHeight: CGFloat

    /// Screen-space x coordinate of the notch horizontal center.
    /// Used by `FloatingPanel.positionAtTop()` to align the bar's
    /// middle void with the actual hardware cutout.
    let notchCenterX: CGFloat

    /// Corner radius of the notch in points — matches how Apple
    /// rounds the cutout. Reused for the pill's corner radius so the
    /// two shapes feel cohesive.
    var cornerRadius: CGFloat { 10 }

    /// Compute geometry for the given screen. Falls back to a fake
    /// notch when no hardware notch is present so the bar still has
    /// a well-defined middle void to render its wings around.
    static func detect(on screen: NSScreen) -> NotchGeometry {
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            let leftArea = screen.auxiliaryTopLeftArea ?? .zero
            let rightArea = screen.auxiliaryTopRightArea ?? .zero
            let width: CGFloat
            let centerX: CGFloat
            if leftArea.width > 0 && rightArea.width > 0 {
                width = rightArea.minX - leftArea.maxX
                centerX = (leftArea.maxX + rightArea.minX) / 2
            } else {
                // Fallback when the auxiliary areas aren't reported
                // (unusual but seen on some third-party display setups).
                width = 200
                centerX = screen.frame.midX
            }
            return NotchGeometry(
                hasRealNotch: true,
                notchWidth: width,
                notchHeight: safeTop,
                notchCenterX: centerX
            )
        }
        // External / non-notched displays: collapse the middle
        // void to a small breathing-space gap. A full-size fake
        // notch (~200pt) just reads as wasted space when there's
        // no hardware cutout to justify it, but zero gap glues
        // the buddy to the summary text. 16pt keeps the pill
        // cohesive while leaving a small visual break between
        // left and right content.
        return NotchGeometry(
            hasRealNotch: false,
            notchWidth: 16,
            notchHeight: 32,
            notchCenterX: screen.frame.midX
        )
    }
}
