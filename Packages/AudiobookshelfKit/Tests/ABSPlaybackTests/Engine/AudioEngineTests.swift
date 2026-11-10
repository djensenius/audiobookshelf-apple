import ABSCore
import AVFoundation
import Foundation
import Testing

@testable import ABSPlayback

extension Tag {
    /// Tests that play media in real time.
    @Tag static var realtimeAudio: Self
}

/// Plays real (silent, muted) 3-second WAV tracks. Serialized to keep real-time waits short and
/// predictable; each test waits well under a second of media time.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AudioEngineTests {
    private func makeEngine(session: FakeAudioSession? = nil) -> AudioEngine {
        let engine = AudioEngine(audioSession: session, timeObserverInterval: 0.05)
        engine.player.isMuted = true
        // Time playback with the host clock so it does not depend on an audio device (headless CI).
        engine.player.sourceClock = CMClockGetHostTimeClock()
        return engine
    }

    @Test func loadQueuesFromStartTrackAndSeeks() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }

        try await engine.load(fixture.source, at: 4)

        #expect(engine.state == .paused)
        #expect(engine.currentTime == 4)
        #expect(engine.currentTrackIndex == 1)
        #expect(engine.duration == 9)
        #expect(engine.pendingSeekTarget == nil)
        #expect(engine.isPlaybackRequested == false)
        #expect(engine.player.items().count == 2)
        #expect(abs((engine.player.currentItem?.currentTime().seconds ?? -1) - 1) < 0.01)
        #expect(events.withoutTicks == [.trackChanged(1)])
        #expect(engine.player.items().allSatisfy { $0.audioTimePitchAlgorithm == .timeDomain })
    }

    @Test func loadRejectsInvalidSources() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()

        await #expect(throws: AudioEngineError.emptyTimeline) {
            try await engine.load(
                AudioEngineSource(timeline: PlaybackTimeline(tracks: [], chapters: []), trackURLs: []), at: 0)
        }
        await #expect(throws: AudioEngineError.trackURLMismatch(expected: 3, actual: 1)) {
            try await engine.load(
                AudioEngineSource(timeline: fixture.timeline, trackURLs: [fixture.urls[0]]), at: 0)
        }
        #expect(engine.state == .idle)
    }

    @Test func loadFailsForUnreadableFile() async throws {
        let fixture = try AudioFixture(trackCount: 1)
        let engine = makeEngine()
        let missing = fixture.directory.appending(path: "missing.wav")
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }

        await #expect {
            try await engine.load(AudioEngineSource(timeline: fixture.timeline, trackURLs: [missing]), at: 0)
        } throws: { error in
            guard case .itemFailed(trackIndex: 0, let failure) = error as? AudioEngineError else { return false }
            // Observed on macOS 27.2: AVFoundationErrorDomain -11800 over NSOSStatusErrorDomain -17913.
            return failure.domain == AVFoundationErrorDomain && failure.underlyingDomain != nil
        }
        guard case .failed = engine.state else {
            Issue.record("Expected failed state, got \(engine.state)")
            return
        }
        #expect(events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test(.tags(.realtimeAudio)) func playAdvancesTimeAndPauseStops() async throws {
        let fixture = try AudioFixture()
        let session = FakeAudioSession()
        let engine = makeEngine(session: session)
        try await engine.load(fixture.source, at: 0)

        engine.play()

        #expect(engine.isPlaybackRequested)
        #expect(session.activations == 1)
        #expect(await eventually { engine.state == .playing && engine.currentTime > 0.1 })

        engine.pause()
        #expect(engine.state == .paused)
        #expect(engine.isPlaybackRequested == false)
        #expect(engine.player.rate == 0)
    }

    @Test func seekAcrossTracksRebuildsQueue() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        let source = AudioEngineSource(timeline: fixture.timeline, trackURLs: fixture.urls, prefersPreciseTiming: true)
        try await engine.load(source, at: 0)

        #expect(await engine.seek(to: 7.5) == .completed)
        #expect(engine.currentTrackIndex == 2)
        #expect(engine.currentTime == 7.5)
        #expect(engine.player.items().count == 1)
        #expect(abs((engine.player.currentItem?.currentTime().seconds ?? -1) - 1.5) < 0.01)

        #expect(await engine.seek(to: 1) == .completed)
        #expect(engine.currentTrackIndex == 0)
        #expect(engine.currentTime == 1)
        #expect(engine.player.items().count == 3)

        #expect(await engine.seek(to: 1.5) == .completed)
        #expect(engine.currentTime == 1.5)
        #expect(events.withoutTicks == [.trackChanged(0), .trackChanged(2), .trackChanged(0)])
    }

    @Test(.tags(.realtimeAudio)) func seekWhilePlayingKeepsPlaying() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        try await engine.load(fixture.source, at: 0)
        engine.play()

        #expect(await engine.seek(to: 6.5) == .completed)

        #expect(engine.isPlaybackRequested)
        #expect(await eventually { engine.state == .playing && engine.currentTime > 6.5 })
        #expect(engine.currentTrackIndex == 2)
    }

    @Test func laterSeekSupersedesEarlierSeek() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        try await engine.load(fixture.source, at: 0)

        let first = Task { await engine.seek(to: 4) }
        try await waitUntil { engine.pendingSeekTarget == 4 }
        let second = await engine.seek(to: 7)

        #expect(await first.value == .superseded)
        #expect(second == .completed)
        #expect(engine.currentTime == 7)
        #expect(engine.currentTrackIndex == 2)
        #expect(engine.pendingSeekTarget == nil)
    }

    @Test(.tags(.realtimeAudio)) func defaultRateAppliesOnPlayAndAcrossTracks() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        try await engine.load(fixture.source, at: 2.7)

        engine.setRate(2)
        engine.setRate(0)
        engine.setRate(.nan)
        #expect(engine.defaultRate == 2)
        #expect(engine.player.defaultRate == 2)
        #expect(engine.player.rate == 0)

        engine.play()
        #expect(engine.player.rate == 2)
        #expect(await eventually { engine.currentTrackIndex == 1 && engine.currentTime > 3 })
        #expect(engine.player.rate == 2)
        #expect(!events.contains(.endOfMedia))

        engine.setRate(1.5)
        #expect(engine.player.rate == 1.5)
    }

    @Test(.tags(.realtimeAudio)) func endOfMediaEndsPlayback() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        try await engine.load(fixture.source, at: 8.8)
        engine.setRate(2)

        engine.play()

        #expect(await eventually { engine.state == .ended })
        #expect(events.last == .endOfMedia)
        #expect(engine.currentTime == 9)
        #expect(engine.isPlaybackRequested == false)

        engine.play()
        #expect(engine.state == .ended)

        #expect(await engine.seek(to: 0.5) == .completed)
        #expect(engine.state == .paused)
        #expect(engine.currentTrackIndex == 0)
        #expect(engine.player.items().count == 3)
    }

    @Test(.tags(.realtimeAudio)) func skipsNonPlayableTracks() async throws {
        let fixture = try AudioFixture()
        // The second track (1–2) lies inside the first, so it is not playable.
        let timeline = PlaybackTimeline(
            tracks: [
                AudioTrack(index: 1, startOffset: 0, duration: 3),
                AudioTrack(index: 3, startOffset: 3, duration: 3),
                AudioTrack(index: 2, startOffset: 1, duration: 1),
            ],
            chapters: [])
        #expect(timeline.tracks.map(\.isPlayable) == [true, false, true])
        let urls = timeline.tracks.map { fixture.urls[$0.sourceIndex] }
        let engine = makeEngine()
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }

        try await engine.load(AudioEngineSource(timeline: timeline, trackURLs: urls), at: 2.8)
        #expect(engine.player.items().count == 2)
        #expect(engine.currentTrackIndex == 0)

        engine.setRate(2)
        engine.play()
        #expect(await eventually { engine.currentTrackIndex == 2 && engine.currentTime > 3 })
        #expect(events.withoutTicks == [.trackChanged(0), .trackChanged(2)])

        #expect(await engine.seek(to: 1.5) == .completed)
        #expect(engine.currentTrackIndex == 0)
        #expect(engine.currentTime == 1.5)
    }

    @Test func stopClearsQueueAndDeactivatesSession() async throws {
        let fixture = try AudioFixture()
        let session = FakeAudioSession()
        let engine = makeEngine(session: session)
        try await engine.load(fixture.source, at: 1)
        engine.play()

        engine.stop()

        #expect(engine.state == .idle)
        #expect(engine.timeline == nil)
        #expect(engine.currentTrackIndex == nil)
        #expect(engine.player.items().isEmpty)
        #expect(session.deactivations == 1)
        #expect(await engine.seek(to: 1) == .failed)
    }

    @Test(.tags(.realtimeAudio)) func interruptionPausesAndResumesAtDefaultRate() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        let handler = AudioInterruptionHandler(engine: engine)
        try await engine.load(fixture.source, at: 0)
        engine.setRate(1.5)
        engine.play()

        handler.handle(.interruptionBegan)
        #expect(engine.state == .paused)
        #expect(engine.player.rate == 0)

        handler.handle(.interruptionEnded(shouldResume: true))
        #expect(engine.isPlaybackRequested)
        #expect(engine.player.rate == 1.5)
    }

    @Test func interruptedSeekRetriesOnceThenWaitsWithoutPlaying() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        try await engine.load(fixture.source, at: 0)
        engine.play()
        var attempts = 0
        engine.itemSeeker = { _, _, _ in
            attempts += 1
            return false
        }

        #expect(await engine.seek(to: 7) == .interrupted)

        #expect(attempts == 2)
        #expect(engine.pendingSeekTarget == 7)
        #expect(engine.currentTime < 7)
        #expect(engine.isPlaybackRequested)
        #expect(engine.player.rate == 0)
        #expect(engine.state == .buffering)

        // play() retries the pending seek, then plays from its target.
        engine.itemSeeker = AudioEngine(audioSession: nil).itemSeeker
        engine.play()
        #expect(await eventually { engine.pendingSeekTarget == nil && engine.state == .playing })
        #expect(engine.currentTime >= 7)
    }

    @Test func staleSeekRetryDoesNotOverwriteNewerSeek() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        try await engine.load(fixture.source, at: 0)
        engine.play()
        let seeker = engine.itemSeeker
        engine.itemSeeker = { _, _, _ in false }
        #expect(await engine.seek(to: 7) == .interrupted)
        engine.itemSeeker = seeker

        // play() schedules a retry to 7; the newer seek must win.
        engine.play()
        #expect(await engine.seek(to: 2) == .completed)
        #expect(await eventually { engine.state == .playing })

        #expect(engine.pendingSeekTarget == nil)
        #expect(engine.currentTrackIndex == 0)
        #expect(engine.currentTime >= 2 && engine.currentTime < 3)
    }

    @Test(.tags(.realtimeAudio)) func pendingSeekTargetSuppressesTicks() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        try await engine.load(fixture.source, at: 0)
        engine.itemSeeker = { _, _, _ in false }
        #expect(await engine.seek(to: 4.5) == .interrupted)
        #expect(engine.currentTrackIndex == 1)
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }

        // The replacement item plays from its unseeked start; its time must not be published.
        engine.player.play()
        #expect(await eventually { (engine.player.currentItem?.currentTime().seconds ?? 0) > 0.3 })

        #expect(engine.currentTime == 0)
        #expect(!events.contains { if case .tick = $0 { true } else { false } })
        #expect(engine.pendingSeekTarget == 4.5)
    }

    private func makeEngine(players: FailablePlayers) -> AudioEngine {
        let engine = AudioEngine(audioSession: nil, timeObserverInterval: 0.05, makePlayer: players.make)
        engine.player.isMuted = true
        engine.player.sourceClock = CMClockGetHostTimeClock()
        return engine
    }

    @Test(.tags(.realtimeAudio)) func playerFailureIsReportedAndSeekReplacesThePlayer() async throws {
        let fixture = try AudioFixture()
        let players = FailablePlayers()
        let engine = makeEngine(players: players)
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        try await engine.load(fixture.source, at: 1)
        engine.setRate(2)
        engine.play()
        #expect(await eventually { engine.state == .playing })

        players.created[0].forceFailure()

        #expect(await eventually { if case .failed(.playerFailed) = engine.state { true } else { false } })
        #expect(events.contains { if case .failed(.playerFailed) = $0 { true } else { false } })
        // The forced failure has no `player.error`.
        #expect(engine.state == .failed(.playerFailed(PlaybackFailure(error: nil))))
        #expect(!engine.isPlaybackRequested)

        #expect(await engine.seek(to: 4) == .completed)
        #expect(players.created.count == 2)
        #expect(engine.routingPlayer === players.created[1])
        #expect(engine.player.isMuted)
        #expect(engine.state == .paused)
        #expect(engine.currentTrackIndex == 1)

        engine.play()
        #expect(await eventually { engine.state == .playing && engine.currentTime > 4 })
        #expect(engine.player.rate == 2)
    }

    @Test func loadAfterPlayerFailureUsesAFreshPlayer() async throws {
        let fixture = try AudioFixture()
        let players = FailablePlayers()
        let engine = makeEngine(players: players)
        try await engine.load(fixture.source, at: 0)

        players.created[0].forceFailure()
        #expect(await eventually { if case .failed(.playerFailed) = engine.state { true } else { false } })

        try await engine.load(fixture.source, at: 2)
        #expect(players.created.count == 2)
        #expect(engine.routingPlayer === players.created[1])
        #expect(engine.state == .paused)
        #expect(engine.currentTime == 2)
    }

    @Test(.tags(.realtimeAudio)) func playDuringLoadStartsAfterTheSeek() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        let load = Task { try await engine.load(fixture.source, at: 4) }
        try await waitUntil { engine.state == .loading }

        engine.play()
        #expect(engine.player.rate == 0)
        #expect(engine.isPlaybackRequested)

        try await load.value
        #expect(await eventually { engine.state == .playing })
        #expect(engine.currentTime >= 4)
        #expect(engine.currentTrackIndex == 1)
    }

    @Test(.tags(.realtimeAudio)) func overlappingTrackEndsAtNextStart() async throws {
        let fixture = try AudioFixture(trackCount: 2)
        let timeline = PlaybackTimeline(
            tracks: [
                AudioTrack(index: 1, startOffset: 0, duration: 3),
                AudioTrack(index: 2, startOffset: 2.5, duration: 3),
            ],
            chapters: [])
        let engine = makeEngine()
        try await engine.load(AudioEngineSource(timeline: timeline, trackURLs: fixture.urls), at: 2.3)

        let items = engine.player.items()
        #expect(items.count == 2)
        #expect(items.first?.forwardPlaybackEndTime.seconds == 2.5)
        #expect(items.last?.forwardPlaybackEndTime.isValid == false)

        engine.setRate(2)
        engine.play()
        #expect(await eventually { engine.currentTrackIndex == 1 && engine.currentTime > 2.5 })
        #expect(engine.currentTime < 3)
    }

    @Test(.tags(.realtimeAudio)) func missingLaterTrackFailsAndSeekRetries() async throws {
        let fixture = try AudioFixture()
        let original = fixture.urls[1]
        let missing = fixture.directory.appending(path: "missing.wav")
        try FileManager.default.moveItem(at: original, to: missing)
        let engine = makeEngine()
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        try await engine.load(fixture.source, at: 2.8)

        engine.setRate(2)
        engine.play()

        // AVQueuePlayer drops the failed item and would play track 2; the engine fails on track 1.
        #expect(await eventually { if case .failed = engine.state { true } else { false } })
        #expect(
            events.contains {
                if case .failed(.itemFailed(trackIndex: 1, _)) = $0 { true } else { false }
            })
        #expect(engine.isPlaybackRequested == false)

        try FileManager.default.moveItem(at: missing, to: original)
        #expect(await engine.seek(to: 4) == .completed)
        #expect(engine.state == .paused)
        #expect(engine.currentTrackIndex == 1)
    }

    @Test(.tags(.realtimeAudio)) func itemFailureWaitsForItsErrorLog() async throws {
        let fixture = try AudioFixture()
        try FileManager.default.removeItem(at: fixture.urls[1])
        let engine = makeEngine()
        let log = GatedErrorLog()
        engine.errorLogFetcher = log.fetch
        try await engine.load(fixture.source, at: 2.8)
        engine.setRate(2)
        engine.play()

        try await waitUntil { log.fetches == 1 }
        // Not reported yet, and not playing past the failed track.
        #expect({ if case .failed = engine.state { false } else { true } }())
        #expect(engine.player.rate == 0)

        log.release([.init(domain: "CoreMediaErrorDomain", statusCode: -12_938, comment: "HTTP 404: File Not Found")])

        #expect(
            await eventually {
                if case .failed(.itemFailed(trackIndex: 1, let failure)) = engine.state {
                    failure.kind == .http(status: 404) && failure.domain == AVFoundationErrorDomain
                } else {
                    false
                }
            })
    }

    @Test(.tags(.realtimeAudio)) func delayedErrorLogDoesNotFailANewerQueue() async throws {
        let fixture = try AudioFixture()
        try FileManager.default.removeItem(at: fixture.urls[1])
        let engine = makeEngine()
        let log = GatedErrorLog()
        engine.errorLogFetcher = log.fetch
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        try await engine.load(fixture.source, at: 2.8)
        engine.setRate(2)
        engine.play()
        try await waitUntil { log.fetches == 1 }

        // The seek rebuilds the queue while the old item's log is still being fetched.
        #expect(await engine.seek(to: 0.5) == .completed)
        log.release([])
        try await waitUntil { log.pending == 0 }
        for _ in 0..<10 { await Task.yield() }

        #expect({ if case .failed = engine.state { false } else { true } }())
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(engine.currentTrackIndex == 0)
    }

    @Test func activationFailureDoesNotPlay() async throws {
        let fixture = try AudioFixture()
        let session = FakeAudioSession()
        session.activationError = FakeAudioSession.ActivationError()
        let engine = makeEngine(session: session)
        var events: [AudioEngineEvent] = []
        engine.onEvent = { events.append($0) }
        try await engine.load(fixture.source, at: 0)

        engine.play()

        #expect(engine.player.rate == 0)
        #expect(engine.isPlaybackRequested == false)
        #expect(engine.state == .paused)
        #expect(
            events.contains {
                if case .failed(.audioSessionActivationFailed) = $0 { true } else { false }
            })
    }

    @Test(.tags(.realtimeAudio)) func systemRateChangeCountsAsPause() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
        try await engine.load(fixture.source, at: 0)
        engine.play()
        #expect(await eventually { engine.state == .playing })

        engine.player.rate = 0
        NotificationCenter.default.post(
            name: AVPlayer.rateDidChangeNotification, object: engine.player,
            userInfo: [AVPlayer.rateDidChangeReasonKey: AVPlayer.RateDidChangeReason.appBackgrounded])

        #expect(await eventually { engine.isPlaybackRequested == false && engine.state == .paused })
    }

    @Test func preciseTimingFollowsSetting() {
        #expect(
            AudioEngine.assetOptions(prefersPreciseTiming: true)[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool
                == true)
        #expect(AudioEngine.assetOptions(prefersPreciseTiming: false).isEmpty)
    }

    @Test func networkAccessAddsTransportFlags() {
        let access = NetworkAccess(policy: .never, treatsExpensiveAsCellular: true)
        let options = AudioEngine.assetOptions(
            prefersPreciseTiming: true, mimeType: "audio/mp4", networkAccess: access)

        #expect(options[AVURLAssetAllowsCellularAccessKey] as? Bool == false)
        #expect(options[AVURLAssetAllowsExpensiveNetworkAccessKey] as? Bool == false)
        #expect(options[AVURLAssetAllowsConstrainedNetworkAccessKey] as? Bool == false)
        #expect(options[AVURLAssetOverrideMIMETypeKey] as? String == "audio/mp4")
        #expect(options[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool == true)

        let always = AudioEngine.assetOptions(
            prefersPreciseTiming: false, networkAccess: NetworkAccess(policy: .always))
        #expect(always[AVURLAssetAllowsCellularAccessKey] as? Bool == true)
        #expect(AudioEngine.assetOptions(prefersPreciseTiming: false, networkAccess: nil).isEmpty)
    }

    @Test func mimeTypeOverridesAssetType() {
        let options = AudioEngine.assetOptions(prefersPreciseTiming: false, mimeType: "audio/mp4")
        #expect(options[AVURLAssetOverrideMIMETypeKey] as? String == "audio/mp4")
        #expect(AudioEngine.assetOptions(prefersPreciseTiming: false, mimeType: nil).isEmpty)
        #expect(AudioEngine.assetOptions(prefersPreciseTiming: false, mimeType: "").isEmpty)
    }

    @Test func loadsExtensionlessURLWithMIMEType() async throws {
        let fixture = try AudioFixture(trackCount: 1)
        let extensionless = fixture.directory.appending(path: "track")
        try FileManager.default.copyItem(at: fixture.urls[0], to: extensionless)
        let engine = makeEngine()

        try await engine.load(
            AudioEngineSource(timeline: fixture.timeline, trackURLs: [extensionless], trackMIMETypes: ["audio/wav"]),
            at: 1)

        #expect(engine.state == .paused)
        #expect(engine.currentTime == 1)
    }
}

