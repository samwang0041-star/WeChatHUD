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
        currentState = .detail
    }

    /// Called when mouse exits the panel area.
    func mouseExited() {
        isMouseInside = false
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
        case .compact: return 36
        case .notification: return 90
        case .detail: return 500
        }
    }

    var panelWidth: CGFloat {
        switch currentState {
        case .compact: return 500
        case .notification: return 500
        case .detail: return 700
        }
    }
}
