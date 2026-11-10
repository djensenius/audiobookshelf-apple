import ABSCore
import Accessibility
import Foundation
import SwiftUI

/// The audio graph description of a daily listening bar chart, for
/// `accessibilityChartDescriptor(_:)`. VoiceOver reads the title and a summary of the week,
/// and plays or reads the minutes listened per day.
public struct DailyListeningChartDescriptor: AXChartDescriptorRepresentable {
    public struct Day: Hashable, Sendable {
        /// The day as VoiceOver reads it, for example "Saturday, March 7". Labels must be unique.
        public var label: String
        /// Whole minutes. Counts outside `0...TimeFormatting.maxMinutes` are clamped to it.
        public var minutes: Int

        public init(label: String, minutes: Int) {
            self.label = label
            self.minutes = minutes
        }
    }

    public var days: [Day]
    public var locale: Locale

    public init(days: [Day], locale: Locale = .autoupdatingCurrent) {
        self.days = days
        self.locale = locale
    }

    /// `minutes` spelled out, for example "75 minutes". Counts outside
    /// `0...TimeFormatting.maxMinutes` are clamped to it.
    public static func minutesText(_ minutes: Int, locale: Locale) -> String {
        let minutes = TimeFormatting.wholeMinutes(minutes: Double(minutes))
        return Duration.seconds(minutes * 60).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(locale))
    }

    /// Each day's minutes within `0...TimeFormatting.maxMinutes`, so the sum, the average and
    /// the axis maximum below stay in range whatever `Int` a caller passes.
    private var clampedMinutes: [Int] {
        days.map { TimeFormatting.wholeMinutes(minutes: Double($0.minutes)) }
    }

    /// The total minutes and the daily average, rounded like the legacy chart.
    var totals: (total: Int, average: Int) {
        let minutes = clampedMinutes
        let total = minutes.reduce(0, +)
        let average = minutes.isEmpty ? 0 : TimeFormatting.wholeMinutes(minutes: Double(total) / Double(minutes.count))
        return (total, average)
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        let locale = locale
        let title = L10n.string("HeaderStatsMinutesListeningChart", locale: locale)
        let (total, average) = totals
        let summary = L10n.string(
            "MessageStatsChartSummary", Self.minutesText(total, locale: locale),
            Self.minutesText(average, locale: locale), locale: locale)
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: L10n.string("LabelStatsDays", locale: locale), categoryOrder: days.map(\.label))
        let minutes = clampedMinutes
        let maximum = max(minutes.max() ?? 0, 1)
        let yAxis = AXNumericDataAxisDescriptor(
            title: L10n.string("LabelStatsMinutesListening", locale: locale), range: 0...Double(maximum),
            gridlinePositions: []
        ) { value in
            Self.minutesText(TimeFormatting.wholeMinutes(minutes: value), locale: locale)
        }
        let series = AXDataSeriesDescriptor(
            name: title, isContinuous: false,
            dataPoints: zip(days, minutes).map { AXDataPoint(x: $0.label, y: Double($1)) })
        return AXChartDescriptor(
            title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}

/// Spoken listening totals.
public enum ListeningTimeText {
    /// The Minutes Listening tile's value in words for VoiceOver, never empty: "61 minutes" for
    /// 3,630 seconds. It formats the tile's own whole-minute count
    /// (``TimeFormatting/wholeMinutes(seconds:)``), so the spoken and the shown values agree;
    /// ``DurationStyle/elapsed(showSeconds:useDays:)`` rounds differently and would read 3,630
    /// seconds as "1 hour". A total that rounds to no minutes reads in seconds, as "20 seconds",
    /// and as "0 minutes" for none (where `elapsed` returns an empty string).
    public static func spoken(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let minutes = TimeFormatting.wholeMinutes(seconds: seconds)
        if minutes > 0 { return DailyListeningChartDescriptor.minutesText(minutes, locale: locale) }
        let brief = DurationStyle.elapsed().accessibilityString(seconds, locale: locale)
        return brief.isEmpty ? DailyListeningChartDescriptor.minutesText(0, locale: locale) : brief
    }

    /// A session's time as shown, with seconds, for example "1m 5s"; "0s" for none (where
    /// ``DurationStyle/elapsed(showSeconds:useDays:)`` returns an empty string).
    public static func session(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let text = DurationStyle.elapsed().string(seconds, locale: locale)
        return text.isEmpty ? zeroSeconds(width: .narrow, locale: locale) : text
    }

    /// The spoken form of ``session(_:locale:)``, for example "1 minute, 5 seconds"; "0 seconds"
    /// for none.
    public static func spokenSession(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let text = DurationStyle.elapsed().accessibilityString(seconds, locale: locale)
        return text.isEmpty ? zeroSeconds(width: .wide, locale: locale) : text
    }

    private static func zeroSeconds(width: Duration.UnitsFormatStyle.UnitWidth, locale: Locale) -> String {
        Duration.zero.formatted(Duration.UnitsFormatStyle(allowedUnits: [.seconds], width: width).locale(locale))
    }
}
