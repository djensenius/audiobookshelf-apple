import AVFoundation
import Testing

@testable import ABSPlayback

@MainActor
struct AudioEngineVolumeTests {
    @Test func setVolumeIsClampedAndReachesThePlayer() {
        let engine = AudioEngine()
        #expect(engine.volume == 1)

        engine.setVolume(0.25)
        #expect(engine.volume == 0.25)
        #expect(engine.routingPlayer.volume == 0.25)
        engine.setVolume(.nan)
        #expect(engine.volume == 0.25)
        engine.setVolume(2)
        #expect(engine.routingPlayer.volume == 1)
        engine.setVolume(-1)
        #expect(engine.volume == 0)
        #expect(engine.routingPlayer.volume == 0)
    }

    @Test func aReplacementPlayerGetsTheVolume() async throws {
        let fixture = try AudioFixture()
        let players = FailablePlayers()
        let engine = AudioEngine(audioSession: nil, timeObserverInterval: 0.05, makePlayer: players.make)
        try await engine.load(fixture.source, at: 0)
        engine.setVolume(0.3)

        players.created[0].forceFailure()
        #expect(await eventually { if case .failed(.playerFailed) = engine.state { true } else { false } })
        #expect(await engine.seek(to: 1) == .completed)

        #expect(players.created.count == 2)
        #expect(players.created[1].volume == 0.3)
        engine.setVolume(0.6)
        #expect(players.created[1].volume == 0.6)
        #expect(players.created[0].volume == 0.3)
    }
}
