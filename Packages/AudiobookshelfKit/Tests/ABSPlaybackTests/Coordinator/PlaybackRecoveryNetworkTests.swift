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

    /// The path drops again during the lookup after it returned (no refresh): the attempt waits
    /// for it, then runs after another lookup.
    @Test func connectivityLostDuringTheLookupHoldsTheAttempt() async {
        h.recoverySleep.isManual = true
        setSession(.alive)
        await playAt600()
        let seeks = engine.seeks.count
        paths.isOnline = false
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }

        let lookup = Gate()
        service.state.withLock { $0.sessionGate = lookup }
        paths.isOnline = true
        await settle { lookups == ["A-1"] && h.recoverySleep.waitingCount == 0 }
        paths.isOnline = false
        lookup.open()
        await settle { h.recoverySleep.waitingCount == 1 }
        await drain()
        #expect(engine.seeks.count == seeks)
        #expect(service.starts == ["A"])

        paths.isOnline = true
        await settle { engine.isPlaybackRequested }
        #expect(lookups == ["A-1", "A-1"])
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
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

    @Test func connectivityLostDuringTheBackoffHoldsTheAttemptUntilItReturns() async {
        h.recoverySleep.isManual = true
        setSession(.alive)
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        let checked = lookups.count
        // The path drops while the backoff is held: when it ends, no attempt runs offline.
        paths.isOnline = false
        h.recoverySleep.fireOldest()
        await settle { h.recoverySleep.waitingCount == 1 }
        await drain()
        #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(300)])
        #expect(engine.seeks.count == seeks)
        #expect(lookups.count == checked)

        // Back online: the attempt runs at once, after a fresh session check, with no new backoff.
        paths.isOnline = true
        await settle { engine.isPlaybackRequested }
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(lookups.count == checked + 1)
        #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(300)])

        // Only the attempt that ran was charged: the next failure takes the second retry delay.
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(h.recoverySleep.durations.last == .seconds(1))
    }

    @Test func anExhaustedRebuildBudgetSurfacesTheErrorWithoutWaitingForTheNetwork() async {
        h.recoverySleep.isManual = true
        setSession(.gone)
        await playAt600()
        engine.loadError = .itemFailed(trackIndex: 0, Self.failure(.network))
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 404))))
        for starts in 2...3 {
            await settle { h.recoverySleep.waitingCount == 1 }
            h.recoverySleep.fireOldest()
            await settle { service.starts.count == starts }
        }
        await settle { h.recoverySleep.waitingCount == 1 }
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 4 }

        // The last rebuild fails offline: nothing is left to wait for.
        paths.isOnline = false
        gate.open()
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .recoveryExhausted)
        #expect(h.recoverySleep.durations == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(h.recoverySleep.waitingCount == 0)
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

    /// The path drops while the refresh is in flight: the rebuild waits for it, checks the session
    /// once it returns, and doesn't refresh again.
    @Test(arguments: [PlaybackSessionStatus.gone, .unauthorized])
    func connectivityLostDuringTheRefreshHoldsTheRebuildUntilItReturns(session: PlaybackSessionStatus) async {
        h.recoverySleep.isManual = true
        await playAt600()
        let gate = Gate()
        service.state.withLock { $0.refreshGate = gate }

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { service.state.withLock { $0.refreshes } == 1 }
        paths.isOnline = false
        gate.open()
        await settle { h.recoverySleep.waitingCount == 1 }
        await drain()

        // Offline: no `/play`, no rebuild budget spent, only the five-minute limit waiting.
        #expect(service.starts == ["A"])
        #expect(h.recoverySleep.durations.last == .seconds(300))
        #expect(lookups.isEmpty)

        setSession(session)
        paths.isOnline = true
        if session == .gone {
            await settle { service.starts.count == 2 && engine.isPlaybackRequested }
            #expect(engine.loads.last?.time == 600)
            #expect(coordinator.error == nil)
        } else {
            // Still rejected after the one refresh: it stops.
            await settle { coordinator.error != nil }
            #expect(coordinator.error == .streamRejected)
            #expect(service.starts == ["A"])
        }
        #expect(lookups == ["A-1"])
        #expect(service.state.withLock { $0.refreshes } == 1)
        #expect(h.recoverySleep.waitingCount == 0)
    }

    /// The path drops again during the lookup after it returned: no rebuild until it is back, and
    /// then only after another lookup.
    @Test func connectivityLostDuringThePostRefreshLookupHoldsTheRebuild() async {
        h.recoverySleep.isManual = true
        setSession(.gone)
        await playAt600()
        let refresh = Gate()
        service.state.withLock { $0.refreshGate = refresh }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { service.state.withLock { $0.refreshes } == 1 }
        paths.isOnline = false
        refresh.open()
        await settle { h.recoverySleep.waitingCount == 1 }

        let lookup = Gate()
        service.state.withLock { $0.sessionGate = lookup }
        paths.isOnline = true
        await settle { lookups == ["A-1"] && h.recoverySleep.waitingCount == 0 }
        paths.isOnline = false
        lookup.open()
        await settle { h.recoverySleep.waitingCount == 1 }
        await drain()

        // Offline again: no `/play`, only a new wait.
        #expect(service.starts == ["A"])
        #expect(h.recoverySleep.durations.suffix(2) == [.seconds(300), .seconds(300)])

        paths.isOnline = true
        await settle { service.starts.count == 2 && engine.isPlaybackRequested }
        #expect(lookups == ["A-1", "A-1"])
        #expect(service.state.withLock { $0.refreshes } == 1)
        #expect(engine.loads.last?.time == 600)
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

        // A second call, with no play in between, has nothing to restore.
        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: true))
        await drain()

        #expect(!engine.isPlaybackRequested)
        #expect(!coordinator.isPlaybackRequested)
    }

    /// A call while the previous item plays and the next one awaits its streaming check: the
    /// pending play never starts.
    @Test func aCallCancelsAPlayAwaitingItsStreamingCheck() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        await playAt600()
        let gate = Gate()
        h.policy.gate = gate
        let play = Task { await coordinator.play(itemID: "B") }
        await settle { h.policy.checks == 2 }

        handler.handle(.interruptionBegan)
        gate.open()
        await play.value
        handler.handle(.interruptionEnded(shouldResume: true))
        await drain()

        #expect(service.starts == ["A"])
        #expect(coordinator.mediaKey == h.key("A"))
    }

    /// A pause after the call ends, before the restored play runs, wins.
    @Test func aPauseAfterTheCallEndsBeatsTheRestoredPlay() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        handler.handle(.interruptionBegan)
        // Recovery succeeds, paused, during the call.
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count > seeks }
        await drain()

        handler.handle(.interruptionEnded(shouldResume: true))
        coordinator.pause()
        await drain()

        #expect(!engine.isPlaybackRequested)
        #expect(!coordinator.isPlaybackRequested)
    }

    /// A pause during the call while the item is starting: the call's end doesn't play it.
    @Test func aPauseDuringTheCallWhileStartingIsKept() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let play = Task { await coordinator.play(itemID: "A", startTime: 600) }
        await settle { service.starts.count == 1 }

        handler.handle(.interruptionBegan)
        coordinator.pause()
        handler.handle(.interruptionEnded(shouldResume: true))
        gate.open()
        await play.value
        await drain()

        #expect(engine.loads.count == 1)
        #expect(!engine.isPlaybackRequested)
    }

    /// A call during a start's catch-up seek: the load path still starts playback once the call
    /// ends, whether that is before or after the seek lands.
    @Test(arguments: [false, true])
    func aCallDuringTheCatchUpSeekStillPlaysOnceItEnds(endsAfterTheSeek: Bool) async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        let load = Gate()
        engine.loadGates = [load]
        let play = Task { await coordinator.play(itemID: "A", startTime: 600) }
        await settle { engine.loads.count == 1 }
        _ = await coordinator.seek(to: 1200)
        let catchUp = Gate()
        engine.seekGates = [catchUp]
        load.open()
        await settle { engine.seeks.count == 1 }

        handler.handle(.interruptionBegan)
        #expect(!coordinator.isPlaybackRequested)
        if endsAfterTheSeek {
            catchUp.open()
            await play.value
            await drain()
            #expect(!engine.isPlaybackRequested)
        }
        handler.handle(.interruptionEnded(shouldResume: true))
        if !endsAfterTheSeek {
            catchUp.open()
            await play.value
        }
        await settle { engine.isPlaybackRequested }

        #expect(coordinator.currentTime == 1200)
        #expect(coordinator.error == nil)
    }

    /// The call ends while recovery waits: only its play intent comes back. No auto-rewind or
    /// seek of the coordinator's own replaces its bounded attempt.
    @Test func aLongCallEndingDuringRecoveryRestoresOnlyItsPlay() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        // A pause records when playback last ran, so a resume after the call would rewind.
        coordinator.pause()
        await coordinator.resume()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        handler.handle(.interruptionBegan)
        h.clock.advance(by: 600)
        handler.handle(.interruptionEnded(shouldResume: true))
        await drain()

        #expect(engine.seeks.count == seeks)
        #expect(!engine.isPlaybackRequested)
        #expect(h.recoverySleep.waitingCount == 1)
        #expect(coordinator.isPlaybackRequested)
        h.recoverySleep.fireOldest()
        await settle { engine.isPlaybackRequested }
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(coordinator.currentTime == 600)
    }

    /// A repeated begin with nothing new to cancel keeps what the first one held.
    @Test func aRepeatedCallBeginKeepsTheHeldPlay() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        handler.handle(.interruptionBegan)
        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: true))
        h.recoverySleep.fireOldest()
        await settle { engine.isPlaybackRequested }
        #expect(coordinator.currentTime == 600)
    }

    /// A call spanning a recovery rebuild (the session is gone): its end plays the rebuilt item,
    /// whether it ends while the rebuild starts or after it loaded.
    @Test(arguments: [false, true])
    func aCallSpanningARecoveryRebuildPlaysItOnceItEnds(endsAfterTheRebuild: Bool) async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        setSession(.gone)
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 404))))
        await settle { h.recoverySleep.waitingCount == 1 }

        handler.handle(.interruptionBegan)
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 2 }
        if endsAfterTheRebuild {
            gate.open()
            await settle { engine.loads.count == 2 }
            await drain()
            #expect(!engine.isPlaybackRequested)
            handler.handle(.interruptionEnded(shouldResume: true))
        } else {
            handler.handle(.interruptionEnded(shouldResume: true))
            gate.open()
        }
        await settle { engine.isPlaybackRequested }

        #expect(coordinator.session?.id == "A-2")
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.error == nil)
    }

    /// A call that ends and another that begins before the restore runs: nothing plays during the
    /// second call, and its end restores the play.
    @Test func aCallBeginningBeforeTheRestoreRunsCancelsIt() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        handler.handle(.interruptionBegan)
        // Recovery succeeds, paused, during the call.
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count > seeks }
        await drain()

        handler.handle(.interruptionEnded(shouldResume: true))
        handler.handle(.interruptionBegan)
        await drain()
        #expect(!engine.isPlaybackRequested)
        #expect(!coordinator.isPlaybackRequested)

        handler.handle(.interruptionEnded(shouldResume: true))
        await settle { engine.isPlaybackRequested }
    }

    /// A stop right after the call ends cancels the queued restore.
    @Test func aStopAfterTheCallEndsCancelsTheRestore() async {
        let handler = AudioInterruptionHandler(engine: engine)
        handler.heldPlayIntent = coordinator
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        handler.handle(.interruptionBegan)
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count > seeks }
        await drain()
        let plays = engine.playCount

        handler.handle(.interruptionEnded(shouldResume: true))
        coordinator.stop()
        await drain()

        #expect(engine.playCount == plays)
        #expect(coordinator.mediaKey == nil)
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
