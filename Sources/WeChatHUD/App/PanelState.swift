import AppKit
import Combine

/// Manages the three-state lifecycle of the floating panel.
@MainActor
final class PanelState: ObservableObject {
    @Published var currentState: HUDState = .compact
    @Published var isMouseInside = false

    private var notificationTimer: Timer?
    private var notificationDuration: TimeInterval = 3

    /// Called when mouse enters the panel area.
    func mouseEntered() {
        isMouseInside = true
        notificationTimer?.invalidate()
        notificationTimer = nil
        // Don't override .detail — the user is inside the full settings view.
        if currentState != .detail {
            currentState = .extended
        }
    }

    /// Called when mouse exits the panel area.
    func mouseExited() {
        isMouseInside = false
        // Don't auto-collapse the detail view — the user may be typing in a
        // text field, etc. The detail view has its own explicit close button.
        if currentState != .detail {
            currentState = .compact
        }
    }

    /// Jump straight to the full-height detail view (e.g. gear click).
    func showDetail() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        currentState = .detail
    }

    /// Dismiss the detail view back to the compact pill.
    func collapse() {
        currentState = .compact
    }

    /// Show a notification banner. Auto-collapses after duration unless mouse enters.
    func showNotification(duration: TimeInterval = 3) {
        notificationDuration = duration
        guard currentState != .detail else { return }  // don't interrupt detail view
        currentState = .notification
        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isMouseInside else { return }
                self.currentState = .compact
            }
        }
    }

    var panelHeight: CGFloat {
        switch currentState {
        case .compact, .extended: return 36
        case .notification: return 90
        case .detail: return 500
        }
    }

    var panelWidth: CGFloat {
        switch currentState {
        case .compact: return 140
        case .extended: return 340
        case .notification: return 420
        case .detail: return 700
        }
    }
}
