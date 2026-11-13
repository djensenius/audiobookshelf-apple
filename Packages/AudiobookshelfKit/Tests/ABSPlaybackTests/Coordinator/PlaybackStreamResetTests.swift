import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// ADR 0007's `stream_reset`: the server restarted the session's transcode, so recovery re-seeks
/// it to the recovery target with the segment-readiness backoff restarted, once per episode, and
/// only for the loaded, streamed session (Part of #527).
@MainActor
struct PlaybackStreamResetTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
    }

    private static func failure(_ kind: PlaybackFailure.Kind) -> PlaybackFailure {
        PlaybackRecoveryTests.failure(kind)
    }

    /// Plays A from 600 (an explicit start, so no rewind), in session A-1.
    private func playAt600() async {
        await coordinator.play(itemID: "A", startTime: 600)
        #expect(coordinator.isPlaying)
        #expect(coordinator.session?.id == "A-1")
    }

    private var lookups: [String] { service.state.withLock { $0.sessionLookups } }

    /// Yields until `condition` holds; recovery crosses several actors per attempt.
    private func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Recovery never settled", sourceLocation: sourceLocation)
    }

    /// Gives an ignored reset the chance to start anything.
    private func drain() async {
        for _ in 0..<500 { await Task.yield() }
    }

    /// Ends every manual sleep still waiting, so no run outlives the test.
    private func fireAll() {
        while h.recoverySleep.waitingCount > 0 { h.recoverySleep.fireOldest() }
    }

    // MARK: - The loaded session

    @Test func aResetOfThePlayingSessionReseeksItOnceAfterTheFirstDelay() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count

        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 1 }
        // The first readiness delay; nothing re-seeks before it ends.
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
        #expect(engine.seeks.count == seeks)
        #expect(coordinator.isPlaybackRequested)

        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count == seeks + 1 }
        await drain()

        // One re-seek to the recovery target, in the same session, still playing; the server just
        // reported the stream, so there is no session lookup.
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
        #expect(service.starts == ["A"])
        #expect(lookups.isEmpty)
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
        #expect(h.recoverySleep.waitingCount == 0)
    }

    @Test func aPausedItemIsReseekedPaused() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        coordinator.pause()
        let seeks = engine.seeks.count
        let plays = engine.playCount

        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { engine.seeks.count == seeks + 1 }
        await drain()

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(engine.playCount == plays)
        #expect(!coordinator.isPlaybackRequested)
    }

    /// A stall while the reset's run waits is the reset's: playback resuming on its own doesn't
    /// end the re-seek, as it ends a stall's own run (Part of #527).
    @Test func aStallDuringAResetKeepsItsReseek() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count

        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 1 }
        // The restarted transcode stalls the player, which then plays again before the delay ends.
        engine.state = .buffering
        engine.onEvent?(.stalled)
        engine.state = .playing
        engine.onEvent?(.tick(600))
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count == seeks + 1 }
        await drain()

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
        #expect(service.starts == ["A"])
        #expect(lookups.isEmpty)
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
        #expect(h.recoverySleep.waitingCount == 0)
    }

    @Test func aResetDuringReadinessRetriesRestartsTheirBackoff() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        // The first two retries' seeks fail, as segments still missing do.
        engine.seekResults = [.failed, .failed]
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 404))))
        for _ in 0..<2 {
            await settle { h.recoverySleep.waitingCount == 1 }
            h.recoverySleep.fireOldest()
        }
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(1), .seconds(2)])
        #expect(engine.seeks.count == seeks + 2)
        #expect(lookups == ["A-1", "A-1", "A-1"])

        // Mid-way through the 2 s delay: the backoff starts again at 0.5 s.
        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 2 }
        #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(1), .seconds(2), .milliseconds(500)])

        // The superseded 2 s delay ends first, and its run does nothing; then the reset's re-seeks.
        h.recoverySleep.fireOldest()
        await drain()
        #expect(engine.seeks.count == seeks + 2)
        h.recoverySleep.fireOldest()
        await settle { engine.isPlaybackRequested }
        await drain()

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600, 600, 600])
        #expect(coordinator.isPlaying)
        #expect(coordinator.currentTime == 600)
        #expect(service.starts == ["A"])
        #expect(lookups == ["A-1", "A-1", "A-1"])
        #expect(h.recoverySleep.durations.count == 4)
        #expect(h.recoverySleep.waitingCount == 0)
    }

    /// ADR 0007's "a `stream_reset` that arrives while a user seek is in flight ends at that
    /// seek's target".
    @Test func aResetDuringAUserSeekEndsAtThatSeeksTarget() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        let gate = Gate()
        engine.seekGates = [gate]
        let seek = Task { await coordinator.seek(to: 1200) }
        await settle { engine.seeks.count == seeks + 1 }

        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count == seeks + 2 }
        gate.open()
        _ = await seek.value
        await drain()

        #expect(Array(engine.seeks.dropFirst(seeks)) == [1200, 1200])
        #expect(coordinator.currentTime == 1200)
        #expect(engine.currentTime == 1200)
        #expect(coordinator.isPlaybackRequested)
    }

    // MARK: - Once

    @Test func aRepeatedResetDoesNotRestartTheBackoffAgain() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count

        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 1 }
        // While its run waits, and again after it re-seeked: the episode has had its reset.
        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()
        #expect(h.recoverySleep.waitingCount == 1)
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count == seeks + 1 }
        await drain()
        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()

        #expect(h.recoverySleep.durations == [.milliseconds(500)])
        #expect(h.recoverySleep.waitingCount == 0)
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])

        // Control: 30 s of playback ends the episode, and the next reset applies.
        engine.onEvent?(.tick(601))
        h.clock.advance(by: 30)
        engine.onEvent?(.tick(631))
        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(h.recoverySleep.durations == [.milliseconds(500), .milliseconds(500)])
        fireAll()
        await settle { engine.seeks.count == seeks + 2 }
    }

    @Test func aResetAfterAFailureRetryOfTheSameEpisodeStillAppliesOnce() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        let seeks = engine.seeks.count
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { engine.isPlaybackRequested }
        #expect(h.recoverySleep.durations == [.milliseconds(500)])

        // Recovered, but inside the episode: the reset restarts the backoff, once.
        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { engine.seeks.count == seeks + 2 }
        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()

        #expect(h.recoverySleep.durations == [.milliseconds(500), .milliseconds(500)])
        #expect(Array(engine.seeks.dropFirst(seeks)) == [600, 600])
        #expect(coordinator.isPlaying)
    }

    @Test func aResetAfterARebuildIsIgnored() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        service.state.withLock { $0.sessionStatus = .gone }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { service.starts == ["A", "A"] && engine.isPlaybackRequested }
        let rebuilt = coordinator.session?.id
        #expect(rebuilt == "A-2")
        let seeks = engine.seeks.count
        let sleeps = h.recoverySleep.durations.count

        // The rebuilt item is new, so recovery only rebuilds it until the episode ends.
        coordinator.handleStreamReset(sessionID: "A-2")
        await drain()

        #expect(engine.seeks.count == seeks)
        #expect(h.recoverySleep.durations.count == sleeps)
        #expect(service.starts == ["A", "A"])
        #expect(coordinator.isPlaying)
    }

    // MARK: - A rebuild or refresh the lookup chose

    /// A readiness failure's session lookup picks the next attempt. A gone session takes a
    /// rebuild and a rejected one a refresh (then a rebuild), which a reset during their backoff
    /// mustn't replace with a re-seek. Control: an alive session retries readiness, and the reset
    /// restarts that backoff.
    @Test(arguments: [PlaybackSessionStatus.alive, .gone, .unauthorized])
    func aResetDuringTheBackoffALookupChoseAppliesOnlyToAReseek(session: PlaybackSessionStatus) async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        service.state.withLock { $0.sessionStatus = session }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(lookups == ["A-1"])

        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()

        if session == .alive {
            #expect(h.recoverySleep.durations == [.milliseconds(500), .milliseconds(500)])
            fireAll()
            await settle { engine.seeks.count == seeks + 1 && engine.isPlaybackRequested }
            await drain()
            #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
            #expect(service.starts == ["A"])
        } else {
            // Ignored: the 1 s rebuild backoff is the only wait, and A-1 is never re-seeked.
            #expect(h.recoverySleep.durations == [.seconds(1)])
            #expect(h.recoverySleep.waitingCount == 1)
            h.recoverySleep.fireOldest()
            await settle { service.starts == ["A", "A"] && engine.isPlaybackRequested }
            await drain()
            #expect(coordinator.session?.id == "A-2")
            #expect(engine.loads.last?.time == 600)
            #expect(engine.seeks.count == seeks)
            #expect(service.state.withLock { $0.refreshes } == (session == .unauthorized ? 1 : 0))
        }
        #expect(coordinator.error == nil)
        #expect(coordinator.isPlaying)
        #expect(h.recoverySleep.waitingCount == 0)
    }

    /// A reset while the refresh a rejected lookup chose is awaited is ignored, so that refresh's
    /// rebuild still runs, or its error still surfaces.
    @Test(arguments: [false, true])
    func aResetDuringTheRefreshALookupChoseIsIgnored(refreshFails: Bool) async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count
        let gate = Gate()
        service.state.withLock {
            $0.sessionStatus = .unauthorized
            $0.refreshGate = gate
            $0.refreshError = refreshFails ? .sessionExpired : nil
        }
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 503))))
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { service.state.withLock { $0.refreshes } == 1 }

        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()
        #expect(h.recoverySleep.durations == [.seconds(1)])
        #expect(h.recoverySleep.waitingCount == 0)

        gate.open()
        if refreshFails {
            await settle { coordinator.error != nil }
            #expect(coordinator.error == .sessionStartFailed(.sessionExpired))
            #expect(service.starts == ["A"])
        } else {
            await settle { service.starts == ["A", "A"] && engine.isPlaybackRequested }
            #expect(coordinator.session?.id == "A-2")
            #expect(engine.loads.last?.time == 600)
            #expect(coordinator.error == nil)
        }
        await drain()
        #expect(engine.seeks.count == seeks)
        #expect(lookups == ["A-1"])
        #expect(service.state.withLock { $0.refreshes } == 1)
        #expect(h.recoverySleep.durations == [.seconds(1)])
    }

    // MARK: - Ignored

    @Test func anotherSessionsResetIsIgnored() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count

        // The server sends every stream's reset to every socket.
        for id in ["A-2", "B-1", "a-1", ""] { coordinator.handleStreamReset(sessionID: id) }
        await drain()

        #expect(h.recoverySleep.durations.isEmpty)
        #expect(engine.seeks.count == seeks)
        #expect(coordinator.isPlaying)

        // Control: this session's own reset applies.
        coordinator.handleStreamReset(sessionID: "A-1")
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
        fireAll()
        await settle { engine.seeks.count == seeks + 1 }
    }

    @Test func aResetWithNothingLoadedIsIgnored() async {
        h.recoverySleep.elapsesImmediately = true

        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()
        #expect(coordinator.phase == .idle)

        // Nor after the session stopped.
        await playAt600()
        coordinator.stop(reason: .user)
        let seeks = engine.seeks.count
        coordinator.handleStreamReset(sessionID: "A-1")
        await drain()

        #expect(h.recoverySleep.durations.isEmpty)
        #expect(engine.seeks.count == seeks)
        #expect(engine.loads.count == 1)
        #expect(service.starts == ["A"])
    }

    /// Local playback has no server stream; the transcode, as the control, does.
    @Test(arguments: [PlayMethod.local, .transcode])
    func aLocallyPlayedItemIgnoresResets(method: PlayMethod) async {
        h.recoverySleep.elapsesImmediately = true
        service.state.withLock {
            $0.sessionOverride = PlaybackSession(
                id: "L-1", libraryItemId: "A", mediaType: .book, duration: 3600, playMethod: method,
                audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 3600, mimeType: "audio/mpeg")])
        }
        await coordinator.play(itemID: "A", startTime: 600)
        #expect(coordinator.session?.playMethod == method)
        let seeks = engine.seeks.count

        coordinator.handleStreamReset(sessionID: "L-1")
        await drain()

        if method == .local {
            #expect(h.recoverySleep.durations.isEmpty)
            #expect(engine.seeks.count == seeks)
        } else {
            await settle { engine.seeks.count == seeks + 1 }
            #expect(h.recoverySleep.durations == [.milliseconds(500)])
            #expect(engine.seeks.last == 600)
        }
        #expect(coordinator.isPlaying)
    }
}
