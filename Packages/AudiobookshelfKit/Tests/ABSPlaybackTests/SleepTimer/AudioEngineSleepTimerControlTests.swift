import AVFoundation
import Testing

@testable import ABSPlayback

@MainActor
struct AudioEngineSleepTimerControlTests {
    @Test func playRewindsThroughTheEngineAndReportsWhereItLanded() async {
        let engine = FakeAudioEngine()
        engine.timeline = TimelineFixture.crossingChapters.timeline
        engine.currentTime = 500
        engine.state = .playing
        let control = AudioEngineSleepTimerControl(engine: engine)
        #expect(control.isPlaying)
        #expect(await control.play(rewindingBy: 30) == 470)
        #expect(engine.calls == ["seek", "play"])

        engine.seekResult = .superseded
        #expect(await control.play(rewindingBy: 30) == nil)
        #expect(engine.calls == ["seek", "play", "seek"], "Doesn't play where it didn't land")

        control.setVolume(0.25)
        #expect(engine.volume == 0.25)
    }
}

// Nested in `AudioEngineTests` so these run serialized with the other real-engine tests.
extension AudioEngineTests {
    /// A ``SleepTimer`` driving a real ``AudioEngine`` whose player fails and is replaced mid-fade.
    @MainActor
    struct SleepTimerControlTests {
        private let fixture: AudioFixture
        private let players: FailablePlayers
        private let engine: AudioEngine
        private let clock = ManualClock()
        private let timer: SleepTimer

        init() throws {
            fixture = try AudioFixture()
            let players = FailablePlayers()
            self.players = players
            engine = AudioEngine(audioSession: nil, timeObserverInterval: 0.05, makePlayer: players.make)
            engine.player.isMuted = true
            engine.player.sourceClock = CMClockGetHostTimeClock()
            timer = SleepTimer(
                control: AudioEngineSleepTimerControl(engine: engine), feedback: FakeFeedback(), clock: clock,
                calendar: .gregorianUTC, tickInterval: .seconds(1))
        }

        /// Fails the player and seeks, which replaces it (the engine's recovery path).
        private func replacePlayer() async {
            players.created[0].forceFailure()
            #expect(await eventually { if case .failed(.playerFailed) = engine.state { true } else { false } })
            #expect(await engine.seek(to: 1) == .completed)
            #expect(players.created.count == 2)
        }

        @Test func readsTheEngine() {
            let control = AudioEngineSleepTimerControl(engine: engine)
            #expect(control.isPlaying == false)
            #expect(control.currentTime == 0)
            #expect(control.rate == 1)
            #expect(control.timeline == nil)
        }

        @Test func aPlayerReplacedMidFadeGetsTheFadeVolumeAndCancelRestoresIt() async throws {
            try await engine.load(fixture.source, at: 0)
            #expect(timer.start(.duration(30)))
            #expect(players.created[0].volume == 0.5)

            await replacePlayer()
            #expect(players.created[1].volume == 0.5)

            timer.cancel()
            #expect(players.created[1].volume == 1)
            #expect(engine.volume == 1)
        }

        @Test(.tags(.realtimeAudio)) func expiryAfterAReplacementPausesAndRestoresTheCurrentPlayer() async throws {
            try await engine.load(fixture.source, at: 0)
            engine.play()
            #expect(await eventually { engine.state == .playing })
            #expect(timer.start(.duration(3)))

            await replacePlayer()
            engine.play()
            #expect(await eventually { engine.state == .playing })
            #expect(players.created[1].volume == Float(3.0 / SleepTimer.fadeDuration))

            await advanceTicking(clock, timer, seconds: 3)
            #expect(timer.isRunning == false)
            #expect(engine.isPlaybackRequested == false)
            #expect(players.created[1].volume == 1)
        }
    }
}
