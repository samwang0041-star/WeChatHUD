import AppKit

/// A one-shot deadline that stops counting while the user cannot see the
/// screen.
///
/// Sonner's invisible edge cases applied to the island's transient surfaces:
/// a toast or an undo bar is a promise the user gets to *see*. If the Mac
/// locks or the display sleeps mid-countdown and the clock keeps running,
/// the surface — and its undo — expires unseen. This freezes while the
/// session is away and resumes for exactly the time that was left.
///
/// App deactivation is deliberately *not* a pause trigger: the island floats
/// above other apps by design, so the surface is still on screen while the
/// user works in WeChat. Only lock, fast user switching and display sleep
/// actually take it away.
@MainActor
final class PauseableDeadline: NSObject {
    private var timer: Timer?
    private var remaining: TimeInterval = 0
    private var suspended = false
    private let onFire: @MainActor () -> Void

    init(_ onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(sessionLeft),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sessionLeft),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sessionReturned),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sessionReturned),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    /// Starts (or restarts) a fresh countdown. Restarting is the
    /// "spam replaces, never queues" behavior of the toast it serves.
    func start(_ duration: TimeInterval) {
        timer?.invalidate()
        timer = nil
        remaining = duration
        arm()
    }

    /// Drops the countdown entirely — the surface went away for its own
    /// reasons (dismissed, replaced, undone).
    func cancel() {
        timer?.invalidate()
        timer = nil
        remaining = 0
    }

    private func arm() {
        guard !suspended, remaining > 0, timer == nil else { return }
        // .common so a tracked menu neither stretches the countdown nor
        // pins the surface past its promise.
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.remaining = 0
                self.onFire()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Freezes the countdown wherever it stands. Internal for tests; the
    /// notification handlers below are the production trigger.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        if let timer {
            remaining = max(0, timer.fireDate.timeIntervalSinceNow)
        }
        timer?.invalidate()
        timer = nil
    }

    /// Picks the frozen remainder back up.
    func resume() {
        guard suspended else { return }
        suspended = false
        arm()
    }

    // NSWorkspace notifications are not delivered on any guaranteed thread;
    // hop to the main actor before touching the clock.
    @objc private func sessionLeft() {
        Task { @MainActor in self.suspend() }
    }

    @objc private func sessionReturned() {
        Task { @MainActor in self.resume() }
    }
}
