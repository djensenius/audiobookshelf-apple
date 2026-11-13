import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// ADR 0007 Decision 3: stalls draw on the readiness budget, and a decode or format error on direct
/// play rebuilds once as an HLS transcode (Part of #527).
@MainActor
struct PlaybackStallFallbackTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
    }

    static func failure(_ kind: PlaybackFailure.Kind) -> PlaybackFailure {
        PlaybackFailure(kind: kind, domain: "AVFoundationErrorDomain", code: -11829, description: "fixture")
    }

    /// Plays A from 600 (an explicit start, so no rewind).
    private func playAt600() async {
        await coordinator.play(itemID: "A", startTime: 600)
        #expect(coordinator.isPlaying)
        #expect(coordinator.currentTime == 600)
    }

    /// Stalls as the real engine reports it: buffering, with play still requested.
    private func stall() {
        engine.state = .buffering
        engine.onEvent?(.stalled)
    }

    /// Yields until `condition` holds; recovery crosses several actors per attempt.
    private func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Recovery never settled", sourceLocation: sourceLocation)
    }

    private var failedEvents: Int {
        h.events.events.count { if case .failed = $0 { true } else { false } }
    }

    // MARK: - Stalls

    @Test func aStallReseeksTheSameSessionToTheRecoveryTarget() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        let seeks = engine.seeks.count

        stall()
        await settle { engine.seeks.count > seeks && coordinator.isPlaying }

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
        #expect(h.recoverySleep.durations == [.milliseconds(500)])
        #expect(service.starts == ["A"])
        #expect(coordinator.error == nil)
    }

    @Test func aStallThatResolvesBeforeItsAttemptSpendsNoBudget() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count

        stall()
        await settle { h.recoverySleep.waitingCount == 1 }
        // Playback resumes on its own during the backoff.
        engine.state = .playing
        engine.onEvent?(.tick(601))
        h.recoverySleep.fireOldest()
        for _ in 0..<200 { await Task.yield() }

        #expect(engine.seeks.count == seeks)
        #expect(coordinator.error == nil)
        #expect(coordinator.isPlaying)

        // Nothing was spent: the next stall starts at the first backoff again.
        stall()
        await settle { h.recoverySleep.waitingCount == 1 }
        #expect(h.recoverySleep.durations == [.milliseconds(500), .milliseconds(500)])
    }

    @Test func aTickWhileStillStalledKeepsTheRetry() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let seeks = engine.seeks.count

        stall()
        await settle { h.recoverySleep.waitingCount == 1 }
        // The time observer fires, but the player is still waiting for media.
        engine.onEvent?(.tick(600))
        h.recoverySleep.fireOldest()
        await settle { engine.seeks.count > seeks && coordinator.isPlaying }

        #expect(Array(engine.seeks.dropFirst(seeks)) == [600])
    }

    @Test func aStallThatClearsIntoTheEndDoesNotPlayTheItemAgain() async {
        h.recoverySleep.isManual = true
        await playAt600()
        let (seeks, plays) = (engine.seeks.count, engine.playCount)

        stall()
        await settle { h.recoverySleep.waitingCount == 1 }
        // The stall clears and the item plays out before the time observer fires again.
        engine.finish()
        h.recoverySleep.fireOldest()
        for _ in 0..<1_000 { await Task.yield() }

        #expect(engine.seeks.count == seeks)
        #expect(engine.playCount == plays)
        #expect(engine.state == .ended)
        #expect(!coordinator.isPlaying)
        #expect(!coordinator.isPlaybackRequested)
        #expect(service.starts == ["A"])
        #expect(coordinator.error == nil)
    }

    @Test func stallsThatNeverClearExhaustTheBudgetsAndSurface() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.seekResults = Array(repeating: .failed, count: 5)
        engine.loadError = .itemFailed(trackIndex: 0, Self.failure(.http(status: 503)))

        stall()
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .recoveryExhausted)
        #expect(service.starts == ["A", "A", "A", "A"])
        #expect(
            h.recoverySleep.durations == [
                .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                .seconds(1), .seconds(2), .seconds(4),
            ])
        #expect(failedEvents == 1)
    }

    enum FailureDuringBackoff: CaseIterable {
        /// A decode error on direct play: the HLS fallback.
        case decodeOnDirectPlay
        /// A decode error on HLS: final.
        case decodeOnHLS
        /// A 401: the one refresh, then a rebuild.
        case unauthorized
    }

    /// The step a stall's backoff was for is not the one a failure during it needs.
    @Test(arguments: FailureDuringBackoff.allCases)
    func aFailureDuringAStallsBackoffTakesItsOwnStep(failure: FailureDuringBackoff) async {
        h.recoverySleep.isManual = true
        if failure == .decodeOnHLS { service.state.withLock { _ = $0.transcodeSessions.insert("A-1") } }
        await playAt600()
        let seeks = engine.seeks.count
        let error = Self.failure(failure == .unauthorized ? .http(status: 401) : .decode)

        stall()
        await settle { h.recoverySleep.waitingCount == 1 }
        engine.fail(.itemFailed(trackIndex: 0, error))
        h.recoverySleep.fireOldest()

        if failure == .decodeOnHLS {
            await settle { coordinator.error != nil }
            #expect(coordinator.error == .playback(error))
            #expect(h.recoverySleep.durations == [.milliseconds(500)])
            #expect(service.starts == ["A"])
        } else {
            // The new step's own backoff, then its rebuild.
            await settle { h.recoverySleep.waitingCount == 1 }
            h.recoverySleep.fireOldest()
            await settle { service.starts.count == 2 && coordinator.isPlaying }
            #expect(h.recoverySleep.durations == [.milliseconds(500), .seconds(1)])
            #expect(service.forcedTranscodes == [false, failure == .decodeOnDirectPlay])
            #expect(service.state.withLock { $0.refreshes } == (failure == .unauthorized ? 1 : 0))
            #expect(coordinator.error == nil)
        }
        // Not the stall's re-seek.
        #expect(engine.seeks.count == seeks)
    }

    enum FailureDuringRefresh: CaseIterable {
        /// None: the refresh's own rebuild.
        case none
        /// A decode error on direct play: the HLS fallback instead.
        case decodeOnDirectPlay
        /// A decode error on HLS: final.
        case decodeOnHLS
        /// A 401: the old token's, so the refresh's rebuild still runs.
        case unauthorized
    }

    /// A stall whose session lookup finds the token rejected refreshes it; a failure during that
    /// refresh is weighed before the rebuild after it, which would clear it.
    @Test(arguments: FailureDuringRefresh.allCases)
    func aFailureDuringAStallsRefreshTakesItsOwnStep(failure: FailureDuringRefresh) async {
        h.recoverySleep.isManual = true
        if failure == .decodeOnHLS { service.state.withLock { _ = $0.transcodeSessions.insert("A-1") } }
        await playAt600()
        let seeks = engine.seeks.count
        let refresh = Gate()
        service.state.withLock {
            $0.sessionStatus = .unauthorized
            $0.refreshGate = refresh
        }
        let decode = Self.failure(.decode)

        stall()
        await settle { h.recoverySleep.waitingCount == 1 }
        h.recoverySleep.fireOldest()
        await settle { service.state.withLock { $0.refreshes } == 1 }
        switch failure {
        case .none: break
        case .decodeOnDirectPlay, .decodeOnHLS: engine.fail(.itemFailed(trackIndex: 0, decode))
        case .unauthorized: engine.fail(.itemFailed(trackIndex: 0, Self.failure(.http(status: 401))))
        }
        refresh.open()

        switch failure {
        case .none, .unauthorized:
            await settle { service.starts.count == 2 && coordinator.isPlaying }
            #expect(service.forcedTranscodes == [false, false])
            #expect(h.recoverySleep.durations == [.seconds(1)])
            #expect(coordinator.error == nil)
        case .decodeOnDirectPlay:
            // The fallback's own backoff, then its forced rebuild: never the unforced one.
            await settle { h.recoverySleep.waitingCount == 1 }
            #expect(service.starts == ["A"])
            h.recoverySleep.fireOldest()
            await settle { service.starts.count == 2 && coordinator.isPlaying }
            #expect(service.forcedTranscodes == [false, true])
            #expect(engine.loads.last?.source.seekTolerance == 0.5)
            #expect(h.recoverySleep.durations == [.seconds(1), .seconds(1)])
            #expect(coordinator.error == nil)
        case .decodeOnHLS:
            await settle { coordinator.error != nil }
            #expect(coordinator.error == .playback(decode))
            #expect(failedEvents == 1)
            #expect(service.starts == ["A"])
            #expect(coordinator.phase == .unloaded)
        }
        // The one refresh, after the stall's one lookup; not the stall's re-seek.
        #expect(service.state.withLock { $0.refreshes } == 1)
        #expect(service.state.withLock { $0.sessionLookups } == ["A-1"])
        #expect(engine.seeks.count == seeks)
    }

    // MARK: - Direct play to HLS fallback

    @Test(arguments: [PlaybackFailure.Kind.decode, .unsupported])
    func aDecodeErrorWhilePlayingDirectRebuildsOnceAsAnHLSTranscode(kind: PlaybackFailure.Kind) async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()

        engine.fail(.itemFailed(trackIndex: 0, Self.failure(kind)))
        await settle { service.starts.count == 2 && coordinator.isPlaying }

        #expect(service.forcedTranscodes == [false, true])
        #expect(engine.loads.last?.time == 600)
        // An HLS source.
        #expect(engine.loads.last?.source.seekTolerance == 0.5)
        // A session rebuild: its backoff, and no session lookup.
        #expect(h.recoverySleep.durations == [.seconds(1)])
        #expect(service.state.withLock { $0.sessionLookups }.isEmpty)
        #expect(coordinator.error == nil)
        await coordinator.waitForPendingCloses()
        #expect(service.closes == ["A-1"])
    }

    @Test(arguments: [PlaybackFailure.Kind.decode, .unsupported])
    func aDecodeErrorLoadingDirectPlayFallsBackToHLS(kind: PlaybackFailure.Kind) async {
        h.recoverySleep.isManual = true
        engine.loadError = .itemFailed(trackIndex: 0, Self.failure(kind))

        await coordinator.play(itemID: "A", startTime: 600)
        await settle { h.recoverySleep.waitingCount == 1 }
        // Not surfaced: the fallback is coming.
        #expect(coordinator.error == nil)
        #expect(failedEvents == 0)
        engine.loadError = nil
        h.recoverySleep.fireOldest()
        await settle { service.starts.count == 2 && coordinator.isPlaying }

        #expect(service.forcedTranscodes == [false, true])
        #expect(engine.loads.map(\.time) == [600, 600])
        #expect(h.recoverySleep.durations == [.seconds(1)])
        #expect(coordinator.error == nil)
        #expect(failedEvents == 0)
    }

    /// ADR 0007, decision 7: a download never falls back to streaming silently. A decode or format
    /// error in downloaded files is final, while playing or at load, with no forced start on the
    /// server.
    @Test(arguments: [PlaybackFailure.Kind.decode, .unsupported], [false, true])
    func aDecodeErrorInADownloadIsFinal(kind: PlaybackFailure.Kind, atLoad: Bool) async {
        h.recoverySleep.elapsesImmediately = true
        let error = Self.failure(kind)
        // As ``LocalPlaybackSessionService`` builds it: a local session over direct-play files.
        let file = URL(filePath: "/downloads/A/1.mp3")
        service.state.withLock {
            $0.sessionOverride = PlaybackSession(
                id: "L-1", libraryItemId: "A", mediaType: .book, duration: 3600, playMethod: .local,
                audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 3600, mimeType: "audio/mpeg")])
            $0.streamOverride = ResolvedStream(
                plan: .localFiles([(url: file, mimeType: "audio/mpeg", startOffset: 0, duration: 3600)]), urls: [file])
        }
        if atLoad { engine.loadError = .itemFailed(trackIndex: 0, error) }
        await coordinator.play(itemID: "A", startTime: 600)
        if !atLoad {
            #expect(coordinator.isPlaying)
            #expect(coordinator.session?.playMethod == .local)
            engine.fail(.itemFailed(trackIndex: 0, error))
        }
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .playback(error))
        #expect(failedEvents == 1)
        #expect(service.forcedTranscodes == [false])
        #expect(service.starts == ["A"])
        #expect(h.recoverySleep.durations.isEmpty)
        #expect(coordinator.phase == .unloaded)
    }

    enum HLSStart: CaseIterable {
        /// The server chose a transcode.
        case session
        /// The fallback's own session.
        case fallback
    }

    @Test(arguments: HLSStart.allCases, [false, true])
    func aDecodeErrorOnHLSIsFinal(start: HLSStart, atLoad: Bool) async {
        h.recoverySleep.elapsesImmediately = true
        let decode = Self.failure(.decode)
        if start == .session { service.state.withLock { _ = $0.transcodeSessions.insert("A-1") } }
        if start == .fallback || !atLoad { await playAt600() }
        if start == .fallback {
            if atLoad { engine.loadError = .itemFailed(trackIndex: 0, decode) }
            engine.fail(.itemFailed(trackIndex: 0, decode))
            if !atLoad {
                await settle { service.starts.count == 2 && coordinator.isPlaying }
                engine.fail(.itemFailed(trackIndex: 0, decode))
            }
        } else if atLoad {
            engine.loadError = .itemFailed(trackIndex: 0, decode)
            await coordinator.play(itemID: "A", startTime: 600)
        } else {
            engine.fail(.itemFailed(trackIndex: 0, decode))
        }
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .playback(decode))
        #expect(h.events.events.last == .failed(.playback(decode)))
        #expect(failedEvents == 1)
        // At most the one fallback.
        #expect(service.forcedTranscodes == (start == .session ? [false] : [false, true]))
        #expect(h.recoverySleep.durations == (start == .session ? [] : [.seconds(1)]))
        #expect(coordinator.phase == .unloaded)
    }

    @Test func aServerIgnoringTheForcedTranscodeGetsNoSecondFallback() async {
        h.recoverySleep.elapsesImmediately = true
        service.state.withLock { $0.ignoresForceTranscode = true }
        let decode = Self.failure(.decode)
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, decode))
        await settle { service.starts.count == 2 && coordinator.isPlaying }

        // Direct play again: the fallback already ran for this play.
        engine.fail(.itemFailed(trackIndex: 0, decode))
        await settle { coordinator.error != nil }

        #expect(coordinator.error == .playback(decode))
        #expect(service.forcedTranscodes == [false, true])
    }

    @Test func theFallbackStaysForcedAcrossRebuildsAndRunsOncePerPlay() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.decode)))
        await settle { service.starts.count == 2 && coordinator.isPlaying }

        // A later rebuild of the transcode asks for one again.
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.network)))
        await settle { service.starts.count == 3 && coordinator.isPlaying }
        #expect(service.forcedTranscodes == [false, true, true])

        // A new play starts on direct play, with its own fallback.
        coordinator.stop()
        await coordinator.play(itemID: "A", startTime: 100)
        #expect(service.forcedTranscodes == [false, true, true, false])
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.decode)))
        await settle { service.starts.count == 5 && coordinator.isPlaying }
        #expect(service.forcedTranscodes == [false, true, true, false, true])
        #expect(engine.loads.last?.time == 100)
        #expect(coordinator.error == nil)
    }

    /// A session the server lost (#184) is replaced as a transcode too: the fallback is for the play.
    @Test func replacingAGoneSessionKeepsTheFallbacksTranscode() async throws {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.decode)))
        await settle { service.starts.count == 2 && coordinator.isPlaying }
        let gone = try #require(coordinator.session?.id)

        // A replacement does nothing until the fallback's recovery run has ended.
        for _ in 0..<20_000 where service.starts.count == 2 {
            await coordinator.replaceGoneSession(gone)
            await Task.yield()
        }

        #expect(service.forcedTranscodes == [false, true, true])
        // An HLS source, at the same position.
        #expect(engine.loads.last?.source.seekTolerance == 0.5)
        #expect(engine.loads.last?.time == 600)
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
    }

    // MARK: - Metered consent

    /// A decode error on A's direct play, whose HLS fallback rebuild the policy then blocks ("ask"
    /// on a metered path).
    private func blockTheFallback() async {
        h.recoverySleep.elapsesImmediately = true
        await playAt600()
        h.policy.decision = .askUser(.cellular)
        engine.fail(.itemFailed(trackIndex: 0, Self.failure(.decode)))
        await settle { coordinator.error != nil }
        #expect(coordinator.error == .streamingNeedsConfirmation(.cellular, key: h.key("A")))
        // Blocked before its `/play`.
        #expect(service.forcedTranscodes == [false])
        #expect(coordinator.phase == .unloaded)
    }

    /// "Stream anyway" on a blocked fallback starts its HLS transcode at once: the direct play that
    /// failed isn't loaded again first.
    @Test func confirmingABlockedFallbackStartsItsTranscode() async {
        await blockTheFallback()

        await coordinator.confirmMeteredStreaming()

        #expect(coordinator.error == nil)
        #expect(service.forcedTranscodes == [false, true])
        #expect(engine.loads.count == 2)
        // An HLS source, where recovery stopped.
        #expect(engine.loads.last?.source.seekTolerance == 0.5)
        #expect(engine.loads.last?.time == 600)
        #expect(coordinator.isPlaying)
    }

    /// A play the policy blocked is confirmed as direct play, including one that replaced a blocked
    /// fallback (of another item).
    @Test(arguments: [false, true])
    func confirmingABlockedPlayStartsDirectPlay(afterABlockedFallback: Bool) async {
        if afterABlockedFallback { await blockTheFallback() }
        h.policy.decision = .askUser(.cellular)
        await coordinator.play(itemID: "B", startTime: 100)
        #expect(coordinator.error == .streamingNeedsConfirmation(.cellular, key: h.key("B")))

        await coordinator.confirmMeteredStreaming()

        #expect(service.forcedTranscodes == (afterABlockedFallback ? [false, false] : [false]))
        #expect(coordinator.mediaKey == h.key("B"))
        #expect(engine.loads.last?.source.seekTolerance == 0)
        #expect(coordinator.isPlaying)
    }

    enum PlayAfterABlockedFallback: CaseIterable {
        /// The user cancelled the confirmation, then played the item.
        case afterDeclining
        /// The user played the item while the confirmation was still showing.
        case instead
    }

    /// Only "Stream anyway" keeps a blocked fallback: the user's own play of the item starts direct
    /// play again, and a later confirmation replays nothing.
    @Test(arguments: PlayAfterABlockedFallback.allCases)
    func aUsersPlayAfterABlockedFallbackStartsDirectPlay(play: PlayAfterABlockedFallback) async {
        await blockTheFallback()
        if play == .afterDeclining {
            coordinator.declineMeteredStreaming()
            #expect(coordinator.error == nil)
        }
        // Back on an unmetered path.
        h.policy.decision = .allowed

        await coordinator.play(itemID: "A", startTime: 600)

        #expect(service.forcedTranscodes == [false, false])
        #expect(engine.loads.last?.source.seekTolerance == 0)
        #expect(coordinator.error == nil)
        #expect(coordinator.isPlaying)
        await coordinator.confirmMeteredStreaming()
        #expect(service.forcedTranscodes == [false, false])
    }
}
