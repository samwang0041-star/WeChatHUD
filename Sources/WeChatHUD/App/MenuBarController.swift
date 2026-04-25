import AppKit
import Combine

/// Single owner of `NSStatusItem.button` (Plan M6.1). AppDelegate's
/// existing combineLatest on inboxItems + vipAlertTiers feeds its
/// **output string** into `badgeText` — owner stays AppDelegate for
/// p0p1/worstTier semantics; this controller only handles the spinner
/// overlay during long retrospective jobs.
@MainActor
final class MenuBarController: ObservableObject {

    static let shared = MenuBarController()

    /// String fed in by AppDelegate's existing combineLatest sink.
    /// Preserves all p0/p1 / VIP worst-tier `agingLabel` semantics.
    @Published var badgeText: String = "" {
        didSet { renderIfIdle() }
    }

    /// Updated by ChatMonitor.retrospectiveJob.$state subscription.
    @Published var jobState: RetrospectiveJob.State = .idle {
        didSet { render() }
    }

    private weak var statusItem: NSStatusItem?
    private var spinTimer: Timer?
    private var spinFrames: [NSImage] = []
    private var spinIndex = 0
    private var savedImage: NSImage?

    private init() {}

    /// AppDelegate calls once after creating the status item. The
    /// image may not be set yet at attach time (depends on init order
    /// in applicationDidFinishLaunching) — render() will lazily
    /// re-snapshot when transitioning back to idle.
    func attach(_ item: NSStatusItem) {
        self.statusItem = item
        savedImage = item.button?.image
        render()
    }

    private func renderIfIdle() {
        switch jobState {
        case .idle, .completed, .failed, .partial:
            render()
        default:
            break  // job running — don't overwrite spinner
        }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        spinTimer?.invalidate()
        spinTimer = nil
        switch jobState {
        case .idle, .completed, .failed, .partial:
            // Late-snapshot: if attach() ran before AppDelegate's
            // updateMenuBarIcon(), savedImage was nil. Re-grab now.
            if savedImage == nil { savedImage = button.image }
            button.image = savedImage
            button.title = badgeText
        case .resolvingScope, .screeningGroups, .analyzingChats,
             .synthesizingSummary, .detectingRedBanner:
            button.title = ""
            startSpinning(button: button)
        }
    }

    private func startSpinning(button: NSStatusBarButton) {
        if spinFrames.isEmpty {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            guard let base = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "复盘进行中"
            )?.withSymbolConfiguration(cfg) else { return }
            spinFrames = (0..<8).map { i in
                MenuBarController.rotated(base, byDegrees: Double(i) * 45)
            }
        }
        spinIndex = 0
        spinTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.spinIndex = (self.spinIndex + 1) % self.spinFrames.count
            button.image = self.spinFrames[self.spinIndex]
        }
    }

    private static func rotated(_ image: NSImage, byDegrees degrees: Double) -> NSImage {
        let radians = CGFloat(degrees * .pi / 180)
        let size = image.size
        let rotated = NSImage(size: size)
        rotated.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byRadians: radians)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1.0)
        rotated.unlockFocus()
        rotated.isTemplate = image.isTemplate
        return rotated
    }
}
