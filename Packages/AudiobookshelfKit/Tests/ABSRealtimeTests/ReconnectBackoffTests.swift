import Testing

@testable import ABSRealtime

@Suite struct ReconnectBackoffTests {
    private let backoff = ReconnectBackoff()

    @Test func doublesUntilTheFifteenSecondCap() {
        let delays = (0..<6).map { backoff.delay(attempt: $0, random: 0.5) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15)])
        #expect(backoff.delay(attempt: 1_000, random: 0.5) == .seconds(15))
    }

    @Test func appliesJitterWithinBounds() {
        #expect(backoff.delay(attempt: 1, random: 0) == .seconds(1))
        #expect(backoff.delay(attempt: 1, random: 0.75) == .seconds(2.5))
        #expect(backoff.delay(attempt: 3, random: 1) == .seconds(12))
        #expect(backoff.delay(attempt: 4, random: 1) == .seconds(15))
    }

    @Test func appliesJitterBeforeTheCap() {
        #expect(backoff.delay(attempt: 4, random: 0) == .seconds(8))
        #expect(backoff.delay(attempt: 5, random: 0) == .seconds(15))
        #expect(backoff.delay(attempt: 1_000, random: 0) == .seconds(15))
    }
}
