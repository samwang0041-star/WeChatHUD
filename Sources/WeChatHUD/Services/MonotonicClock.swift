import Foundation

/// Seconds since boot, counting only the time the machine was awake.
///
/// `Date` is an instant the system *owns*, not one it *measures*: the user can
/// set the clock by hand, and macOS corrects it when the hardware clock has
/// drifted. A window that decides whether a guardrail releases, whether a
/// reply batch fires, or whether a reminder is still muted is therefore not a
/// calendar fact — it is elapsed time between two events this process watched,
/// and it belongs on this axis.
///
/// Both failure directions are bad, which is why this is not a rounding
/// concern: a forward jump ages every stored entry out of its window (the
/// hourly send cap disarms and permits a whole extra round of unattended
/// sends), while a backward jump makes them all look future-dated (the same
/// identifier stays muted until the clock catches up — days, for a 24-hour
/// cooldown).
///
/// Sleep is excluded on purpose. Nothing is sent or evaluated while the
/// machine sleeps, so a window that pauses with the machine can only make a
/// cap stricter or a reply later by the sleep duration; it can never make one
/// fire sooner than it would have.
enum MonotonicClock {
    static func seconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// Injectable form, so a regression test can move elapsed time independently
/// of the wall clock instead of waiting for a real hour to pass.
typealias MonotonicSeconds = @Sendable () -> TimeInterval
