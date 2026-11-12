import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSPlayback

/// ADR 0007 recovery's network wait and session check, a call interrupting it, and the play intent
/// a user seek carries from it (Part of #148).
@MainActor
struct PlaybackRecoveryNetworkTests {
    let paths = RecoveryPathSource()
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness(networkPaths: paths)
    }

    private static func failure(_ kind: PlaybackFailure.Kind) -> PlaybackFailure {
        PlaybackRecoveryTests.failure(kind)
    }

    private func playAt600() async {
        await coordinator.play(itemID: "A", startTime: 600)
        #expect(coordinator.isPlaying)
    }

    private func setSession(_ status: PlaybackSessionStatus) {
        service.state.withLock { $0.sessionStatus = status }
    }

    private var lookups: [String] { service.state.withLock { $0.sessionLookups } }

    private func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Recovery never settled", sourceLocation: sourceLocation)
    }

    private func drain() async {
        for _ in 0..<500 { await Task.yield() }
    }

    // MARK: - Network wait

    @Test(arguments: [PlaybackSessionStatus.alive, .gone])
    func noAttemptWhileOfflineThenAnImmediateRetryOnceOnline(session: PlaybackSessionStatus) async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        paths.isOnline = false

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        await drain()
        // Only the five-minute limit is waiting: no backoff, attempt or lookup spends the budget.
        #expect(h.recoverySleep.durations == [.seconds(300)])
        #expect(engine.seeks.count == seeks)
        #expect(service.starts == ["A"])
        #expect(lookups.isEmpty)
        #expect(coordinator.isPlaybackRequested)

        setSession(session)
        paths.isOnline = true
        await settle { engine.isPlaybackRequested }

        // The session decides: alive re-seeks the same session, gone rebuilds with a new one.
        #expect(lookups == ["A-1"])
        if session == .alive {
            #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
            #expect(service.starts == ["A"])
        } else {
            #expect(engine.seeks.count == seeks)
            #expect(service.starts == ["A", "A"])
            #expect(engine.loads.last?.time == 600)
        }
        // At once: no backoff after the wait, whose limit was cancelled.
        #expect(h.recoverySleep.durations == [.seconds(300)])
        #expect(h.recoverySleep.waitingCount == 0)
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.error == nil)
    }

    @Test func fiveMinutesOfflineSurfacesTheError() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        paths.isOnline = false

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .recoveryExhausted)
        #expect(engine.seeks.count == seeks)
        #expect(service.starts == ["A"])
        #expect(coordinator.currentTime == 600)
        #expect(paths.openStreams == 0)
    }

    @Test func aStopWhileOfflineEndsTheWaitWithoutAnAttempt() async {
        h.recoverySleep.isManual = true
        await playAt600()
        paths.isOnline = false
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }

        await coordinator.stop()
        paths.isOnline = true
        await drain()

        #expect(service.starts == ["A"])
        #expect(lookups.isEmpty)
        #expect(coordinator.error == nil)
    }

    // MARK: - Session check

    @Test func a404WithTheSessionAliveReseeksTheSameSession() async {
        h.recoverySleep.elapsesImmediately = true
        setSession(.alive)
        await playAt600()
        let seeks = engine.seeks.count

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 404))))
        await settle { engine.isPlaybackRequested }

        #expect(lookups == ["A-1"])
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(service.starts == ["A"])
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
    }

    @Test func a404WithTheSessionGoneRecoversThroughOneRebuild() async {
        h.recoverySleep.elapsesImmediately = true
        setSession(.gone)
        await playAt600()
        let seeks = engine.seeks.count

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 404))))
        await settle { service.starts.count == 2 && engine.isPlaybackRequested }

        #expect(lookups == ["A-1"])
        #expect(engine.seeks.count == seeks)
        #expect(engine.loads.last?.time == 600)
        // Counted as the first rebuild, with its backoff.
        #expect(h.recoverySleep.durations == [.seconds(1)])
        #expect(coordinator.session?.id == "A-2")
        #expect(coordinator.error == nil)
    }

    @Test func networkLossWithTheSessionAliveReseeksInsteadOfRebuilding() async {
        h.recoverySleep.elapsesImmediately = true
        setSession(.alive)
        await playAt600()

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { engine.isPlaybackRequested }

        #expect(engine.seeks.last == 600)
        #expect(service.starts == ["A"])
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
    }

    @Test func a401OnTheLookupTakesTheRefreshPath() async {
        h.recoverySleep.elapsesImmediately = true
        setSession(.unauthorized)
        await playAt600()

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 404))))
        await settle { service.starts.count == 2 && engine.isPlaybackRequested }

        #expect(service.state.withLock { $0.refreshes } == 1)
        #expect(coordinator.error == nil)
    }

    // MARK: - A user seek during recovery

    @Test func aSeekReplacingOneThatTookOverRecoveryStillPlays() async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        let gate = Gate()
        engine.seekGates = [gate]

        let first = Task { await coordinator.seek(to: 1200) }
        await settle { engine.seeks.last == 1200 }
        #expect(await coordinator.seek(to: 1800) == 1800)
        gate.open()
        #expect(await first.value == nil)
        await drain()

        #expect(engine.isPlaybackRequested)
        #expect(coordinator.currentTime == 1800)
        #expect(service.starts == ["A"])
    }

    @Test func aFailedSeekThatTookOverRecoveryKeepsItsPlay() async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        let gate = Gate()
        engine.seekGates = [gate]
        engine.seekResults = [.failed]

        let seek = Task { await coordinator.seek(to: 1200) }
        await settle { engine.seeks.last == 1200 }
        // As the real engine does, the failure is reported before the seek returns.
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        gate.open()
        #expect(await seek.value == nil)
        #expect(coordinator.isPlaybackRequested)

        h.recoverySleep.elapsesImmediately = true
        while h.recoverySleep.waitingCount > 0 { h.recoverySleep.fireOldest() }
        await settle { engine.isPlaybackRequested }

        #expect(engine.seeks.last == 1200)
        #expect(coordinator.currentTime == 1200)
        #expect(coordinator.error == nil)
    }

    // MARK: - Interruptions

    @Test(arguments: [false, true])
    func aCallDuringRecoveryCancelsItsPlayUntilTheCallEnds(endsDuringBackoff: Bool) async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(coordinator.isPlaybackRequested)

        handler.handle(.interruptionBegan)
        #expect(!coordinator.isPlaybackRequested)
        if !endsDuringBackoff {
            // Recovery goes on, paused: it never starts audio during the call.
            h.recoverySleep.fireOldest()
            await settle { engine.seeks.count > seeks }
            await drain()
            #expect(!engine.isPlaybackRequested)
        }

        handler.handle(.interruptionEnded(shouldResume: true))
        await drain()
        if endsDuringBackoff { h.recoverySleep.fireOldest() }
        await settle { engine.isPlaybackRequested }
        #expect(coordinator.error == nil)
    }

    @Test func aCallEndingWithoutAResumptionLeavesRecoveryPaused() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: false))
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count > seeks }
        await drain()

        #expect(!engine.isPlaybackRequested)
        #expect(!coordinator.isPlaybackRequested)
    }
}

/// Paths that tests switch by hand; each stream yields the current path first, as
/// `SystemNetworkPathSource` does.
final class RecoveryPathSource: NetworkPathSource, Sendable {
    private struct State {
        var isOnline = true
        var sinks: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]
    }

    private let state = Mutex(State())

    var isOnline: Bool {
        get { state.withLock { $0.isOnline } }
        set {
            let sinks = state.withLock {
                $0.isOnline = newValue
                return Array($0.sinks.values)
            }
            for sink in sinks { sink.yield(newValue ? .wifi : .offline) }
        }
    }

    /// Streams whose consumer hasn't stopped.
    var openStreams: Int { state.withLock { $0.sinks.count } }

    func paths() -> AsyncStream<NetworkPath> {
        let (stream, sink) = AsyncStream.makeStream(of: NetworkPath.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        sink.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.sinks.removeValue(forKey: id) } }
        let online = state.withLock {
            $0.sinks[id] = sink
            return $0.isOnline
        }
        sink.yield(online ? .wifi : .offline)
        return stream
    }
}
