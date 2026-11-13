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
}
