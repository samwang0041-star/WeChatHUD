import AppKit
import SwiftUI

/// Manages the independent retrospective NSWindow (Plan M6.2). True
/// `NSWindow` (not `NSPanel`) so it doesn't inherit FloatingPanel's
/// hover-dismiss behavior — Spec §2.2.
@MainActor
final class RetrospectiveWindowManager {

    static let shared = RetrospectiveWindowManager()

    private var window: NSWindow?
    private var contentController: NSViewController?

    /// The shipped window width — 600pt is what the hosting fit computes for
    /// this view (r19/r20 captures measure 1200px @2x). Set explicitly so the
    /// height policy below cannot drift the width with it.
    private static let defaultWidth: CGFloat = 600
    /// The empty state hugged to its card: ink ends at 264pt (measured in the
    /// §88 baseline capture) + the tab view's bottom padding and slack.
    private static let emptyContentHeight: CGFloat = 320
    /// The report at its natural length fills 796pt without scrolling (the r20
    /// capture); anything taller scrolls inside resultView's ScrollView.
    private static let resultContentHeight: CGFloat = 796

    private init() {}

    func showWindow(monitor: ChatMonitor) {
        if let w = window {
            DispatchQueue.main.async {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        let view = RetrospectiveWindow().environmentObject(monitor)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.resultContentHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = CompanionProductCopy.timeReview
        // Short enough for the empty state to hug its card; the report scrolls
        // (RetrospectiveTabView's resultView), so nothing needs more floor than
        // the empty default.
        w.minSize = NSSize(width: 600, height: Self.emptyContentHeight)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace]
        // Disable the default window-show animation to avoid _NSWindowTransformAnimation
        // lifetime crashes when this races with FloatingPanel frame animations.
        w.animationBehavior = .none

        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black

        // Use a hosting controller and retain it explicitly through the
        // manager. This matches AppKit's regular content-controller
        // ownership model and avoids custom close interception around a raw
        // NSHostingView tree.
        let hostingController = NSHostingController(rootView: view)
        // The hosting controller otherwise keeps tracking its fitting size
        // into the window — and this tree's `maxHeight: .infinity` frames
        // over-report that fit as 796pt tall no matter what the content is
        // (§88's dead band). With auto-sizing off, the window keeps exactly
        // the size set below; the view still fills on manual resize.
        hostingController.sizingOptions = []
        w.contentViewController = hostingController
        contentController = hostingController
        // Size to the state at open (§88): the empty card's ink ends at 264pt
        // (baseline capture r19-retro-baseline.png measured 532pt of bare
        // background under it in the old fixed 800×900 default), while the
        // report fills 796pt without scrolling (r20).
        let hasReport = RetrospectiveTabView.runState(from: monitor.hudStore).displayed != nil
        w.setContentSize(NSSize(
            width: Self.defaultWidth,
            height: hasReport ? Self.resultContentHeight : Self.emptyContentHeight
        ))
        w.center()
        // A first generation lands in the window the empty state sized: grow
        // it once to the report height — and only when a report actually
        // exists. The notification fires for every run-list write, including
        // reaps that find nothing, so the height guard alone grew the empty
        // window to a report that was not there. A manual resize is left
        // alone: the guard only fires from the untouched empty default.
        let store = monitor.hudStore
        NotificationCenter.default.addObserver(
            forName: .retrospectiveLiveUpdate, object: nil, queue: .main
        ) { [weak w] _ in
            MainActor.assumeIsolated {
                guard let w, let content = w.contentView,
                      abs(content.frame.height - Self.emptyContentHeight) < 2,
                      RetrospectiveTabView.runState(from: store).displayed != nil else { return }
                w.setContentSize(NSSize(width: Self.defaultWidth, height: Self.resultContentHeight))
            }
        }
        window = w
        // Defer makeKeyAndOrderFront by one runloop tick so any in-flight
        // panel animations finish their CA transaction before AppKit starts
        // a new window-ordering transaction.
        DispatchQueue.main.async {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closeWindow() {
        window?.orderOut(nil)
    }
}
