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

    /// ``timestamp(_:locale:)`` in ASCII digits (`en_US_POSIX`), for machine-readable text and
    /// tests. Text people read uses the locale's digits instead.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        timestamp(seconds, locale: posix)
    }

    /// `m:ss`, or `h:mm:ss` from one hour, in `locale`'s digits: for example `4:05` or `1:02:03`
    /// in `en_US`, `٤:٠٥` in `ar_SA`. The shape and the `:` separators are the same in every
    /// locale. Fractional seconds are truncated; negative and non-finite values show as `0:00`.
    public static func timestamp(_ seconds: TimeInterval, locale: Locale) -> String {
        let (hours, minutes, secs) = components(wholeSeconds(seconds, rounded: false))
        let digits = Digits(locale: locale)
        if hours == 0 { return "\(digits.plain(minutes)):\(digits.padded(secs))" }
        return "\(digits.plain(hours)):\(digits.padded(minutes)):\(digits.padded(secs))"
    }

    /// ``fullTimestamp(_:locale:)`` in ASCII digits (`en_US_POSIX`), for machine-readable text
    /// and tests. Text people read uses the locale's digits instead.
    public static func fullTimestamp(_ seconds: TimeInterval) -> String {
        fullTimestamp(seconds, locale: posix)
    }

    /// Always `hh:mm:ss`, in `locale`'s digits: for example `00:04:05` in `en_US`, `٠٠:٠٤:٠٥` in
    /// `ar_SA`. Seconds are rounded.
    public static func fullTimestamp(_ seconds: TimeInterval, locale: Locale) -> String {
        let (hours, minutes, secs) = components(wholeSeconds(seconds, rounded: true))
        let digits = Digits(locale: locale)
        return "\(digits.padded(hours)):\(digits.padded(minutes)):\(digits.padded(secs))"
    }

    /// The longest duration, in seconds, that is converted to a whole number. Longer ones are
    /// clamped to it, so a finite but absurd server value can't overflow `Int`. About 31
    /// million years.
    public static let maxSeconds: Double = 1e15

    /// ``maxSeconds`` in whole minutes, the most ``wholeMinutes(seconds:)`` and
    /// ``wholeMinutes(minutes:)`` return.
    public static let maxMinutes = Int((maxSeconds / 60).rounded())

    /// `seconds` as whole minutes, rounded like the legacy stats page (`Math.round(seconds / 60)`),
    /// within `0...maxMinutes`. Zero, negative and non-finite values are `0`; values past
    /// ``maxSeconds`` are clamped before the conversion, which therefore can't trap.
    public static func wholeMinutes(seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return wholeMinutes(minutes: min(seconds, maxSeconds) / 60)
    }

    /// `minutes` rounded to a whole number within `0...maxMinutes`. Zero, negative and
    /// non-finite values are `0`; larger values are clamped before the conversion, which
    /// therefore can't trap.
    public static func wholeMinutes(minutes: Double) -> Int {
        guard minutes.isFinite, minutes > 0 else { return 0 }
        return Int(min(minutes, Double(maxMinutes)).rounded())
    }

    private static func wholeSeconds(_ seconds: TimeInterval, rounded: Bool) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let whole = rounded ? seconds.rounded() : seconds.rounded(.towardZero)
        return whole < Double(Int.max) ? Int(whole) : Int.max
    }

    private static func components(_ total: Int) -> (hours: Int, minutes: Int, seconds: Int) {
        (total / 3600, total % 3600 / 60, total % 60)
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Timestamp components in a locale's numbering system, without grouping separators.
    private struct Digits {
        private let plainStyle: IntegerFormatStyle<Int>
        private let paddedStyle: IntegerFormatStyle<Int>

        init(locale: Locale) {
            plainStyle = IntegerFormatStyle<Int>(locale: locale).grouping(.never)
            paddedStyle = plainStyle.precision(.integerLength(2...))
        }

        func plain(_ value: Int) -> String { value.formatted(plainStyle) }
        func padded(_ value: Int) -> String { value.formatted(paddedStyle) }
    }
}
