import ABSCore
import Accessibility
import Foundation
import Testing

@testable import ABSUI

@MainActor
@Suite struct DailyListeningChartDescriptorTests {
    private static let locale = Locale(identifier: "en_US")
    private static let minutesStyle = Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(locale)

    private static func minutes(_ value: Int) -> String {
        Duration.seconds(value * 60).formatted(minutesStyle)
    }

    private static let days: [DailyListeningChartDescriptor.Day] = [
        .init(label: "Sunday, February 25", minutes: 0),
        .init(label: "Monday, February 26", minutes: 12),
        .init(label: "Tuesday, February 27", minutes: 0),
        .init(label: "Wednesday, February 28", minutes: 45),
        .init(label: "Thursday, February 29", minutes: 0),
        .init(label: "Friday, March 1", minutes: 60),
        .init(label: "Saturday, March 2", minutes: 30),
    ]

    @Test func describesTheWeek() throws {
        let chart = DailyListeningChartDescriptor(days: Self.days, locale: Self.locale).makeChartDescriptor()
        let title = L10n.string("HeaderStatsMinutesListeningChart", locale: Self.locale)
        #expect(chart.title == title)
        // 147 minutes in total; 147 / 7 = 21 a day.
        #expect(
            chart.summary
                == L10n.string(
                    "MessageStatsChartSummary", Self.minutes(147), Self.minutes(21), locale: Self.locale))

        let xAxis = try #require(chart.xAxis as? AXCategoricalDataAxisDescriptor)
        #expect(xAxis.title == L10n.string("LabelStatsDays", locale: Self.locale))
        #expect(xAxis.categoryOrder == Self.days.map(\.label))

        let yAxis = try #require(chart.yAxis)
        #expect(yAxis.title == L10n.string("LabelStatsMinutesListening", locale: Self.locale))
        #expect(yAxis.range == 0...60)
        #expect(yAxis.valueDescriptionProvider(45) == Self.minutes(45))
        #expect(yAxis.valueDescriptionProvider(0) == Self.minutes(0))

