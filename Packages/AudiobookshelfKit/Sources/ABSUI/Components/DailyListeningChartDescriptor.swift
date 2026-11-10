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

    /// `minutes` spelled out, for example "75 minutes".
    public static func minutesText(_ minutes: Int, locale: Locale) -> String {
        Duration.seconds(minutes * 60).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(locale))
    }

    /// The total minutes and the daily average, rounded like the legacy chart.
    var totals: (total: Int, average: Int) {
        let total = days.reduce(0) { $0 + $1.minutes }
        let average = days.isEmpty ? 0 : Int((Double(total) / Double(days.count)).rounded())
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
        let maximum = max(days.map(\.minutes).max() ?? 0, 1)
        let yAxis = AXNumericDataAxisDescriptor(
            title: L10n.string("LabelStatsMinutesListening", locale: locale), range: 0...Double(maximum),
            gridlinePositions: []
        ) { value in
            Self.minutesText(Int(value.rounded()), locale: locale)
        }
        let series = AXDataSeriesDescriptor(
            name: title, isContinuous: false,
            dataPoints: days.map { AXDataPoint(x: $0.label, y: Double($0.minutes)) })
        return AXChartDescriptor(
            title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}

/// Spoken listening totals.
public enum ListeningTimeText {
    /// `seconds` in words for VoiceOver, never empty: "2 hours, 5 minutes", "20 seconds" for a
    /// brief total, and "0 minutes" for none (where ``DurationStyle/elapsed(showSeconds:useDays:)``
    /// returns an empty string).
    public static func spoken(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let minutes = DurationStyle.elapsed(showSeconds: false).accessibilityString(seconds, locale: locale)
        if !minutes.isEmpty { return minutes }
        let brief = DurationStyle.elapsed().accessibilityString(seconds, locale: locale)
        return brief.isEmpty ? DailyListeningChartDescriptor.minutesText(0, locale: locale) : brief
    }
}
