import Foundation

/// Playback time helpers. Port of the legacy `PlayerTimeUtils` and the web client's
/// `$secondsToTimestamp` / `$secondsToTimestampFull`.
public enum TimeFormatting {
    /// The position to resume from after auto-rewind: rewinds further the longer playback
    /// was paused, never below `0`.
    ///
    /// - Parameters:
    ///   - currentTime: The saved position, in seconds.
    ///   - lastPlayedMs: When playback last happened, in milliseconds since 1970.
    ///   - autoRewindEnabled: The inverse of the `disableAutoRewind` device setting.
    ///   - now: The current date.
    public static func seekBackTime(
        currentTime: TimeInterval,
        lastPlayedMs: Double?,
        autoRewindEnabled: Bool = true,
        now: Date = .now
    ) -> TimeInterval {
        guard autoRewindEnabled else { return max(currentTime, 0) }
        let rewind = rewindInterval(sinceLastPlayed: timeSinceLastPlayed(lastPlayedMs, now: now))
        return max(currentTime - rewind, 0)
    }

    static func timeSinceLastPlayed(_ lastPlayedMs: Double?, now: Date = .now) -> TimeInterval? {
        guard let lastPlayedMs else { return nil }
        return now.timeIntervalSince(Date(timeIntervalSince1970: lastPlayedMs / 1000))
    }

    static func rewindInterval(sinceLastPlayed: TimeInterval?) -> TimeInterval {
        guard let sinceLastPlayed else { return 0 }
        switch sinceLastPlayed {
        case ..<10: return 0
        case ..<60: return 3
        case ..<300: return 10
        case ..<1800: return 20
        default: return 30
        }
    }

    /// `m:ss`, or `h:mm:ss` from one hour, for example `4:05` or `1:02:03`.
    /// Fractional seconds are truncated; negative and non-finite values show as `0:00`.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let (hours, minutes, secs) = components(wholeSeconds(seconds, rounded: false))
        if hours == 0 { return "\(minutes):\(pad(secs))" }
        return "\(hours):\(pad(minutes)):\(pad(secs))"
    }

    /// Always `hh:mm:ss`, for example `00:04:05`. Seconds are rounded.
    public static func fullTimestamp(_ seconds: TimeInterval) -> String {
        let (hours, minutes, secs) = components(wholeSeconds(seconds, rounded: true))
        return "\(pad(hours)):\(pad(minutes)):\(pad(secs))"
    }

    private static func wholeSeconds(_ seconds: TimeInterval, rounded: Bool) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let whole = rounded ? seconds.rounded() : seconds.rounded(.towardZero)
        return whole < Double(Int.max) ? Int(whole) : Int.max
    }

    private static func components(_ total: Int) -> (hours: Int, minutes: Int, seconds: Int) {
        (total / 3600, total % 3600 / 60, total % 60)
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
