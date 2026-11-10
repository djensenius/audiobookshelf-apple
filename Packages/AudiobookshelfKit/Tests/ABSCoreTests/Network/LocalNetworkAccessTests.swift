import Synchronization
import Testing

@testable import ABSCore

/// A clock whose sleeps return at once, recording each deadline.
private final class ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant

    let deadlines = Mutex<[Instant]>([])

    var now: Instant { .now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        deadlines.withLock { $0.append(deadline) }
    }
}

@Suite struct LocalNetworkAccessTests {
    @Test(arguments: [-1, 70000])
    func invalidPortIsNotADenial(port: Int) async {
        let clock = ImmediateClock()
        #expect(await SystemLocalNetworkAccess(clock: clock).isDenied(host: "192.168.1.20", port: port) == false)
        // Returned without connecting or waiting.
        #expect(clock.deadlines.withLock { $0.isEmpty })
    }

    @Test(.timeLimit(.minutes(1)))
    func noAnswerWithinTheTimeoutIsNotADenial() async {
        let clock = ImmediateClock()
        let start = ContinuousClock.now
        let access = SystemLocalNetworkAccess(timeout: .seconds(3600), clock: clock)
        // TEST-NET-1 (RFC 5737) is public, so the system doesn't ask for local network access.
        #expect(await access.isDenied(host: "192.0.2.1", port: 80) == false)
        let deadlines = clock.deadlines.withLock { $0 }
        #expect(deadlines.count == 1)
        #expect(deadlines.allSatisfy { $0 >= start.advanced(by: .seconds(3600)) })
    }
}
