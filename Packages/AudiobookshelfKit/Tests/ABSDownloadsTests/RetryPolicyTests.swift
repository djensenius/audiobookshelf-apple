import Testing

@testable import ABSDownloads

@Suite struct RetryPolicyTests {
    private let policy = RetryPolicy(baseDelay: .seconds(2), maxDelay: .seconds(10), maxRetries: 4)

    @Test func doublesCeilingWithEqualJitter() {
        #expect(
            (1...4).map { policy.delay(beforeRetry: $0, random: 0) } == [
                .seconds(1), .seconds(2), .seconds(4), .seconds(5),
            ])
        #expect(
            (1...4).map { policy.delay(beforeRetry: $0, random: 1) } == [
                .seconds(2), .seconds(4), .seconds(8), .seconds(10),
            ])
    }

    @Test func clampsRandomAndHugeRetryCounts() {
        let unbounded = RetryPolicy(baseDelay: .seconds(2), maxDelay: .seconds(300), maxRetries: .max)
        #expect(unbounded.delay(beforeRetry: 1_000, random: 2) == .seconds(300))
        #expect(unbounded.delay(beforeRetry: 1, random: -1) == .seconds(1))
    }

    @Test func givesUpAfterMaxRetries() {
        #expect(policy.delay(beforeRetry: 5, random: 0.5) == nil)
        #expect(policy.delay(beforeRetry: 0, random: 0.5) == nil)
        #expect(
            RetryPolicy(baseDelay: .seconds(1), maxDelay: .seconds(1), maxRetries: 0).delay(beforeRetry: 1, random: 0)
                == nil)
    }
}
