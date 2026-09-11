import Foundation

/// Conversions for numbers that arrive from outside this process: AI JSON,
/// remote HTTP responses, Accessibility attribute values.
///
/// `Int(_: Double)` is a `_precondition`, not a throw — `Int(1e30)` ends the
/// process, in release builds too, and no `catch` can see it. A model that
/// answers `"msg": 1e30`, a summary that reports `"noise_ratio": 1e400`, or a
/// chat window mid-relayout is therefore enough to kill the HUD. Everything
/// an external source can put on the far side of a conversion goes through
/// here, where an impossible value saturates at a bound or becomes `nil`.
///
/// Numbers the app computes itself (`Date().timeIntervalSince1970`, a row
/// count, an index into an array we just built) do not need this and should
/// not be routed through it. They cannot be out of range, and a clamp there
/// would hide a real bug instead of absorbing a hostile input.
enum SafeNumber {

    /// Clamps `value` into `range`. `+∞` saturates high, `-∞` saturates low,
    /// and `NaN` becomes the lower bound — all three mean "the source gave us
    /// nonsense", and for the ratios this is used on the lower bound is the
    /// conservative reading.
    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        if value.isNaN { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Rounds `value` to the nearest integer and clamps it into `range`.
    /// Saturates rather than trapping.
    static func clampedInt(_ value: Double, in range: ClosedRange<Int>) -> Int {
        if value.isNaN { return range.lowerBound }
        // Compare in `Double` so the bound itself can't be stepped over:
        // `Double(Int.max)` is 2^63, one past the largest `Int`, and a value
        // that reaches it would trap on the way out of `Int(_:)`.
        if value >= Double(range.upperBound) { return range.upperBound }
        if value <= Double(range.lowerBound) { return range.lowerBound }
        return Int(value.rounded())
    }

    /// `nil` unless `value` is a whole number inside `range`.
    ///
    /// The strict counterpart of `clampedInt`. Use it where saturating would
    /// fabricate meaning: an out-of-range message index that clamps to "the
    /// last message" becomes a citation the model never made, so the item
    /// should be dropped instead.
    static func exactInt(_ value: Double, in range: ClosedRange<Int> = Int.min...Int.max) -> Int? {
        guard let exact = Int(exactly: value) else { return nil }
        return range.contains(exact) ? exact : nil
    }

    /// Reads an integer out of loosely typed JSON — models send the same
    /// field as `3`, `3.0` or `"3"` — and bounds-checks it.
    static func jsonInt(_ value: Any?, in range: ClosedRange<Int> = Int.min...Int.max) -> Int? {
        switch value {
        case let i as Int:
            return range.contains(i) ? i : nil
        case let d as Double:
            return exactInt(d, in: range)
        case let s as String:
            return Int(s.trimmingCharacters(in: .whitespaces))
                .flatMap { range.contains($0) ? $0 : nil }
        default:
            return nil
        }
    }
}
