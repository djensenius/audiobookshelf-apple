import ABSCore
import AVFoundation
import Foundation
import Testing

@testable import ABSPlayback

/// Plays real (silent, muted) 3-second WAV tracks. Serialized to keep real-time waits short and
/// predictable; each test waits well under a second of media time.
@MainActor
@Suite(.serialized)
struct AudioEngineTests {
    private func makeEngine(session: FakeAudioSession? = nil) -> AudioEngine {
        let engine = AudioEngine(audioSession: session, timeObserverInterval: 0.05)
        engine.player.isMuted = true
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
            guard case .itemFailed(trackIndex: 0, _) = error as? AudioEngineError else { return false }
            return true
        }
        guard case .failed = engine.state else {
            Issue.record("Expected failed state, got \(engine.state)")
            return
        }
        #expect(events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func playAdvancesTimeAndPauseStops() async throws {
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

    @Test func seekWhilePlayingKeepsPlaying() async throws {
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
        while engine.pendingSeekTarget != 4 { await Task.yield() }
        let second = await engine.seek(to: 7)

        #expect(await first.value == .superseded)
        #expect(second == .completed)
        #expect(engine.currentTime == 7)
        #expect(engine.currentTrackIndex == 2)
        #expect(engine.pendingSeekTarget == nil)
    }

    @Test func defaultRateAppliesOnPlayAndAcrossTracks() async throws {
        let fixture = try AudioFixture()
        let engine = makeEngine()
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

        engine.setRate(1.5)
        #expect(engine.player.rate == 1.5)
    }

    @Test func endOfMediaEndsPlayback() async throws {
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

    @Test func skipsNonPlayableTracks() async throws {
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

    @Test func interruptionPausesAndResumesAtDefaultRate() async throws {
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

    @Test func preciseTimingFollowsSetting() {
        #expect(
            AudioEngine.assetOptions(prefersPreciseTiming: true)[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool
                == true)
        #expect(AudioEngine.assetOptions(prefersPreciseTiming: false).isEmpty)
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
