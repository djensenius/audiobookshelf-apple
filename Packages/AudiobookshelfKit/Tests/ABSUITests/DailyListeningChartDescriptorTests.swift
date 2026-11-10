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
}

@Suite struct ListeningTimeTextTests {
    private static let locale = Locale(identifier: "en_US")

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

    @Test func longerTotalsReadInHoursAndMinutes() {
        let expected = DurationStyle.elapsed(showSeconds: false).accessibilityString(3_725, locale: Self.locale)
        #expect(ListeningTimeText.spoken(3_725, locale: Self.locale) == expected)
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
