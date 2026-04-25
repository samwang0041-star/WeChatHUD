import AppKit
import SwiftUI

/// Manages the independent retrospective NSWindow (Plan M6.2). True
/// `NSWindow` (not `NSPanel`) so it doesn't inherit FloatingPanel's
/// hover-dismiss behavior — Spec §2.2.
@MainActor
final class RetrospectiveWindowManager {

    static let shared = RetrospectiveWindowManager()

    private var window: NSWindow?
    private var delegateProxy: WindowDelegateProxy?

    private init() {}

    func showWindow(monitor: ChatMonitor) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = RetrospectiveWindow().environmentObject(monitor)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "复盘"
        w.contentView = NSHostingView(rootView: view)
        w.center()
        let proxy = WindowDelegateProxy { [weak self] in
            self?.window = nil
            self?.delegateProxy = nil
        }
        w.delegate = proxy
        delegateProxy = proxy
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        window = nil
        delegateProxy = nil
    }
}

private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
