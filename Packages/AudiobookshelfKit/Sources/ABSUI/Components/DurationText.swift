import ABSCore
import Foundation
import SwiftUI

/// Formats a number of seconds like the legacy app.
public enum DurationStyle: Hashable, Sendable {
    /// `4:05` or `1:02:03` (legacy `$secondsToTimestamp`), for playback positions.
    case timestamp
    /// `1d 2h 3m 4s` (legacy `$elapsedPrettyExtended`), localized, for total durations.
    /// Rounds to whole seconds; without seconds the minutes are rounded too. Without days,
    /// hours run past 24 until 100 days, as in legacy.
    case elapsed(showSeconds: Bool = true, useDays: Bool = true)

    /// The visible text for `seconds`. `.elapsed` returns an empty string for zero,
    /// negative and non-finite values, and for under 30 seconds without seconds, like legacy.
    public func string(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .timestamp:
            TimeFormatting.timestamp(seconds)
        case .elapsed(let showSeconds, let useDays):
            Self.elapsed(seconds, showSeconds: showSeconds, useDays: useDays, width: .narrow, locale: locale)
        }
    }

    /// The spoken form for VoiceOver, for example "1 hour, 2 minutes, 3 seconds".
    public func accessibilityString(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .timestamp:
            // Truncated like the visible timestamp.
            let whole = seconds.isFinite ? max(seconds, 0).rounded(.towardZero) : 0
            return Self.format(
                min(whole, Self.maxSeconds), units: [.hours, .minutes, .seconds], width: .wide, locale: locale
            )
        case .elapsed(let showSeconds, let useDays):
            return Self.elapsed(seconds, showSeconds: showSeconds, useDays: useDays, width: .wide, locale: locale)
        }
    }

    /// Guards the integer conversion; about 31 million years.
    private static let maxSeconds: Double = 1e15

    /// Port of `$elapsedPrettyExtended`: rounds to whole seconds first, and without seconds
    /// rounds the minutes up from 30 seconds when the minute-of-hour is non-zero.
    private static func elapsed(
        _ seconds: TimeInterval,
        showSeconds: Bool,
        useDays: Bool,
        width: Duration.UnitsFormatStyle.UnitWidth,
        locale: Locale
    ) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        var total = Int64(min(seconds.rounded(), maxSeconds))
        if !showSeconds {
            let remainder = total % 60
            let minuteOfHour = total / 60 % 60
            total -= remainder
            if minuteOfHour != 0, remainder >= 30 { total += 60 }
        }
        guard total > 0 else { return "" }
        var units: Set<Duration.UnitsFormatStyle.Unit> = [.hours, .minutes]
        if useDays || total >= 100 * 86_400 { units.insert(.days) }
        if showSeconds { units.insert(.seconds) }
        return format(Double(total), units: units, width: width, locale: locale)
    }

    private static func format(
        _ seconds: Double,
        units: Set<Duration.UnitsFormatStyle.Unit>,
        width: Duration.UnitsFormatStyle.UnitWidth,
        locale: Locale
    ) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: units, width: width).locale(locale)
        return Duration.seconds(seconds).formatted(style)
    }
}

/// A duration in seconds, rendered with a ``DurationStyle`` and read out in words.
public struct DurationText: View {
    private let seconds: TimeInterval
    private let style: DurationStyle
    @Environment(\.locale) private var locale

    public init(seconds: TimeInterval, style: DurationStyle = .timestamp) {
        self.seconds = seconds
        self.style = style
    }

    public var body: some View {
        Text(verbatim: style.string(seconds, locale: locale))
            .monospacedDigit()
            .accessibilityLabel(Text(verbatim: style.accessibilityString(seconds, locale: locale)))
    }
}
