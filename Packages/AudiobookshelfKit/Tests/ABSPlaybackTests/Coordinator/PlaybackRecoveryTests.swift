import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// ADR 0007 Decision 3 recovery, through the coordinator with a scripted engine and server.
@MainActor
struct PlaybackRecoveryTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
    }

    static func failure(_ kind: PlaybackFailure.Kind) -> PlaybackFailure {
        PlaybackFailure(kind: kind, domain: "CoreMediaErrorDomain", code: -12938, description: "fixture")
    }

    /// Plays A from 600 (an explicit start, so no rewind).
    private func playAt600() async {
        await coordinator.play(itemID: "A", startTime: 600)
        #expect(coordinator.isPlaying)
        #expect(coordinator.currentTime == 600)
    }

    /// Yields until `condition` holds; recovery crosses several actors per attempt.
    private func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Recovery never settled", sourceLocation: sourceLocation)
    }

    // MARK: - Retries and rebuilds

    @Test func transientFailureResumesAtTheSamePositionInTheSameSession() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        let seeks = engine.seeks.count

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
        #expect(service.starts == ["A"])
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
    }

    @Test func aPausedItemRecoversPaused() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        coordinator.pause()
        let seeks = engine.seeks.count

        engine.fail(.playerFailed(Self.failure(.http(status: 503))))
        await settle { engine.seeks.count > seeks }

        #expect(engine.seeks.last == 600)
        #expect(!engine.isPlaybackRequested)
        #expect(coordinator.error == nil)
    }

    @Test func permanentFailureSurfacesAfterTheRetryAndRebuildBudgets() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.seekResults = Array(repeating: .failed, count: 5)
        engine.loadError = .itemFailed(trackIndex: 0, Self.failure(.http(status: 503)))
        let loads = engine.loads.count

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .recoveryExhausted)
        #expect(h.events.events.last == .failed(.recoveryExhausted))
        // Five re-seeks, then three rebuilds and no fourth `/play`.
        #expect(service.starts == ["A", "A", "A", "A"])
        #expect(
            h.recoverySleep.durations == [
                .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                .seconds(1), .seconds(2), .seconds(4),
            ])
        // Every rebuild targets the saved position.
        #expect(engine.loads.dropFirst(loads).map(\.time) == [600, 600, 600])
        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.currentTime == 600)
        // Nothing but the final error was surfaced.
        #expect(h.events.events.filter { if case .failed = $0 { true } else { false } }.count == 1)
    }

    @Test func networkLossRebuildsAtTheSavedPositionNotTheServers() async {
        h.recoverySleep.elapsesImmediately = true
        h.settings.playbackRate = 1.5
        await playAt600()
        // The new session's server position is older; a rebuild never uses it.
        h.setServerProgress("A", time: 100, updated: h.clock.now)

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { service.starts.count == 2 && engine.isPlaybackRequested }

        #expect(engine.loads.last?.time == 600)
        #expect(coordinator.currentTime == 600)
        #expect(engine.defaultRate == 1.5)
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
        await coordinator.waitForPendingCloses()
        #expect(service.closes == ["A-1"])
        #expect(h.recoverySleep.durations == [.seconds(1)])
    }

    @Test func aRebuiltItemFailingBeforeTheAttemptReturnsCountsAsAFailedAttempt() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        var failedOnce = false
        _ = coordinator.addObserver { event in
            guard case .loaded = event, !failedOnce else { return }
            failedOnce = true
            engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        }

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { service.starts.count == 3 && engine.isPlaybackRequested }

        #expect(h.recoverySleep.durations == [.seconds(1), .seconds(2)])
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
    }

    @Test func theEpisodeResetsAfterThirtySecondsOfPlayback() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }

        engine.onEvent?(.tick(601))
        h.clock.advance(by: 30)
        engine.onEvent?(.tick(631))
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }

        // A fresh budget: the second failure starts again at the first backoff.
        #expect(h.recoverySleep.durations == [.milliseconds(500), .milliseconds(500)])
    }

    @Test func theEpisodeKeepsItsBudgetWithoutThirtySecondsOfPlayback() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }

        engine.onEvent?(.tick(601))
        h.clock.advance(by: 29)
        engine.onEvent?(.tick(630))
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }

        #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(1)])
    }

    // MARK: - Not recoverable

    @Test(arguments: [
        PlaybackFailure.Kind.http(status: 403), .http(status: 400), .tls, .decode, .unsupported, .cancelled,
    ])
    func unrecoverableFailuresSurfaceAtOnce(kind: PlaybackFailure.Kind) async {
        await playAt600()
        let seeks = engine.seeks.count
        let failure = Self.failure(kind)

        engine.fail(.playerFailed(failure))

        #expect(coordinator.error == .playback(failure))
        #expect(h.events.events.last == .failed(.playback(failure)))
        #expect(engine.seeks.count == seeks)
        #expect(h.recoverySleep.durations.isEmpty)
    }

    @Test func nonTransientSessionStartFailureDuringARebuildSurfacesIt() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        service.state.withLock { $0.startError = .sessionExpired }

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .sessionStartFailed(.sessionExpired))
        #expect(h.events.events.last == .failed(.sessionStartFailed(.sessionExpired)))
        #expect(service.starts == ["A", "A"])
    }

    // MARK: - 401

    @Test func a401RefreshesOnceAndASecond401Stops() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))
        await settle { service.starts.count == 2 && engine.isPlaybackRequested }
        #expect(service.state.withLock { $0.refreshes } == 1)
        // The token the rejected stream used, so one another request already replaced is reused.
        #expect(service.state.withLock { $0.refreshedTokens } == ["token-A-1"])
        #expect(coordinator.error == nil)
        #expect(engine.loads.last?.time == 600)

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))

        #expect(coordinator.error == .streamRejected)
        #expect(h.events.events.last == .failed(.streamRejected))
        for _ in 0..<200 { await Task.yield() }
        #expect(service.state.withLock { $0.refreshes } == 1)
        #expect(service.starts == ["A", "A"])
    }

    /// A session lookup whose request refreshed the token spends the episode's one refresh, so a
    /// later 401 stops instead of refreshing again (#491). Without that refresh, the 401 refreshes.
    @Test(arguments: [true, false])
    func aLookupThatRefreshedSpendsTheRefresh(lookupRefreshed: Bool) async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        service.state.withLock {
            $0.sessionStatus = .alive
            $0.sessionRefreshesToken = lookupRefreshed
        }
        let seeks = engine.seeks.count

        // A 503 checks the session before its re-seek.
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.seeks.count > seeks && engine.isPlaybackRequested }
        #expect(service.state.withLock { $0.sessionLookups } == ["A-1"])
        #expect(coordinator.error == nil)

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))

        if lookupRefreshed {
            #expect(coordinator.error == .streamRejected)
            #expect(h.events.events.last == .failed(.streamRejected))
            for _ in 0..<200 { await Task.yield() }
            #expect(service.state.withLock { $0.refreshes } == 0)
            #expect(service.starts == ["A"])
        } else {
            await settle { service.starts.count == 2 && engine.isPlaybackRequested }
            #expect(service.state.withLock { $0.refreshes } == 1)
            #expect(coordinator.error == nil)
        }
    }

    /// A user seek that takes the run over while the lookup is held doesn't lose the lookup's
    /// refresh: the episode stays, and so does the charge.
    @Test(arguments: [true, false])
    func aLookupRefreshHeldAcrossASeekIsCharged(lookupRefreshed: Bool) async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        let gate = Gate()
        service.state.withLock {
            $0.sessionStatus = .alive
            $0.sessionRefreshesToken = lookupRefreshed
            $0.sessionGate = gate
        }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { service.state.withLock { $0.sessionLookups.count } == 1 }

        #expect(await coordinator.seek(to: 1200) == 1200)
        gate.open()
        for _ in 0..<200 { await Task.yield() }
        #expect(coordinator.error == nil)

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))

        if lookupRefreshed {
            #expect(coordinator.error == .streamRejected)
            for _ in 0..<200 { await Task.yield() }
            #expect(service.state.withLock { $0.refreshes } == 0)
            #expect(service.starts == ["A"])
        } else {
            await settle { service.starts.count == 2 }
            #expect(service.state.withLock { $0.refreshes } == 1)
            #expect(coordinator.error == nil)
        }
    }

    @Test func aFailedRefreshStopsWithoutARebuild() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        service.state.withLock { $0.refreshError = .sessionExpired }

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))
        await settle { coordinator.error != nil }

        // Reported as a session failure, so the account scope asks to sign in again.
        #expect(coordinator.error == .sessionStartFailed(.sessionExpired))
        #expect(service.starts == ["A"])
    }

    @Test func givingUpWhileLoadedReleasesTheAudioSessionAndKeepsThePosition() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        service.state.withLock { $0.refreshError = .sessionExpired }
        let stops = engine.stopCount

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))
        await settle { coordinator.error != nil }

        // Unloaded as after a failed load: the session is closed and the audio session released.
        #expect(coordinator.phase == .unloaded)
        #expect(engine.stopCount == stops + 1)
        #expect(!engine.isAudioSessionActive)
        await settle { service.closes == ["A-1"] }
        #expect(coordinator.mediaKey == h.key("A"))
        #expect(coordinator.currentTime == 600)

        // Play retries it where it failed.
        service.state.withLock { $0.refreshError = nil }
        await coordinator.resume()
        #expect(service.starts == ["A", "A"])
        #expect(engine.loads.last?.time == 600)
    }

    // MARK: - Supersession

    @Test(arguments: [false, true])
    func aStoppedOrReplacedItemIsNotRecovered(stops: Bool) async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        if stops { coordinator.stop() } else { await coordinator.play(itemID: "B") }
        let seeks = engine.seeks.count
        let plays = engine.playCount
        h.recoverySleep.fireOldest()
        for _ in 0..<200 { await Task.yield() }

        #expect(engine.seeks.count == seeks)
        #expect(engine.playCount == plays)
        #expect(service.starts == (stops ? ["A"] : ["A", "B"]))
        #expect(coordinator.mediaKey == (stops ? nil : h.key("B")))
        #expect(coordinator.error == nil)
    }

    @Test func aSeekDuringTheBackoffWinsAndPlays() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        #expect(await coordinator.seek(to: 1200) == 1200)
        h.recoverySleep.fireOldest()
        for _ in 0..<200 { await Task.yield() }

        #expect(Array(engine.seeks.dropFirst(seeks)) == [1200])
        #expect(coordinator.currentTime == 1200)
        #expect(coordinator.isPlaying)
        #expect(service.starts == ["A"])
    }

    @Test func aStaleRecoverySeekNeverWritesThePosition() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        let gate = Gate()
        engine.seekGates = [gate]
        let seeks = engine.seeks.count
        let events = h.events.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.seeks.count == seeks + 1 }

        // The user seeks while recovery's seek to 600 is in flight; then that one returns.
        #expect(await coordinator.seek(to: 1200) == 1200)
        gate.open()
        for _ in 0..<200 { await Task.yield() }

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600, 1200])
        #expect(coordinator.currentTime == 1200)
        #expect(h.lastPlayed.record?.position == 1200)
        #expect(!h.events.since(events).contains(.didSeek(time: 600)))
        #expect(h.events.since(events).contains(.didSeek(time: 1200)))
        #expect(coordinator.isPlaying)
    }

    @Test func aPauseDuringRecoveryKeepsItPaused() async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        // Recovery's intent is the coordinator's while the failed engine holds none, so a toggle
        // pauses the pending restart rather than resuming.
        #expect(coordinator.isPlaybackRequested)
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.last == 600 && engine.pendingSeekTarget == nil }
        for _ in 0..<200 { await Task.yield() }

        #expect(!engine.isPlaybackRequested)
    }

    @Test func aLostOutputDuringRecoveryKeepsItPaused() async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }

        // Headphones unplugged during the backoff: the retry must not play on the speaker.
        engine.pauseForOutputLoss()
        #expect(!coordinator.isPlaybackRequested)
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.last == 600 && engine.pendingSeekTarget == nil }
        for _ in 0..<200 { await Task.yield() }

        #expect(!engine.isPlaybackRequested)
        #expect(coordinator.error == nil)
    }

    /// Where a held rebuild fails, once released.
    enum RebuildFailure: Sendable, CaseIterable {
        case start, load
    }

    /// Network loss during A at 600, then the first rebuild's backoff fires with its `/play` held
    /// (and the rebuild failing at `failure`, once released); returns the held start's gate.
    private func holdFirstRebuild(failing failure: RebuildFailure? = nil) async -> Gate {
        h.recoverySleep.isManual = true
        await playAt600()
        let gate = Gate()
        service.state.withLock {
            $0.startGates["A"] = gate
            if failure == .start { $0.startError = .network(.networkConnectionLost) }
        }
        if failure == .load { engine.loadError = .itemFailed(trackIndex: 0, Self.failure(.network)) }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { coordinator.phase == .starting && service.state.withLock { $0.startGates.isEmpty } }
        return gate
    }

    /// Opens the held rebuild, lets its load fail, and runs the next rebuild with a working load.
    private func failHeldRebuildAndRetry(_ gate: Gate) async {
        gate.open()
        await settle { coordinator.phase == .unloaded && h.recoverySleep.waitingCount == 1 }
        engine.loadError = nil
        service.state.withLock { $0.startError = nil }
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 3 && coordinator.phase == .loaded }
        for _ in 0..<200 { await Task.yield() }
    }

    @Test(arguments: [false, true])
    func aLostOutputWhileARebuildStartsOrWaitsKeepsItPaused(betweenAttempts: Bool) async {
        let gate = await holdFirstRebuild(failing: betweenAttempts ? .load : nil)
        if betweenAttempts {
            gate.open()
            await settle { coordinator.phase == .unloaded && h.recoverySleep.waitingCount == 1 }
            engine.loadError = nil
        }

        // Unplugged while no item is loaded: the coming rebuild must not play on the speaker.
        engine.pauseForOutputLoss()
        #expect(!coordinator.isPlaybackRequested)
        if betweenAttempts { h.recoverySleep.fireOldest() } else { gate.open() }
        await settle { coordinator.phase == .loaded }
        for _ in 0..<200 { await Task.yield() }

        #expect(!engine.isPlaybackRequested)
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.error == nil)
    }

    @Test(arguments: RebuildFailure.allCases, [false, true])
    func aPauseThenPlayDuringAFailingRebuildPlaysTheNextOne(failure: RebuildFailure, samePlay: Bool) async {
        let gate = await holdFirstRebuild(failing: failure)

        coordinator.pause()
        if samePlay {
            await coordinator.play(itemID: "A")
        } else {
            await coordinator.resume()
        }
        #expect(coordinator.isPlaybackRequested)
        await failHeldRebuildAndRetry(gate)

        #expect(engine.isPlaybackRequested)
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.error == nil)
    }

    @Test(arguments: RebuildFailure.allCases, [false, true])
    func aSeekDuringAFailingRebuildIsWhereTheNextOneStarts(failure: RebuildFailure, jumps: Bool) async {
        let gate = await holdFirstRebuild(failing: failure)

        _ = await coordinator.seek(to: 1200)
        if jumps { _ = await coordinator.jump(by: 30) }
        let target: Double = jumps ? 1230 : 1200
        await failHeldRebuildAndRetry(gate)

        #expect(engine.loads.last?.time == target)
        #expect(coordinator.currentTime == target)
        #expect(engine.isPlaybackRequested)
        #expect(coordinator.error == nil)
    }

    @Test func aSeekDuringTheLastFailingRebuildIsWhereARetryStarts() async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.loadError = .itemFailed(trackIndex: 0, Self.failure(.network))
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        for starts in 2...3 {
            await settle { h.recoverySleep.waitingCount == 1 }
            h.recoverySleep.fireOldest()
            await settle { service.starts.count == starts && coordinator.phase == .unloaded }
        }
        // The third, last rebuild: the user seeks while its `/play` is held, and it fails.
        let gate = Gate()
        service.state.withLock {
            $0.startGates["A"] = gate
            $0.startError = .network(.networkConnectionLost)
        }
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { coordinator.phase == .starting && service.state.withLock { $0.startGates.isEmpty } }
        _ = await coordinator.seek(to: 1200)
        gate.open()
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .recoveryExhausted)
        #expect(coordinator.currentTime == 1200)
        engine.loadError = nil
        service.state.withLock { $0.startError = nil }
        await coordinator.resume()
        await settle { coordinator.phase == .loaded && engine.isPlaybackRequested }
        #expect(engine.loads.last?.time == 1200)
    }

    @Test(arguments: [false, true])
    func aSeekWhileARebuildFinishesItsLoadStillPlays(seekLandsFirst: Bool) async {
        h.recoverySleep.isManual = true
        await playAt600()
        let load = Gate()
        engine.loadGates = [load]
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { engine.loads.count == 2 }
        // A seek during the load makes the rebuild's load path catch up to it; that is held.
        _ = await coordinator.seek(to: 1200)
        let catchUp = Gate()
        let userSeek = Gate()
        engine.seekGates = [catchUp, userSeek]
        let seeks = engine.seeks.count
        load.open()
        await settle { engine.seeks.count == seeks + 1 }

        // The user seeks again while the rebuild is finishing its load.
        let seek = Task { _ = await coordinator.seek(to: 1500) }
        await settle { engine.seeks.count == seeks + 2 }
        if seekLandsFirst {
            userSeek.open()
            await seek.value
            catchUp.open()
        } else {
            catchUp.open()
            for _ in 0..<200 { await Task.yield() }
            userSeek.open()
            await seek.value
        }
        await settle { engine.isPlaybackRequested }

        #expect(coordinator.isPlaying)
        #expect(coordinator.currentTime == 1500)
        #expect(coordinator.error == nil)
    }

    @Test func aToggleBetweenFailedRebuildsPausesTheNextOne() async {
        let gate = await holdFirstRebuild(failing: .load)
        gate.open()
        await settle { coordinator.phase == .unloaded && h.recoverySleep.waitingCount == 1 }
        engine.loadError = nil

        // The pending restart is the coordinator's play request, so a toggle pauses it.
        #expect(coordinator.isPlaybackRequested)
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)
        // Toggling back plays the next rebuild without starting a session of its own.
        await coordinator.resume()
        #expect(coordinator.isPlaybackRequested)
        #expect(service.starts.count == 2)
        coordinator.pause()

        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 3 && coordinator.phase == .loaded }
        for _ in 0..<200 { await Task.yield() }

        #expect(!engine.isPlaybackRequested)
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.error == nil)
        #expect(h.recoverySleep.durations == [.seconds(1), .seconds(2)])
    }

    @Test func aTransientStreamResolutionFailureDuringARebuildIsRetried() async {
        h.recoverySleep.isManual = true
        await playAt600()
        // The rebuilt stream's token refresh fails offline.
        service.state.withLock { $0.resolveError = APIError.network(.notConnectedToInternet) }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 2 && h.recoverySleep.waitingCount == 1 }
        #expect(coordinator.error == nil)

        service.state.withLock { $0.resolveError = nil }
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 3 && engine.isPlaybackRequested }

        #expect(engine.loads.last?.time == 600)
        #expect(coordinator.error == nil)
        #expect(h.recoverySleep.durations == [.seconds(1), .seconds(2)])
    }

    @Test func aSupersededRebuildReturningLateLeavesTheNewItemsAttempt() async {
        h.recoverySleep.isManual = true
        await playAt600()
        // A's rebuild holds at its load.
        let gateA = Gate()
        engine.loadGates = [gateA]
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        let loads = engine.loads.count
        h.recoverySleep.fireOldest()
        await settle { engine.loads.count == loads + 1 }

        // B replaces it, fails, and its own rebuild holds at its load.
        await coordinator.play(itemID: "B", startTime: 100)
        #expect(coordinator.isPlaying)
        let gateB = Gate()
        engine.loadGates = [gateB]
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { engine.loads.count == loads + 3 }

        // A's rebuild returns superseded; then B's rebuilt item fails before its attempt returns.
        gateA.open()
        for _ in 0..<200 { await Task.yield() }
        var armed = true
        _ = coordinator.addObserver { event in
            guard case .loaded = event, armed else { return }
            armed = false
            engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        }
        gateB.open()
        await settle { h.recoverySleep.waitingCount == 1 }

        // The same episode's second rebuild, not a fresh episode's first.
        #expect(h.recoverySleep.durations == [.seconds(1), .seconds(1), .seconds(2)])
        h.recoverySleep.fireOldest()
        await settle { coordinator.phase == .loaded && engine.isPlaybackRequested }
        #expect(coordinator.mediaKey == h.key("B"))
        #expect(engine.loads.last?.time == 100)
        #expect(coordinator.error == nil)
    }

    @Test(arguments: [false, true])
    func aPlayOfTheSameItemBetweenFailedRebuildsKeepsTheEpisode(startsElsewhere: Bool) async {
        let gate = await holdFirstRebuild(failing: .load)
        gate.open()
        await settle { coordinator.phase == .unloaded && h.recoverySleep.waitingCount == 1 }
        engine.loadError = nil
        coordinator.pause()

        // Play from the item's page: recovery's next rebuild plays it, at the start time if given.
        await coordinator.play(itemID: "A", startTime: startsElsewhere ? 900 : nil)
        #expect(coordinator.isPlaybackRequested)
        #expect(service.starts.count == 2)
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 3 && coordinator.phase == .loaded }
        await settle { engine.isPlaybackRequested }

        let target: Double = startsElsewhere ? 900 : 600
        #expect(engine.loads.last?.time == target)
        #expect(coordinator.currentTime == target)
        #expect(coordinator.error == nil)
        #expect(h.recoverySleep.durations == [.seconds(1), .seconds(2)])
    }

    @Test func aLostOutputDiscardsAPlayAwaitingItsStreamingCheck() async {
        let gate = Gate()
        h.policy.gate = gate
        let play = Task { await coordinator.play(itemID: "A") }
        await settle { h.policy.checks == 1 }

        engine.pauseForOutputLoss()
        #expect(!coordinator.isPlaybackRequested)
        gate.open()
        await play.value

        #expect(service.starts.isEmpty)
        #expect(!engine.isPlaybackRequested)
    }

    @Test(arguments: [false, true])
    func aPauseDuringASeekThatTookOverRecoveryKeepsItPaused(outputLost: Bool) async {
        h.recoverySleep.isManual = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        let gate = Gate()
        engine.seekGates = [gate]

        let seek = Task { await coordinator.seek(to: 1200) }
        await settle { engine.seeks.last == 1200 }
        // The seek carries recovery's intent to play.
        #expect(coordinator.isPlaybackRequested)
        if outputLost { engine.pauseForOutputLoss() } else { coordinator.pause() }
        #expect(!coordinator.isPlaybackRequested)
        gate.open()
        #expect(await seek.value == 1200)
        for _ in 0..<200 { await Task.yield() }

        #expect(!engine.isPlaybackRequested)
        #expect(coordinator.currentTime == 1200)
    }

    // MARK: - Episode interval

    @Test(arguments: [false, true])
    func aPauseRestartsTheThirtySecondInterval(systemPause: Bool) async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }
        engine.onEvent?(.tick(601))

        if systemPause {
            // An interruption pauses the engine directly; the player reports the rate change.
            engine.pause()
            engine.onEvent?(.tick(601))
        } else {
            coordinator.pause()
        }
        h.clock.advance(by: 30)
        engine.play()
        engine.onEvent?(.tick(602))
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }

        // Thirty seconds passed, but not of playback: the budget carries on.
        #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(1)])
    }
}
