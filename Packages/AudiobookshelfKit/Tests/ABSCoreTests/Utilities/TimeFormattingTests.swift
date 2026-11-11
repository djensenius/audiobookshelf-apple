import Foundation
import Testing

@testable import ABSCore

/// Port of the legacy `PlayerTimeUtilsTests`, with an injected clock.
@Suite struct TimeFormattingSeekBackTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func playedMs(secondsAgo: TimeInterval) -> Double {
        now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000
    }

    func seekBack(_ currentTime: TimeInterval, _ lastPlayedMs: Double?) -> TimeInterval {
        TimeFormatting.seekBackTime(currentTime: currentTime, lastPlayedMs: lastPlayedMs, now: now)
    }

    @Test func calcSeekBackTime() {
        #expect(seekBack(1000, nil) == 1000)
        #expect(seekBack(1000, playedMs(secondsAgo: 2)) == 1000)
        #expect(seekBack(1000, playedMs(secondsAgo: 12)) == 997)
        #expect(seekBack(1000, playedMs(secondsAgo: 62)) == 990)
        #expect(seekBack(1000, playedMs(secondsAgo: 302)) == 980)
        #expect(seekBack(1000, playedMs(secondsAgo: 1802)) == 970)
        // Would go negative.
        #expect(seekBack(1, playedMs(secondsAgo: 12)) == 0)
        // A negative timestamp is a very old one.
        #expect(seekBack(1000, -5000) == 970)
    }

    @Test func calcSeekBackTimeWithZeroCurrentTime() {
        #expect(seekBack(0, playedMs(secondsAgo: 300)) == 0)
    }

    @Test func disabledAutoRewindKeepsPosition() {
        let time = TimeFormatting.seekBackTime(
            currentTime: 1000, lastPlayedMs: playedMs(secondsAgo: 1802), autoRewindEnabled: false, now: now)
        #expect(time == 1000)
    }

    @Test func timeSinceLastPlayed() throws {
        let since = try #require(TimeFormatting.timeSinceLastPlayed(playedMs(secondsAgo: 5), now: now))
        #expect(abs(since - 5) < 1)
        #expect(TimeFormatting.timeSinceLastPlayed(nil, now: now) == nil)
    }

    @Test(
        arguments: [
            (nil, 0), (5, 0), (11, 3), (298, 10), (1798, 20), (3599, 30),
        ] as [(TimeInterval?, TimeInterval)])
    func timeToSeekBackForSinceLastPlayed(since: TimeInterval?, expected: TimeInterval) {
        #expect(TimeFormatting.rewindInterval(sinceLastPlayed: since) == expected)
    }

    @Test(
        arguments: [(9.99, 0), (10, 3), (59.9, 3), (60, 10), (299, 10), (300, 20), (1800, 30)]
            as [(TimeInterval, TimeInterval)])
    func rewindIntervalBoundaries(since: TimeInterval, expected: TimeInterval) {
        #expect(TimeFormatting.rewindInterval(sinceLastPlayed: since) == expected)
    }
}

@Suite struct TimeFormattingTimestampTests {
    @Test(
        arguments: [
            (0, "0:00"), (5.9, "0:05"), (65, "1:05"), (599, "9:59"), (3599, "59:59"), (3600, "1:00:00"),
            (3723, "1:02:03"), (36_000, "10:00:00"), (-3, "0:00"), (.nan, "0:00"), (.infinity, "0:00"),
        ] as [(TimeInterval, String)])
    func timestamp(seconds: TimeInterval, expected: String) {
        #expect(TimeFormatting.timestamp(seconds) == expected)
    }

    @Test(
        arguments: [
            (0, "00:00:00"), (65, "00:01:05"), (59.6, "00:01:00"), (3723.4, "01:02:03"), (360_000, "100:00:00"),
        ] as [(TimeInterval, String)])
    func fullTimestamp(seconds: TimeInterval, expected: String) {
        #expect(TimeFormatting.fullTimestamp(seconds) == expected)
    }
}

/// Listening totals become whole minutes in one clamped conversion: a finite server value such
/// as 1e30 would trap `Int(_:)`, so it is bounded first.
@Suite struct TimeFormattingWholeMinutesTests {
    private static let bound = TimeFormatting.maxMinutes

    @Test func boundIsTheDurationFormattersBound() {
        #expect(TimeFormatting.maxSeconds == 1e15)
        #expect(TimeFormatting.maxMinutes == 16_666_666_666_667)
    }

    /// Rounds half up, like the legacy page's `Math.round(seconds / 60)`.
    @Test(
        arguments: [
            (0, 0), (0.4, 0), (29.9, 0), (30, 1), (59.9, 1), (60, 1), (89.9, 1), (90, 2), (3_599, 60), (3_600, 60),
            (3_630, 61), (3_725, 62), (5_400.5, 90), (86_400, 1_440),
        ] as [(TimeInterval, Int)])
    func secondsRoundToTheNearestMinute(seconds: TimeInterval, expected: Int) {
        #expect(TimeFormatting.wholeMinutes(seconds: seconds) == expected)
    }

    /// Non-finite values are no data, like `timestamp` and `DurationStyle.elapsed`.
    @Test(arguments: [0, -0.0, -1, -1e30, -.greatestFiniteMagnitude, -.infinity, .infinity, .nan] as [TimeInterval])
    func nonPositiveAndNonFiniteSecondsAreZero(seconds: TimeInterval) {
        #expect(TimeFormatting.wholeMinutes(seconds: seconds) == 0)
    }

    @Test(arguments: [1e16, 1e30, .greatestFiniteMagnitude] as [TimeInterval])
    func hugeSecondsClampToTheBound(seconds: TimeInterval) {
        #expect(TimeFormatting.wholeMinutes(seconds: seconds) == Self.bound)
    }

    @Test func secondsAtAndJustOverTheBound() {
        let limit = TimeFormatting.maxSeconds
        #expect(TimeFormatting.wholeMinutes(seconds: limit - 60) == Self.bound - 1)
        #expect(TimeFormatting.wholeMinutes(seconds: limit.nextDown) == Self.bound)
        #expect(TimeFormatting.wholeMinutes(seconds: limit) == Self.bound)
        #expect(TimeFormatting.wholeMinutes(seconds: limit.nextUp) == Self.bound)
        #expect(TimeFormatting.wholeMinutes(seconds: limit * 2) == Self.bound)
    }

    @Test(
        arguments: [
            (0, 0), (0.4, 0), (0.5, 1), (22.5, 23), (60, 60), (-1, 0), (-1e30, 0), (-.infinity, 0), (.infinity, 0),
            (.nan, 0),
        ] as [(Double, Int)])
    func minutesRoundToWholeNumbers(minutes: Double, expected: Int) {
        #expect(TimeFormatting.wholeMinutes(minutes: minutes) == expected)
    }

    @Test(
        arguments: [1e30, .greatestFiniteMagnitude, Double(Int.max), Double(TimeFormatting.maxMinutes) + 1] as [Double])
    func hugeMinutesClampToTheBound(minutes: Double) {
        #expect(TimeFormatting.wholeMinutes(minutes: minutes) == Self.bound)
    }

    @Test func minutesAtAndJustOverTheBound() {
        let limit = Double(Self.bound)
        #expect(TimeFormatting.wholeMinutes(minutes: limit - 1) == Self.bound - 1)
        #expect(TimeFormatting.wholeMinutes(minutes: limit) == Self.bound)
        #expect(TimeFormatting.wholeMinutes(minutes: limit.nextUp) == Self.bound)
    }
}
