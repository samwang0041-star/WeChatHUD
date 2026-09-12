import AppKit
import CoreGraphics
import simd

/// Pure geometry for the compositor mask that *is* the island while a
/// window-frame spring is in flight.
///
/// Expanding and collapsing used to drive `NSPanel.setFrame` on every vsync.
/// Each setFrame is a window-server round trip that invalidates the hosted
/// SwiftUI tree; a live expand measured 19 ms of that work on the first tick
/// (the hitch the eye reads as "卡帧"). The panel now jumps to the *union*
/// of the current and target frames once, and this type maps the spring's
/// painted rect into that union so a CALayer mask can reveal the same
/// silhouette. Layout happens once, at the destination size; every later
/// tick is a compositor transform.
enum IslandMaskGeometry {
    /// Screen-space union of two window frames, with the same whole-point
    /// rounding AppKit applies to a live `setFrame`. The panel occupies this
    /// rect for the whole run so neither the start nor the end is clipped.
    static func covering(_ a: NSRect, _ b: NSRect) -> NSRect {
        FloatingPanel.rect(from: FloatingPanel.landing(a.union(b)))
    }

    /// Layer-space rect for a painted window frame sitting inside `cover`.
    ///
    /// The covering window's content view is an unflipped `NSView` filling
    /// the frame, so layer space matches AppKit: origin at the bottom-left,
    /// y growing up. A top-aligned island therefore sits at
    /// `y = cover.height - painted.height`, not at y = 0.
    static func layerFrame(painted: NSRect, in cover: NSRect) -> CGRect {
        CGRect(
            x: painted.origin.x - cover.origin.x,
            y: painted.origin.y - cover.origin.y,
            width: max(0, painted.size.width),
            height: max(0, painted.size.height)
        )
    }

    /// Bottom-corner radius of the island mask at `size`. Compact (32 pt)
    /// becomes a capsule; expanded stays a 22 pt pill. Top corners stay
    /// square so the body remains flush with the screen edge.
    static func cornerRadius(for size: CGSize) -> CGFloat {
        IslandMotion.maskCornerRadius(width: size.width, height: size.height)
    }

    /// Hit-testing a cursor against the *visible* island, not the covering
    /// window. While a run is in flight the window is the union, so a raw
    /// `frame.contains` would count empty cover as inside and refuse to
    /// collapse — or, worse, count a cursor parked in the yet-to-grow region
    /// as already hovering.
    static func containsMouse(painted: NSRect, point: NSPoint) -> Bool {
        IslandHitTest.contains(frame: painted, point: point)
    }

    /// SIMD convenience so the display-link tick can stay in the spring's
    /// own units until the last moment.
    static func layerFrame(painted: SIMD4<Double>, in cover: NSRect) -> CGRect {
        layerFrame(painted: FloatingPanel.rect(from: painted), in: cover)
    }
}
