/// The playback rates the player offers (port of legacy `PlaybackSpeedModal`, D1): a list of
/// presets and a stepper over 0.5–10× in steps of 0.1.
///
/// Rates are kept on the 0.1 grid by working in whole tenths, so stepping never accumulates
/// floating-point drift (legacy `toFixed(1)`).
public enum PlaybackSpeed {
    /// Legacy `PlaybackSpeedModal` rates.
    public static let presets: [Double] = [0.5, 1, 1.2, 1.5, 1.7, 2, 3]
    /// The stepper's bounds.
    public static let range: ClosedRange<Double> = 0.5...10
    /// The stepper's increment.
    public static let step: Double = 0.1
    /// How close two rates must be to count as the same, as for a preset's checkmark.
    public static let tolerance: Double = 1e-6

    /// `rate` rounded to the nearest 0.1 and clamped to ``range``; a non-finite or non-positive rate,
    /// which settings would reject, gives `1`.
    public static func normalized(_ rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return 1 }
        return clamped(tenths: (rate / step).rounded())
    }

    /// The next rate on the 0.1 grid above or below `rate`, or `nil` at the end of ``range``.
    /// A rate between grid points moves to the nearest one in that direction (1.25 steps up to 1.3
    /// and down to 1.2). A rate outside ``range`` is clamped first; a non-finite or non-positive one
    /// counts as `1`.
    public static func stepped(_ rate: Double, up: Bool) -> Double? {
        let base = rate.isFinite && rate > 0 ? min(max(rate, range.lowerBound), range.upperBound) : 1
        let tenths = base / step
        // The tolerance absorbs a grid rate stored as, say, 1.2000000000000002.
        let next = up ? (tenths + tolerance).rounded(.down) + 1 : (tenths - tolerance).rounded(.up) - 1
        let result = next * step
        guard result >= range.lowerBound - tolerance, result <= range.upperBound + tolerance else { return nil }
        return clamped(tenths: next)
    }

    /// Whether `rate` is one of the ``presets``, within ``tolerance``.
    public static func isPreset(_ rate: Double) -> Bool {
        presets.contains { isSame($0, rate) }
    }

    /// Whether two rates are equal within ``tolerance``.
    public static func isSame(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < tolerance
    }

    /// Whole `tenths` as a rate in ``range``; dividing the integer by 10 gives the closest double to
    /// the decimal, unlike repeated additions of 0.1.
    private static func clamped(tenths: Double) -> Double {
        let bounded = min(max(tenths, range.lowerBound / step), range.upperBound / step).rounded()
        return bounded / 10
    }
}