        #expect(chart.series.count == 1)
        let series = try #require(chart.series.first)
        #expect(series.name == title)
        #expect(!series.isContinuous)
        // `AXDataPointValue` refines its accessors for Swift with no replacement, so read the
        // underlying properties.
        #expect(series.dataPoints.map(\.xValue.__category) == Self.days.map(\.label))
        #expect(series.dataPoints.map { $0.yValue?.__number } == Self.days.map { Double($0.minutes) })
    }

    @Test func emptyWeekKeepsAUsableRange() throws {
        let days = Self.days.map { DailyListeningChartDescriptor.Day(label: $0.label, minutes: 0) }
        let chart = DailyListeningChartDescriptor(days: days, locale: Self.locale).makeChartDescriptor()
        #expect(chart.yAxis?.range == 0...1)
        #expect(
            chart.summary
                == L10n.string("MessageStatsChartSummary", Self.minutes(0), Self.minutes(0), locale: Self.locale))
        #expect(chart.series.first?.dataPoints.map { $0.yValue?.__number } == Array(repeating: 0, count: 7))
    }

    @Test func minutesTextUsesTheLocale() {
        let german = Locale(identifier: "de_DE")
        let expected = Duration.seconds(75 * 60).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(german))
        #expect(DailyListeningChartDescriptor.minutesText(75, locale: german) == expected)
        #expect(DailyListeningChartDescriptor.minutesText(75, locale: german) != Self.minutes(75))
    }

    /// `Day.minutes` is any `Int` a caller passes. Each day is clamped to `0...maxMinutes`
    /// before it's summed, averaged or used for the axis maximum, so none of it overflows.
    @Test func hugeDaysStayInRange() throws {
        let bound = TimeFormatting.maxMinutes
        let minutes = [Int.max, Int.min, bound, bound + 1, 0, 5, -5]
        let days = minutes.enumerated().map {
            DailyListeningChartDescriptor.Day(label: "Day \($0.offset)", minutes: $0.element)
        }
        let descriptor = DailyListeningChartDescriptor(days: days, locale: Self.locale)
        let chart = descriptor.makeChartDescriptor()

        let clamped = [bound, 0, bound, bound, 0, 5, 0]
        let total = 3 * bound + 5
        let average = 7_142_857_142_858  // 50,000,000,000,006 / 7
        #expect(clamped.reduce(0, +) == total)
        #expect(descriptor.totals.total == total)
        #expect(descriptor.totals.average == average)
        // The total is itself past the bound, so `minutesText` clamps it again when it's spoken.
        #expect(
            chart.summary
                == L10n.string(
                    "MessageStatsChartSummary", Self.minutes(bound), Self.minutes(average), locale: Self.locale))
        #expect(chart.yAxis?.range == 0...Double(bound))
        #expect(chart.series.first?.dataPoints.map { $0.yValue?.__number } == clamped.map(Double.init))
    }

    @Test func minutesTextIsClamped() {
        let bound = TimeFormatting.maxMinutes
        let text = { (minutes: Int) in DailyListeningChartDescriptor.minutesText(minutes, locale: Self.locale) }
        #expect(text(75) == Self.minutes(75))
        #expect(text(bound) == Self.minutes(bound))
        #expect(text(bound + 1) == Self.minutes(bound))
        #expect(text(Int.max) == Self.minutes(bound))
        #expect(text(-5) == Self.minutes(0))
        #expect(text(Int.min) == Self.minutes(0))
    }

    /// VoiceOver can ask the axis to describe any value; none may trap the `Int` conversion.
    @Test func axisValuesAreSanitised() throws {
        let bound = TimeFormatting.maxMinutes
        let chart = DailyListeningChartDescriptor(days: Self.days, locale: Self.locale).makeChartDescriptor()
        let yAxis = try #require(chart.yAxis)
        for value in [.nan, .infinity, -.infinity, -5, -1e30] as [Double] {
            #expect(yAxis.valueDescriptionProvider(value) == Self.minutes(0), "\(value)")
        }
        for value in [1e30, .greatestFiniteMagnitude, Double(bound) + 1] as [Double] {
            #expect(yAxis.valueDescriptionProvider(value) == Self.minutes(bound), "\(value)")
        }
        #expect(yAxis.valueDescriptionProvider(22.5) == Self.minutes(23))
    }
}

@Suite struct ListeningTimeTextTests {
    private static let locale = Locale(identifier: "en_US")

