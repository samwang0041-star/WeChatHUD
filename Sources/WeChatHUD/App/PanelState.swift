import AppKit
import Combine

/// What kind of content the detail panel is hosting. `.conversation`
/// carries the target chat's username so `DetailPanelView` can hydrate
/// `ConversationDetailView`; `.autopilot` routes to the full autopilot
/// control surface (the same content formerly rendered as a tab).
enum IslandSurface: Equatable {
    case inbox
    case tasks
    case firstLaunch
}

enum DetailKind: Equatable {
    case conversation(chatUsername: String)
    case autopilot
}

/// A one-shot request to hydrate the composer with a saved reply draft.
/// Keeping this on the routing state lets a draft opened from the workbench
/// update an already-mounted conversation view (where `onAppear` won't fire).
struct ReplyDraftContinuation: Equatable {
    let id: UUID
    let chatUsername: String
    let text: String
    /// The saved reply_drafts row this continuation originated from. Nil means
    /// this was a plain composer hydration and must create a new draft.
    let savedDraftID: Int64?
}

/// Manages the three-state lifecycle of the floating panel.
@MainActor
final class PanelState: ObservableObject {
    @Published var currentState: HUDState = .compact {
        didSet {
            guard oldValue != currentState else { return }
            // Leaving .notification tears down the in-place briefing
            // card: the SwiftUI view unmounts without its onChange
            // firing, so reset both flags here — otherwise a latched
            // popoverOpen would silently block every future banner.
            if oldValue == .notification || oldValue == .detail || oldValue == .extended {
                popoverOpen = false
                briefingExpanded = false
                snoozeMenuExpanded = false
                autopilotPopoverOpen = false
                islandTextInputActive = false
            }
            // Expanding content can swap immediately: the covering window
            // is already at the destination size. Collapsing content must
            // wait for the mask spring to land, or the covering window
            // would show an empty black plate while the island shrinks.
            if currentState != .compact || oldValue == .compact {
                presentedState = currentState
            }
            // Tests and reduce-motion / already-at-size paths never start a
            // frame spring. If no animation has claimed the collapse by the
            // next turn of the run loop, paint the compact surface instead of
            // leaving the outgoing inbox mounted forever.
            if presentedState != currentState {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.presentedState != self.currentState,
                          !self.frameAnimationInProgress else { return }
                    self.presentedState = self.currentState
                }
            }
        }
    }
    /// What SwiftUI currently paints. Matches `currentState` except during
    /// a compacting spring, when the outgoing surface stays mounted until
    /// `frameAnimationEnded`.
    @Published var presentedState: HUDState = .compact
    @Published var isMouseInside = false
    /// What the detail panel is currently showing. `nil` means no detail
    /// target (either the panel is in compact/extended/notification, or
    /// the caller opened the standalone Settings window).
    @Published var detailKind: DetailKind?
    /// Human-readable chat name — populated alongside `.conversation`
    /// kinds and consumed by `ConversationDetailView` so we don't have
    /// to re-look it up from the whitelist.
    @Published var selectedChatName: String?

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
    @Published var pendingDiscussionScope: DiscussionScope?
    /// When opening 待办 from 聊天回顾 / 今日小结, keep the same conversation.
    @Published var pendingDiscussionChatUsername: String?
    /// Hover inbox vs in-island task preview (figures 19 / 20).
    @Published var islandSurface: IslandSurface = .inbox
    /// Figure 41: snooze receipt + undo, shown on the island after 23.
    @Published var islandSnoozeUndo: (item: InboxItem, until: Date)?
    /// Preview-only send receipts for figures 26 / 27.
    @Published var previewSendReceipt: String?
    /// Pending saved-draft hydration. This is consumed by the matching
    /// `ConversationDetailView` after routing, including when that view is
    /// already showing the same chat.
    @Published private(set) var pendingReplyDraftContinuation: ReplyDraftContinuation?

    private var notificationTimer: Timer?
    private var notificationDuration: TimeInterval = 3
    private var notificationGeneration = UUID()
    /// An unsolicited banner owns its duration until the pointer actually
    /// enters it (or the user opens its popover). Frame growth is not an exit.
    private var notificationWasInteractedWith = false
    private var exitDebounceTimer: Timer?
    private var exitGeneration = UUID()

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
    /// Survives invalidateMeasuredSize so compact to extended can reuse the last real size.
    private(set) var lastExtendedSize: CGSize = .zero

    /// SwiftUI-measured rendered height of the notification banner
    /// content (notch padding included). Published so AppDelegate can
    /// size the NSPanel to the banner's real height instead of the
    /// static estimate that used to clip long messages.
    @Published var measuredNotificationSize: CGSize = .zero

    /// Set to `true` after `applicationDidFinishLaunching` has fully
    /// configured the panel (screen, notch geometry, sinks). Until then
    /// the measurement sink ignores any sizes reported by SwiftUI to
    /// avoid reacting to stale geometry produced during window creation.
    @Published var isReady: Bool = false

    /// Transient toast message shown at the top of the panel, typically
    /// to surface silent failures (e.g. WeChatLauncher can't open a
    /// chat because Accessibility isn't granted). Nil = no toast.
    @Published var toastMessage: String? = nil
    private var toastTimer: Timer?

    /// True while an in-place context-briefing card is expanded
    /// (notification banner or conversation detail). Drives the taller
    /// panel frame for .notification via AppDelegate. Set through
    /// setBriefingExpanded(_:) and reset whenever the panel leaves
    /// .notification so a stale expansion can't pin the next banner
    /// open.
    @Published var briefingExpanded: Bool = false
    /// In-island 稍后提醒 menu on the notification/briefing surface.
    /// Grows the notification panel so all three time choices stay visible.
    @Published var snoozeMenuExpanded: Bool = false
    /// NSMenu tracking over the island. Separate from the popover latch so
    /// closing a context menu cannot clobber the Autopilot / briefing latch.
    ///
    /// This flag blocks the hover-exit collapse, so it must never latch.
    /// AppKit's didEndTracking notification is the only thing that clears it,
    /// and that notification is not guaranteed to arrive (app switch, menu
    /// torn down by another process, Cmd-Tab while it is open). A missed end
    /// notification used to pin the panel open with no way back except Esc.
    /// The backstops below clear it on a timeout.
    @Published var menuTrackingOpen: Bool = false {
        didSet {
            guard oldValue != menuTrackingOpen else { return }
            menuTrackingTimeoutTimer?.invalidate()
            menuTrackingTimeoutTimer = nil
            guard menuTrackingOpen else { return }
            menuTrackingTimeoutTimer = Timer.scheduledTimer(
                withTimeInterval: Self.menuTrackingTimeout, repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.endMenuTrackingIfStale()
                }
            }
        }
    }

    /// How long a menu may claim to be tracking before we assume the end
    /// notification was lost. Real menu use is seconds; this is a backstop,
    /// not a UX deadline.
    private static let menuTrackingTimeout: TimeInterval = 60
    private var menuTrackingTimeoutTimer: Timer?

    /// Drops a stale menu latch and re-runs the collapse decision the latch
    /// was blocking.
    func endMenuTrackingIfStale() {
        menuTrackingTimeoutTimer?.invalidate()
        menuTrackingTimeoutTimer = nil
        guard menuTrackingOpen else { return }
        menuTrackingOpen = false
        guard !isMouseInside, !popoverOpen, !islandTextInputActive else { return }
        scheduleExitCollapse()
    }

    /// Autopilot popover on the compact/extended pill. Separate from
    /// `popoverOpen` so closing a snooze menu cannot drop this latch.
    @Published var autopilotPopoverOpen: Bool = false
    /// Rename sheet (or similar) needs the island to accept typing.
    @Published var islandTextInputActive: Bool = false
    /// In-window CompanionDialog is open; sidebar Tab must not leave the dialog.
    @Published var modalDialogOpen: Bool = false

    /// Toggle the in-place briefing card. While a banner is showing,
    /// expansion maps onto popoverOpen so the existing semantics
    /// (pause the auto-dismiss timer, ignore mouse-out collapse) keep
    /// working without a second state machine. In .detail the card
    /// lives inside a scroll view with no auto-collapse, so
    /// popoverOpen is left alone there.
    func setBriefingExpanded(_ expanded: Bool) {
        briefingExpanded = expanded
        if expanded { snoozeMenuExpanded = false }
        switch currentState {
        case .notification:
            popoverOpen = expanded || snoozeMenuExpanded || autopilotPopoverOpen
        case .compact, .extended, .detail:
            break
        }
    }

    func setSnoozeMenuExpanded(_ expanded: Bool) {
        snoozeMenuExpanded = expanded
        refreshTransientIslandHold()
        NotificationCenter.default.post(name: .hudIslandNeedsResize, object: nil)
    }

    func setAutopilotPopoverOpen(_ expanded: Bool) {
        autopilotPopoverOpen = expanded
        refreshTransientIslandHold()
    }

    private func refreshTransientIslandHold() {
        popoverOpen = snoozeMenuExpanded || briefingExpanded || autopilotPopoverOpen
    }

    /// Set to `true` while any SwiftUI popover anchored inside the pill
    /// is visible. Popovers render outside the pill bounds, so the
    /// cursor leaves `isMouseInside` as soon as the user moves toward
    /// the popover content — which would otherwise trigger the
    /// extended→compact collapse and take the popover down with it.
    /// `mouseExited()` honors this flag and skips the collapse.
    @Published var popoverOpen: Bool = false {
        didSet {
            guard oldValue != popoverOpen else { return }
            if popoverOpen, currentState == .notification {
                notificationWasInteractedWith = true
                notificationTimer?.invalidate()
                notificationTimer = nil
            }
            if !popoverOpen {
                scheduleExitCollapseAfterTransientSurfaceClosed()
            }
        }
    }

    private var frameAnimationInProgress = false
    private var exitRequestedDuringFrameAnimation = false

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

    /// Exit debounce: the window resize animation sweeps the frame past
    /// the cursor and fires spurious exited / entered pairs. 220 ms still
    /// forgives a brief look-away but no longer stacks a perceptible pause
    /// on top of the animation itself. Exits that arrive mid-animation are
    /// deferred to `frameAnimationEnded`, where the real hit test decides
    /// — those skip most of this delay via `scheduleExitCollapse(delay:)`.
    private let exitDebounce: TimeInterval = 0.22

    /// Called when mouse enters the panel area.
    func mouseEntered() {
        isMouseInside = true
        if currentState == .notification { notificationWasInteractedWith = true }
        // Cancel any pending collapse — we're back inside. Also clear an
        // exit recorded mid-animation: re-entering means the user is
        // back, and the pending request must not collapse us later.
        exitRequestedDuringFrameAnimation = false
        exitGeneration = UUID()
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil

        // If we just yielded to WeChat, swallow the "enter" that fires
        // when the cursor happens to still be over our old frame.
        if let until = reexpandSuppressedUntil, Date() < until {
            return
        }

        // Don't override .detail — the user is inside the full settings view.
        // Keep the banner under the pointer. Replacing it with the inbox
        // on entry used to remove the very controls the user was aiming at.
        if currentState == .compact {
            CompanionMotion.performHoverTick()
            currentState = .extended
        }
    }

    /// Called when mouse exits the panel area. Debounces briefly so
    /// animation-induced oscillations don't flicker the state.
    func mouseExited() {
        if currentState == .notification, isMouseInside { notificationWasInteractedWith = true }
        isMouseInside = false
        // AppKit can report an exit while the newly expanded frame sweeps
        // past a pointer that never entered this banner. Keep its duration.
        if currentState == .notification, !notificationWasInteractedWith { return }
        // Don't auto-collapse the detail view — the user may be typing in a
        // text field, etc. The detail view has its own explicit close button.
        guard currentState != .detail else { return }
        // Popovers anchored inside the pill render outside the pill's
        // bounds. Moving the cursor toward the popover UI counts as
        // "exit" here; ignore the exit while a popover is open so the
        // pill (and the popover with it) stay put.
        guard !popoverOpen, !menuTrackingOpen, !islandTextInputActive else { return }
        // Task preview and first-launch are opened surfaces; leaving the
        // island must not tuck them away (交互规范：菜单/抽屉打开时不收起).
        guard islandSurface == .inbox else { return }

        if frameAnimationInProgress {
            exitRequestedDuringFrameAnimation = true
            return
        }

        scheduleExitCollapse()
    }

    func frameAnimationStarted() {
        frameAnimationInProgress = true
        exitRequestedDuringFrameAnimation = false
    }

    func frameAnimationEnded(mouseInside: Bool) {
        frameAnimationInProgress = false
        updateMouseInside(mouseInside)
        if presentedState != currentState {
            presentedState = currentState
        }
        guard collapsesWhenMouseOutside else {
            exitRequestedDuringFrameAnimation = false
            return
        }
        if !mouseInside || exitRequestedDuringFrameAnimation {
            exitRequestedDuringFrameAnimation = false
            // The hit test already confirmed the pointer is outside and the
            // user has been waiting through the whole animation — collapse
            // with a minimal re-check delay instead of the full debounce.
            scheduleExitCollapse(delay: 0.08)
        }
    }

    func updateMouseInside(_ inside: Bool) {
        isMouseInside = inside
        if inside, currentState == .notification {
            notificationWasInteractedWith = true
            notificationTimer?.invalidate()
            notificationTimer = nil
        }
    }

    private func scheduleExitCollapse(delay: TimeInterval? = nil) {
        guard collapsesWhenMouseOutside else { return }
        AnimationDebugger.logEvent("scheduleExitCollapse state=\(currentState) mouseInside=\(isMouseInside) exitRequestedDuringAnimation=\(exitRequestedDuringFrameAnimation)")
        exitGeneration = UUID()
        exitDebounceTimer?.invalidate()
        let generation = exitGeneration
        exitDebounceTimer = Timer.scheduledTimer(withTimeInterval: delay ?? exitDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.exitGeneration == generation else { return }
                // Only collapse if the mouse actually stayed outside AND
                // no popover re-opened during the debounce window.
                if !self.isMouseInside && !self.popoverOpen && !self.menuTrackingOpen && !self.islandTextInputActive && self.collapsesWhenMouseOutside && self.islandSurface == .inbox {
                    AnimationDebugger.logEvent("exitDebounce FIRED -> compact")
                    self.currentState = .compact
                }
                self.exitDebounceTimer = nil
            }
        }
    }

    private func scheduleExitCollapseAfterTransientSurfaceClosed() {
        guard !isMouseInside, collapsesWhenMouseOutside else { return }
        if frameAnimationInProgress {
            exitRequestedDuringFrameAnimation = true
        } else {
            scheduleExitCollapse()
        }
    }

    private var collapsesWhenMouseOutside: Bool {
        currentState == .extended || (currentState == .notification && notificationWasInteractedWith)
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

    func requestReplyDraftContinuation(chatUsername: String, text: String, savedDraftID: Int64? = nil) {
        pendingReplyDraftContinuation = ReplyDraftContinuation(
            id: UUID(), chatUsername: chatUsername, text: text, savedDraftID: savedDraftID
        )
    }

    /// Consume only a request for this chat. A request for another chat must
    /// remain pending until that conversation view is mounted.
    func consumeReplyDraftContinuation(for chatUsername: String) -> String? {
        consumeReplyDraftContinuationRequest(for: chatUsername)?.text
    }

    func consumeReplyDraftContinuationRequest(for chatUsername: String) -> ReplyDraftContinuation? {
        guard let pending = pendingReplyDraftContinuation,
              pending.chatUsername == chatUsername else { return nil }
        pendingReplyDraftContinuation = nil
        return pending
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
        exitGeneration = UUID()
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
        exitGeneration = UUID()
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        notificationGeneration = UUID()
        clearDetail()
        islandSurface = .inbox
        popoverOpen = false
        menuTrackingOpen = false
        islandTextInputActive = false
        autopilotPopoverOpen = false
        briefingExpanded = false
        snoozeMenuExpanded = false
        currentState = .compact
    }

    /// Transition directly to the extended inbox, regardless of
    /// current state. Used by in-panel banner buttons that want to
    /// open the inbox without the collapse-then-expand flicker of
    /// `collapse()` + `mouseEntered()`.
    func goExtended() {
        exitGeneration = UUID()
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        reexpandSuppressedUntil = nil
        if currentState != .extended {
            currentState = .extended
        }
    }

    /// Called by HUDRootView's SwiftUI preference-key callback with the
    /// actual rendered size of the extended inbox. AppDelegate observes
    /// this to animate the NSPanel frame to hug the content — so a row
    /// expanding to reveal action buttons grows the panel instead of
    /// being clipped. Dedup at the setter level: avoid re-publishing if
    /// the size hasn't changed (SwiftUI can fire the same value).
    func reportExtendedSize(_ size: CGSize) {
        guard size != .zero, size != measuredExtendedSize else { return }
        AnimationDebugger.logEvent("reportSize state=\(currentState) size=(\(String(format: "%.1f", size.width))×\(String(format: "%.1f", size.height))) ready=\(isReady)")
        measuredExtendedSize = size
        if currentState == .extended {
            lastExtendedSize = size
        }
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

    /// Rendered height of the notification banner's own content, reported
    /// by `NotificationBannerView` through `SizePreferenceKey`. The panel
    /// hugs this instead of a static estimate so a long message can never
    /// be clipped by the window's bottom edge. `AppDelegate` observes it to
    /// animate the NSPanel frame.
    func reportNotificationSize(_ size: CGSize) {
        guard size.height > 1 else { return }
        // Ignore measurements taken while the panel is still widening out
        // of compact: the banner re-wraps in the narrow window and reports
        // an inflated height, which would make the window overshoot and
        // then shrink back. The banner is never narrower than the minimum
        // notification width, so anything below it is mid-animation.
        guard size.width >= IslandChrome.notificationMinWidth - 2 else { return }
        guard size != measuredNotificationSize else { return }
        AnimationDebugger.logEvent("reportNotificationSize state=\(currentState) size=(\(String(format: "%.1f", size.width))×\(String(format: "%.1f", size.height))) ready=\(isReady)")
        measuredNotificationSize = size
    }

    /// Forget the banner measurement (no measurement yet). Called when a
    /// new notification is presented so the previous banner's height is
    /// never reused as this one's starting frame.
    func invalidateNotificationSize() {
        measuredNotificationSize = .zero
    }

    /// Collapse immediately and ignore any `mouseEntered` that fires in
    /// the next `duration` seconds. Use when we're handing focus to
    /// another app (WeChat) — without this, the cursor still hovering
    /// over our old frame would pop the panel right back open.
    func collapseAndYield(duration: TimeInterval = 1.5) {
        exitGeneration = UUID()
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        reexpandSuppressedUntil = Date().addingTimeInterval(duration)
        popoverOpen = false
        menuTrackingOpen = false
        islandTextInputActive = false
        autopilotPopoverOpen = false
        briefingExpanded = false
        snoozeMenuExpanded = false
        if currentState != .compact {
            currentState = .compact
        }
    }

    /// Notifications may expand an idle island, but must never replace an
    /// active inbox, detail view, or popover. Hover pauses dismissal.
    func showNotification(duration: TimeInterval = 3) {
        // In-place surfaces belong to the banner that opened them. When the
        // next notification arrives while the previous banner is still up, the
        // new one must not inherit them: a leaked `briefingExpanded` swaps the
        // new banner for the *previous* message's briefing card — the new
        // message never renders at all — and the `popoverOpen` it latches makes
        // the guard below drop the notification outright, so it gets no timer
        // and never auto-dismisses.
        //
        // Only the banner's own two surfaces are cleared, and only while the
        // panel is still showing a banner. A popover belonging to something
        // else (the autopilot review) keeps holding the notification off, and
        // in `.detail` the same card is part of the page rather than a
        // transient surface — which is why `setBriefingExpanded` deliberately
        // leaves `popoverOpen` alone there.
        if currentState == .notification, briefingExpanded || snoozeMenuExpanded {
            briefingExpanded = false
            snoozeMenuExpanded = false
            refreshTransientIslandHold()
        }
        guard currentState != .detail, currentState != .extended, !popoverOpen, !menuTrackingOpen, !islandTextInputActive else { return }
        islandSnoozeUndo = nil
        toastMessage = nil
        // A new banner may be much shorter or taller than the previous one
        // (short snippet vs. long group message vs. expanded briefing), so
        // drop the stale measurement and let the fresh render drive the
        // panel height. Until it arrives the panel uses the static
        // fallback instead of the previous banner's size.
        invalidateNotificationSize()
        notificationDuration = max(0.1, duration)
        exitGeneration = UUID()
        exitDebounceTimer?.invalidate()
        exitDebounceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        notificationGeneration = UUID()
        notificationWasInteractedWith = isMouseInside
        currentState = .notification
        guard !isMouseInside else { return }
        let generation = notificationGeneration
        notificationTimer = Timer.scheduledTimer(withTimeInterval: notificationDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.notificationGeneration == generation,
                      self.currentState == .notification,
                      !self.isMouseInside, !self.popoverOpen, !self.menuTrackingOpen, !self.islandTextInputActive else { return }
                self.notificationTimer = nil
                self.currentState = .compact
            }
        }
    }

    static func height(for state: HUDState) -> CGFloat {
        switch state {
        case .compact, .extended:
            // These states are measurement-driven; the static value is
            // only a placeholder for SwiftUI previews.
            return 32
        case .notification: return 150
        case .detail: return 500
        }
    }

    static func width(for state: HUDState) -> CGFloat {
        switch state {
        case .compact, .extended:
            // These states are measurement-driven; the static value is
            // only a placeholder for SwiftUI previews.
            return 320
        case .notification: return IslandChrome.notificationMinWidth
        case .detail: return 700
        }
    }
}
