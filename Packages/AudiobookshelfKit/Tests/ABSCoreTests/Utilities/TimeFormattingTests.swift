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
