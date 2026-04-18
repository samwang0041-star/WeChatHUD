import AppKit
import Combine

/// What kind of content the detail panel is hosting. `.conversation`
/// carries the target chat's username so `DetailPanelView` can hydrate
/// `ConversationDetailView`; `.autopilot` routes to the full autopilot
/// control surface (the same content formerly rendered as a tab).
enum DetailKind: Equatable {
    case conversation(chatUsername: String)
    case autopilot
}

/// Manages the three-state lifecycle of the floating panel.
@MainActor
final class PanelState: ObservableObject {
    @Published var currentState: HUDState = .compact
    @Published var isMouseInside = false
    /// What the detail panel is currently showing. `nil` means no detail
    /// target (either the panel is in compact/extended/notification, or
    /// the caller opened the standalone Settings window).
    @Published var detailKind: DetailKind?
    /// Human-readable chat name — populated alongside `.conversation`
    /// kinds and consumed by `ConversationDetailView` so we don't have
    /// to re-look it up from the whitelist.
    @Published var selectedChatName: String?
    /// Set when returning from > 30 min idle — triggers digest banner.
    @Published var showSmartDigest = false

    /// Back-compat convenience — the chat username when the detail
    /// panel is hosting a `.conversation`, otherwise `nil`. Lets
    /// existing call sites that only care about "is a chat selected?"
    /// keep working without decomposing the enum.
    var selectedChatUsername: String? {
        if case .conversation(let username) = detailKind { return username }
        return nil
    }

    /// Callback to open settings in a separate window.
    var onShowSettings: (() -> Void)?
    /// When set, SettingsView should navigate to this tab on open.
    @Published var pendingSettingsTab: String?

    /// Last time the user actively interacted (mouse entered extended).
    private var lastActiveAt = Date()

    private var notificationTimer: Timer?
    private var notificationDuration: TimeInterval = 3
    private var exitDebounceTimer: Timer?

    /// While set in the future, `mouseEntered` won't re-expand the pill.
    /// Used after we deliberately collapse (e.g. to hand focus over to
    /// WeChat) so the cursor still hovering over our old frame doesn't
    /// immediately pop the panel back open.
    private var reexpandSuppressedUntil: Date?

    /// SwiftUI-measured size of the extended inbox content. Published so
    /// AppDelegate can animate the NSPanel frame to hug the content
    /// exactly (including expanded rows that reveal action buttons).
    /// `.zero` means "not yet measured" — AppDelegate should ignore it.
    @Published var measuredExtendedSize: CGSize = .zero

    /// Transient toast message shown at the top of the panel, typically
    /// to surface silent failures (e.g. WeChatLauncher can't open a
    /// chat because Accessibility isn't granted). Nil = no toast.
    @Published var toastMessage: String? = nil
    private var toastTimer: Timer?

    /// Show a toast that auto-dismisses after `duration` seconds. New
    /// calls replace the previous message and reset the timer, so
    /// spamming doesn't queue up stale messages.
    func showToast(_ message: String, duration: TimeInterval = 4) {
        toastTimer?.invalidate()
        toastMessage = message
        toastTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toastMessage = nil
                self?.toastTimer = nil
            }
        }
    }

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

        // If we just yielded to WeChat, swallow the "enter" that fires
        // when the cursor happens to still be over our old frame.
        if let until = reexpandSuppressedUntil, Date() < until {
            return
        }

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

    /// Open settings in a separate window (gear click).
    func showDetail() {
        onShowSettings?()
    }

    /// Open settings window with the insight tab selected.
    func onShowInsight() {
        pendingSettingsTab = "insight"
        onShowSettings?()
    }

    /// Show detail view for a specific conversation.
    func showChatDetail(chatUsername: String, chatName: String) {
        showDetail(kind: .conversation(chatUsername: chatUsername), chatName: chatName)
    }

    /// Route the detail panel to a specific `DetailKind`. The optional
    /// `chatName` is stored only for `.conversation` kinds (other kinds
    /// ignore it).
    func showDetail(kind: DetailKind, chatName: String? = nil) {
        detailKind = kind
        if case .conversation = kind {
            selectedChatName = chatName
        } else {
            selectedChatName = nil
        }
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        currentState = .detail
    }

    /// Dismiss the detail target (used by back chevrons inside the
    /// detail view). Kept as a separate entry point from `collapse()`
    /// because callers sometimes want to drop back to `.extended`
    /// rather than all the way to `.compact`.
    func clearDetail() {
        detailKind = nil
        selectedChatName = nil
    }

    /// Dismiss the detail view back to the compact bar.
    func collapse() {
        currentState = .compact
    }

    /// Transition directly to the extended inbox, regardless of
    /// current state. Used by in-panel banner buttons that want to
    /// open the inbox without the collapse-then-expand flicker of
    /// `collapse()` + `mouseEntered()`.
    func goExtended() {
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        reexpandSuppressedUntil = nil
        if currentState != .extended {
            currentState = .extended
        }
        lastActiveAt = Date()
    }

    /// Called by HUDRootView's SwiftUI preference-key callback with the
    /// actual rendered size of the extended inbox. AppDelegate observes
    /// this to animate the NSPanel frame to hug the content — so a row
    /// expanding to reveal action buttons grows the panel instead of
    /// being clipped. Dedup at the setter level: avoid re-publishing if
    /// the size hasn't changed (SwiftUI can fire the same value).
    func reportExtendedSize(_ size: CGSize) {
        guard size != .zero, size != measuredExtendedSize else { return }
        measuredExtendedSize = size
    }

    /// Reset the size gate so the next SwiftUI PreferenceKey report
    /// always fires through `removeDuplicates()`. Called by AppDelegate
    /// on compact→extended transitions — SwiftUI rebuilds @State
    /// (expanded rows collapse back), so the rendered content often
    /// differs from the previous session even when the window already
    /// animated to the cached larger size. Without this reset, the
    /// fresh measurement matches `measuredExtendedSize` from the prior
    /// session, Combine dedups it, and the panel stays stuck at the
    /// stale cached height with content centered in a too-tall frame.
    func invalidateMeasuredSize() {
        measuredExtendedSize = .zero
    }

    /// Collapse immediately and ignore any `mouseEntered` that fires in
    /// the next `duration` seconds. Use when we're handing focus to
    /// another app (WeChat) — without this, the cursor still hovering
    /// over our old frame would pop the panel right back open.
    func collapseAndYield(duration: TimeInterval = 1.5) {
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        reexpandSuppressedUntil = Date().addingTimeInterval(duration)
        if currentState != .compact {
            currentState = .compact
        }
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
        case .compact: return 280
        case .extended: return 340
        case .notification: return 420
        case .detail: return 700
        }
    }
}