extension [AudioEngineEvent] {
    /// The events without periodic ticks, whose number depends on timing.
    var withoutTicks: [AudioEngineEvent] {
        filter {
            if case .tick = $0 { return false }
            return true
        }
    }
}

/// An `AVQueuePlayer` whose `status` can be forced to `.failed`.
final class FailablePlayer: AVQueuePlayer {
    // `status` is nonisolated in AVFoundation; tests only touch this on the main actor.
    nonisolated(unsafe) private var isForcedFailed = false

    override var status: AVPlayer.Status { isForcedFailed ? .failed : super.status }

    func forceFailure() {
        willChangeValue(forKey: "status")
        isForcedFailed = true
        didChangeValue(forKey: "status")
    }
}

/// Creates ``FailablePlayer``s for the engine and keeps them.
@MainActor
final class FailablePlayers {
    private(set) var created: [FailablePlayer] = []

    func make() -> AVQueuePlayer {
        let player = FailablePlayer()
        created.append(player)
        return player
    }
}

/// An error log fetch that waits until the test releases it.
@MainActor
final class GatedErrorLog {
    private(set) var fetches = 0
    private var waiters: [CheckedContinuation<[PlaybackFailure.ErrorLogEntry], Never>] = []
    var pending: Int { waiters.count }

    func fetch(_ item: AVPlayerItem) async -> [PlaybackFailure.ErrorLogEntry] {
        fetches += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ entries: [PlaybackFailure.ErrorLogEntry]) {
        let released = waiters
        waiters = []
        for waiter in released { waiter.resume(returning: entries) }
    }
}
