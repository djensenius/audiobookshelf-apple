import Foundation
import Testing

@testable import ABSDownloads

@Suite struct ProgressThrottleTests {
    private let partID = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func publishesEveryPercentOrSecondAndPersistsEveryTwoSeconds() {
        var throttle = ProgressThrottle()
        let decisions = [
            (bytes: 0, seconds: 0.0),  // first event
            (bytes: 5, seconds: 0.1),  // under 1% and 1 s
            (bytes: 10, seconds: 0.2),  // 1%
            (bytes: 11, seconds: 1.3),  // 1 s
            (bytes: 12, seconds: 2.0),  // 2 s since the last write
            (bytes: 1000, seconds: 2.1),  // 100%
            (bytes: 1000, seconds: 2.2),  // already at 100%
        ].map { throttle.record(partID, bytesWritten: Int64($0.bytes), expectedBytes: 1000, at: start + $0.seconds) }

        #expect(decisions.map(\.publishes) == [true, false, true, true, false, true, false])
        #expect(decisions.map(\.persists) == [true, false, false, false, true, false, false])
    }

    @Test func unknownLengthPublishesBySecond() {
        var throttle = ProgressThrottle()
        let decisions = [0.0, 0.5, 1.0].map {
            throttle.record(partID, bytesWritten: Int64($0 * 1000), expectedBytes: -1, at: start + $0).publishes
        }
        #expect(decisions == [true, false, true])
    }

    @Test func resetStartsOver() {
        var throttle = ProgressThrottle()
        _ = throttle.record(partID, bytesWritten: 0, expectedBytes: 1000, at: start)
        throttle.reset(partID)
        #expect(
            throttle.record(partID, bytesWritten: 1, expectedBytes: 1000, at: start + 0.1)
                == .init(publishes: true, persists: true))
    }
}
