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
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = CompanionProductCopy.timeReview
        w.minSize = NSSize(width: 600, height: 500)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace]
        w.center()
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
        w.contentViewController = hostingController
        contentController = hostingController
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
