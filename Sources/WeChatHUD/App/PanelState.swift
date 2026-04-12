import AppKit
import Combine

/// Manages the three-state lifecycle of the floating panel.
@MainActor
final class PanelState: ObservableObject {
    @Published var currentState: HUDState = .compact
    @Published var isMouseInside = false
    /// When set, DetailPanelView shows conversation analysis instead of settings.
    @Published var selectedChatUsername: String?
    @Published var selectedChatName: String?
    /// Set when returning from > 30 min idle — triggers digest banner.
    @Published var showSmartDigest = false

    /// Last time the user actively interacted (mouse entered extended).
    private var lastActiveAt = Date()

    private var notificationTimer: Timer?
    private var notificationDuration: TimeInterval = 3
    private var exitDebounceTimer: Timer?

    /// Exit debounce: the window resize animation takes ~220 ms, during
    /// which the sweeping pill edges can cross the cursor and fire
    /// spurious exited / entered pairs. 400 ms covers the animation window
    /// plus a small buffer; any real mouse-out is cancelled by a follow-up
    /// mouseEntered before the timer fires. 400 ms before collapse is also
    /// forgiving for the user who moves the cursor away briefly to look
    /// at something else then back.
    private let exitDebounce: TimeInterval = 0.4

    /// Called when mouse enters the panel area.
    func mouseEntered() {
        isMouseInside = true
        // Cancel any pending collapse — we're back inside.
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil

        // Smart Digest: if > 30 min since last active, flag for digest
        let idleMinutes = Date().timeIntervalSince(lastActiveAt) / 60
        if idleMinutes >= 30 && currentState == .compact {
            showSmartDigest = true
        }
        lastActiveAt = Date()

        // Don't override .detail — the user is inside the full settings view.
        if currentState != .detail && currentState != .extended {
            currentState = .extended
        }
    }

    /// Called when mouse exits the panel area. Debounces briefly so
    /// animation-induced oscillations don't flicker the state.
    func mouseExited() {
        isMouseInside = false
        // Don't auto-collapse the detail view — the user may be typing in a
        // text field, etc. The detail view has its own explicit close button.
        guard currentState != .detail else { return }

        exitDebounceTimer?.invalidate()
        exitDebounceTimer = Timer.scheduledTimer(withTimeInterval: exitDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Only collapse if the mouse actually stayed outside.
                if !self.isMouseInside && self.currentState == .extended {
                    self.currentState = .compact
                }
                self.exitDebounceTimer = nil
            }
        }
    }

    /// Jump straight to the full-height detail view (e.g. gear click).
    func showDetail() {
        selectedChatUsername = nil
        selectedChatName = nil
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        currentState = .detail
    }

    /// Show detail view for a specific conversation.
    func showChatDetail(chatUsername: String, chatName: String) {
        selectedChatUsername = chatUsername
        selectedChatName = chatName
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
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

    var panelHeight: CGFloat { Self.height(for: currentState) }
    var panelWidth: CGFloat { Self.width(for: currentState) }

    static func height(for state: HUDState) -> CGFloat {
        switch state {
        case .compact, .extended: return 36
        case .notification: return 90
        case .detail: return 500
        }
    }

    static func width(for state: HUDState) -> CGFloat {
        switch state {
        case .compact: return 208
        case .extended: return 340
        case .notification: return 420
        case .detail: return 700
        }
    }
}
