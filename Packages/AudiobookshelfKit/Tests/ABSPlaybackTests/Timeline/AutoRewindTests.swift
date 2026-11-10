import ABSPlayback
import Foundation
import Testing

/// Ports `PlayerTimeUtilsTests` from the legacy app.
@Suite struct AutoRewindTests {
    @Test(
        arguments: [
            (nil, 0.0),
            (-5, 0), (0, 0), (5, 0), (9.999, 0),
            (10, 3), (11, 3), (59.999, 3),
            (60, 10), (298, 10), (299.999, 10),
            (300, 20), (1798, 20), (1799.999, 20),
            (1800, 30), (3599, 30), (86_400, 30), (.infinity, 30),
            (.nan, 0),
        ] as [(TimeInterval?, TimeInterval)])
    func tiers(_ sinceLastPlayed: TimeInterval?, _ expected: TimeInterval) {
        #expect(AutoRewind.interval(sinceLastPlayed: sinceLastPlayed) == expected)
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(
        arguments: [
            (1000.0, -2.0 as TimeInterval?, true, 1000.0),
            (1000, -12, true, 997),
            (1000, -62, true, 990),
            (1000, -302, true, 980),
            (1000, -1802, true, 970),
            (1000, nil, true, 1000),
            (1000, 60, true, 1000),
            (1, -12, true, 0),
            (0, -300, true, 0),
            (1000, -1802, false, 1000),
            (.nan, -1802, true, 0),
        ] as [(TimeInterval, TimeInterval?, Bool, TimeInterval)])
    func resumeTime(
        _ currentTime: TimeInterval, _ lastPlayedOffset: TimeInterval?, _ enabled: Bool, _ expected: TimeInterval
    ) {
        let lastPlayed = lastPlayedOffset.map { Self.now.addingTimeInterval($0) }
        #expect(
            AutoRewind.resumeTime(currentTime: currentTime, lastPlayed: lastPlayed, now: Self.now, isEnabled: enabled)
                == expected)
    }

    /// Legacy: a negative `lastPlayedMs` is an old timestamp, so it rewinds the full 30 s.
    @Test func timestampBeforeEpochRewindsFully() {
        let lastPlayed = Date(timeIntervalSince1970: -5)
        #expect(AutoRewind.resumeTime(currentTime: 1000, lastPlayed: lastPlayed, now: Self.now) == 970)
    }
}