    private static func minutes(_ value: Int) -> String {
        Duration.seconds(value * 60).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(locale))
    }

    @Test func zeroReadsAsZeroMinutes() {
        let expected = Duration.seconds(0).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(Self.locale))
        #expect(!expected.isEmpty)
        #expect(ListeningTimeText.spoken(0, locale: Self.locale) == expected)
        #expect(ListeningTimeText.spoken(0.2, locale: Self.locale) == expected)
        #expect(ListeningTimeText.spoken(-5, locale: Self.locale) == expected)
        #expect(ListeningTimeText.spoken(.nan, locale: Self.locale) == expected)
    }

    @Test func briefTotalsReadInSeconds() {
        let expected = DurationStyle.elapsed().accessibilityString(20, locale: Self.locale)
        #expect(!expected.isEmpty)
        #expect(ListeningTimeText.spoken(20, locale: Self.locale) == expected)
    }

    /// Totals that round to no minutes keep the fallbacks: seconds, or zero minutes for none.
    @Test func totalsThatRoundToNoMinutesKeepTheFallbacks() {
        #expect(ListeningTimeText.spoken(29, locale: Self.locale) == "29 seconds")
        #expect(ListeningTimeText.spoken(29.4, locale: Self.locale) == "29 seconds")
        for seconds in [0, 0.4, -5, -1e30, .infinity, -.infinity, .nan] as [TimeInterval] {
            #expect(ListeningTimeText.spoken(seconds, locale: Self.locale) == "0 minutes", "\(seconds)")
        }
    }

    /// The tile shows `Math.round(seconds / 60)`, so from half a minute that is 1.
    @Test func halfAMinuteAndMoreReadsAsTheTilesMinutes() {
        for seconds in [30, 45, 59.9, 60, 89] as [TimeInterval] {
            #expect(ListeningTimeText.spoken(seconds, locale: Self.locale) == "1 minute", "\(seconds)")
        }
        #expect(ListeningTimeText.spoken(90, locale: Self.locale) == "2 minutes")
    }

    /// `DurationStyle.elapsed(showSeconds: false)` doesn't round up when the minute-of-hour is
    /// zero, so it reads 3,630 seconds as "1 hour" while the tile shows 61.
    @Test func readsTheMinutesTheTileShows() {
        #expect(TimeFormatting.wholeMinutes(seconds: 3_630) == 61)
        #expect(ListeningTimeText.spoken(3_630, locale: Self.locale) == "61 minutes")
        #expect(ListeningTimeText.spoken(3_630, locale: Self.locale) == Self.minutes(61))
    }

    @Test func anExactHourReadsAsSixtyMinutes() {
        #expect(TimeFormatting.wholeMinutes(seconds: 3_600) == 60)
        #expect(ListeningTimeText.spoken(3_600, locale: Self.locale) == "60 minutes")
        #expect(ListeningTimeText.spoken(3_629, locale: Self.locale) == "60 minutes")
    }

    /// Whatever the total, the spoken text carries the number the tile formats.
    @Test(arguments: [30, 3_599, 3_600, 3_630, 3_660 + 29, 3_725, 7_500, 86_400, 75_000, 360_090] as [TimeInterval])
    func spokenValueAgreesWithTheTile(seconds: TimeInterval) {
        let minutes = TimeFormatting.wholeMinutes(seconds: seconds)
        let tile = minutes.formatted(.number.locale(Self.locale))
        let spoken = ListeningTimeText.spoken(seconds, locale: Self.locale)
        #expect(spoken == Self.minutes(minutes))
        #expect(spoken.hasPrefix(tile), "\(spoken) vs \(tile)")
    }

    /// A total `Int` can't hold reads as the clamped minutes the tile shows.
    @Test(
        arguments: [
            1e30, .greatestFiniteMagnitude, TimeFormatting.maxSeconds, TimeFormatting.maxSeconds.nextUp,
        ] as [TimeInterval])
    func hugeTotalsReadTheClampedMinutes(seconds: TimeInterval) {
        #expect(ListeningTimeText.spoken(seconds, locale: Self.locale) == Self.minutes(TimeFormatting.maxMinutes))
    }

    @Test func usesTheLocale() {
        let german = Locale(identifier: "de_DE")
        let expected = Duration.seconds(0).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .wide).locale(german))
        #expect(ListeningTimeText.spoken(0, locale: german) == expected)
    }

    @Test func emptySessionShowsAndReadsZeroSeconds() {
        let visible = Duration.zero.formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.seconds], width: .narrow).locale(Self.locale))
        let spoken = Duration.zero.formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.seconds], width: .wide).locale(Self.locale))
        #expect(!visible.isEmpty)
        #expect(!spoken.isEmpty)
        for seconds in [0, 0.2, -3, .nan] as [TimeInterval] {
            #expect(ListeningTimeText.session(seconds, locale: Self.locale) == visible)
            #expect(ListeningTimeText.spokenSession(seconds, locale: Self.locale) == spoken)
        }
    }

    @Test func sessionKeepsSeconds() {
        for seconds in [1, 65, 3_725] as [TimeInterval] {
            #expect(
                ListeningTimeText.session(seconds, locale: Self.locale)
                    == DurationStyle.elapsed().string(seconds, locale: Self.locale))
            #expect(
                ListeningTimeText.spokenSession(seconds, locale: Self.locale)
                    == DurationStyle.elapsed().accessibilityString(seconds, locale: Self.locale))
        }
        #expect(
            ListeningTimeText.session(65, locale: Self.locale) != ListeningTimeText.session(60, locale: Self.locale))
    }
}
