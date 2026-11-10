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
}
