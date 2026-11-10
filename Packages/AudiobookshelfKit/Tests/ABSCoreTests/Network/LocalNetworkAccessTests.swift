import Network
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

/// Stands in for the connection: records each call and, when started, reports `states`.
private final class FakeProbe: LocalNetworkProbe {
    typealias Handler = @Sendable (NWConnection.State, NWPath.UnsatisfiedReason?) -> Void

    private let states: [(NWConnection.State, NWPath.UnsatisfiedReason?)]
    private let handler = Mutex<Handler?>(nil)
    let calls = Mutex<[String]>([])

    init(_ states: [(NWConnection.State, NWPath.UnsatisfiedReason?)]) {
        self.states = states
    }

    func setStateHandler(_ handler: Handler?) {
        calls.withLock { $0.append(handler == nil ? "clear" : "set") }
        self.handler.withLock { $0 = handler }
    }

    func start() {
        calls.withLock { $0.append("start") }
        guard let handler = handler.withLock({ $0 }) else { return }
        for (state, reason) in states { handler(state, reason) }
    }

    func cancel() {
        calls.withLock { $0.append("cancel") }
    }
}

private let refused = NWError.posix(.ECONNREFUSED)

@Suite struct LocalNetworkAccessTests {
    /// Checks with `probe`, with a timeout that ends only when cancelled unless `clock` is given.
    private func isDenied(_ probe: FakeProbe, clock: any Clock<Duration> = ContinuousClock()) async -> Bool {
        let access = SystemLocalNetworkAccess(timeout: .seconds(86_400), clock: clock) { host, port in
            #expect(host == "nas.lan" && port == 13378)
            return probe
        }
        let denied = await access.isDenied(host: "nas.lan", port: 13378)
        // The handler is cleared before the connection is cancelled, so it doesn't outlive the check.
        #expect(probe.calls.withLock { $0 } == ["set", "start", "clear", "cancel"])
        return denied
    }

    @Test(.timeLimit(.minutes(1)), arguments: [NWConnection.State.waiting(refused), .failed(refused)])
    func localNetworkDeniedPathIsADenial(state: NWConnection.State) async {
        #expect(await isDenied(FakeProbe([(.preparing, nil), (state, .localNetworkDenied)])))
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [NWConnection.State.waiting(refused), .failed(refused)],
        [nil, .notAvailable, .cellularDenied, .wifiDenied, .vpnInactive] as [NWPath.UnsatisfiedReason?])
    func otherReasonOrNoPathIsNotADenial(state: NWConnection.State, reason: NWPath.UnsatisfiedReason?) async {
        #expect(await isDenied(FakeProbe([(state, reason)])) == false)
    }

    /// The state decides, even if a path reported a denial.
    @Test(.timeLimit(.minutes(1)), arguments: [NWConnection.State.ready, .cancelled])
    func connectingOrCancellingIsNotADenial(state: NWConnection.State) async {
        #expect(await isDenied(FakeProbe([(.setup, nil), (state, .localNetworkDenied)])) == false)
    }

    @Test func connectionStillPreparingAtTheTimeoutIsCleanedUp() async {
        let clock = ImmediateClock()
        #expect(await isDenied(FakeProbe([(.preparing, nil)]), clock: clock) == false)
        #expect(clock.deadlines.withLock { $0.count } == 1)
    }

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
