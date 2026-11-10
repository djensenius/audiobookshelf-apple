import Foundation

/// Rewind applied when playback resumes after a pause, ported from the legacy
/// `PlayerTimeUtils.calcSeekBackTime`.
public enum AutoRewind {
    /// Seconds to rewind after a pause of `sinceLastPlayed` seconds.
    ///
    /// | Paused for | Rewind |
    /// | --- | --- |
    /// | unknown, or under 10 s | 0 s |
    /// | 10 s to under 1 min | 3 s |
    /// | 1 min to under 5 min | 10 s |
    /// | 5 min to under 30 min | 20 s |
    /// | 30 min or more | 30 s |
    ///
    /// NaN returns `0`; the legacy code fell through to 30 s.
    public static func interval(sinceLastPlayed: TimeInterval?) -> TimeInterval {
        guard let sinceLastPlayed, !sinceLastPlayed.isNaN else { return 0 }
        switch sinceLastPlayed {
        case ..<10: return 0
        case ..<60: return 3
        case ..<300: return 10
        case ..<1800: return 20
        default: return 30
        }
    }

    /// The time to resume from: `currentTime` minus the tier for the pause since `lastPlayed`, not
    /// below `0`. A `lastPlayed` in the future counts as a pause under 10 s.
    public static func resumeTime(
        currentTime: TimeInterval, lastPlayed: Date?, now: Date, isEnabled: Bool = true
    ) -> TimeInterval {
        let currentTime = currentTime.isFinite ? currentTime : 0
        guard isEnabled else { return max(currentTime, 0) }
        let rewind = interval(sinceLastPlayed: lastPlayed.map { now.timeIntervalSince($0) })
        return max(currentTime - rewind, 0)
    }
}
