import ABSCore
import Foundation
import SwiftUI

/// Formats a number of seconds like the legacy app.
public enum DurationStyle: Hashable, Sendable {
    /// `4:05` or `1:02:03` (legacy `$secondsToTimestamp`), for playback positions.
    case timestamp
    /// `1d 2h 3m 4s` (legacy `$elapsedPrettyExtended`), localized, for total durations.
    /// Without seconds the minutes are rounded. Without days, hours run past 24 until
    /// 100 days, as in legacy.
    case elapsed(showSeconds: Bool = true, useDays: Bool = true)

    /// The visible text for `seconds`.
    public func string(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .timestamp:
            TimeFormatting.timestamp(seconds)
        case .elapsed(let showSeconds, let useDays):
            Self.units(seconds, showSeconds: showSeconds, useDays: useDays, width: .narrow, locale: locale)
        }
    }

    /// The spoken form for VoiceOver, for example "1 hour, 2 minutes, 3 seconds".
    public func accessibilityString(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .timestamp:
            Self.units(seconds, showSeconds: true, useDays: false, width: .wide, locale: locale)
        case .elapsed(let showSeconds, let useDays):
            Self.units(seconds, showSeconds: showSeconds, useDays: useDays, width: .wide, locale: locale)
        }
    }

    private static func units(
        _ seconds: TimeInterval,
        showSeconds: Bool,
        useDays: Bool,
        width: Duration.UnitsFormatStyle.UnitWidth,
        locale: Locale
    ) -> String {
        let clamped = seconds.isFinite ? max(seconds, 0) : 0
        // Truncated like the timestamp so the spoken form matches the visible one.
        let whole = showSeconds ? clamped.rounded(.towardZero) : clamped
        var units: Set<Duration.UnitsFormatStyle.Unit> = [.hours, .minutes]
        if useDays || whole >= 100 * 86_400 { units.insert(.days) }
        if showSeconds { units.insert(.seconds) }
        let style = Duration.UnitsFormatStyle(
            allowedUnits: units,
            width: width,
            fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
        )
        .locale(locale)
        return Duration.seconds(whole).formatted(style)
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
