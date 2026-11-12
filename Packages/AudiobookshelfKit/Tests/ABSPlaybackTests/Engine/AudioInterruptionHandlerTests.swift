import ABSPlayback
import Observation
import Testing

/// Records the calls ``AudioInterruptionHandler`` makes.
@MainActor
@Observable
final class FakeAudioEngine: AudioEngineProtocol {
    var state: PlaybackState = .paused
    var currentTime: Double = 0
    var duration: Double = 0
    var currentTrackIndex: Int?
    var defaultRate: Float = 1
    var isPlaybackRequested = false
    var wasPlaybackRequestedAtFailure = false
    var pendingSeekTarget: Double?
    var isAudioSessionActive = false
    var timeline: PlaybackTimeline?
    var volume: Float = 1
    var seekResult = SeekResult.completed
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)?
    private(set) var calls: [String] = []

    func load(_ source: AudioEngineSource, at time: Double) async throws(AudioEngineError) { calls.append("load") }
    func play() {
        calls.append("play")
        isPlaybackRequested = true
    }
    func pause() {
        calls.append("pause")
        isPlaybackRequested = false
    }
    func stop() { calls.append("stop") }
    func unload() { calls.append("unload") }
    func seek(to time: Double) async -> SeekResult {
        calls.append("seek")
        if seekResult == .completed { currentTime = time }
        return seekResult
    }
    func setRate(_ rate: Float) { calls.append("setRate") }
    func setVolume(_ volume: Float) { self.volume = volume }
}

@MainActor
struct AudioInterruptionHandlerTests {
    @Test func resumesAfterInterruptionWhenPlaying() {
        let engine = FakeAudioEngine()
        engine.isPlaybackRequested = true
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls == ["pause", "play"])
    }

    @Test func doesNotResumeWithoutRecommendation() {
        let engine = FakeAudioEngine()
        engine.isPlaybackRequested = true
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: false))
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls == ["pause"])
    }

    @Test func doesNotStartPlaybackThatWasPaused() {
        let engine = FakeAudioEngine()
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls.isEmpty)
    }

    @Test func pausesWhenOutputIsUnpluggedAndForgetsResume() {
        let engine = FakeAudioEngine()
        engine.isPlaybackRequested = true
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        handler.handle(.oldDeviceUnavailable)
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls == ["pause"])

        engine.play()
        handler.handle(.oldDeviceUnavailable)
        #expect(engine.calls == ["pause", "play", "pause"])
    }

    @Test func userPlayAndPauseClearLateResume() {
        let engine = FakeAudioEngine()
        engine.isPlaybackRequested = true
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        engine.play()
        handler.userDidChangePlayback()
        engine.pause()
        handler.userDidChangePlayback()
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls == ["pause", "play", "pause"])
        #expect(!engine.isPlaybackRequested)
    }

    @Test func secondBeganKeepsTheResume() {
        let engine = FakeAudioEngine()
        engine.isPlaybackRequested = true
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        handler.handle(.interruptionBegan)
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls == ["pause", "play"])
    }

    @Test func sessionActivationClearsTheResume() {
        let engine = FakeAudioEngine()
        engine.isPlaybackRequested = true
        let handler = AudioInterruptionHandler(engine: engine)

        handler.handle(.interruptionBegan)
        handler.handle(.sessionActivated)
        handler.handle(.interruptionEnded(shouldResume: true))

        #expect(engine.calls == ["pause"])
    }

    @Test func holdsEngineWeakly() {
        var engine: FakeAudioEngine? = FakeAudioEngine()
        let handler = AudioInterruptionHandler(engine: engine)
        engine = nil

        #expect(handler.engine == nil)
        handler.handle(.interruptionBegan)
    }
}
