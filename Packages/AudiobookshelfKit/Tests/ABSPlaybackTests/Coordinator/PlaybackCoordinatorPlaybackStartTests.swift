import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// `playbackStarted` is for plays the engine accepted: it can refuse one at once, reporting
/// `.failed` as an audio session activation failure does.
@MainActor
struct PlaybackCoordinatorPlaybackStartTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    private let activationFailure = PlaybackCoordinatorError.engine(
        .audioSessionActivationFailed(description: "Session activation failed"))

    init() throws {
        h = try CoordinatorHarness()
    }

    @Test func refusedPlayIsNotAnnouncedAsStarted() async {
        engine.failingPlays = 1

        await coordinator.play(itemID: "A")

        #expect(coordinator.phase == .loaded)
        #expect(!coordinator.isPlaying)
        #expect(coordinator.error == activationFailure)
        #expect(
            h.events.events == [
                .itemChanged(h.key("A")), .sessionStarted(sessionID: "A-1", key: h.key("A")),
                .loaded(time: 0), .didSeek(time: 0), .failed(activationFailure),
            ])

        // Playing again, now accepted, is announced.
        await coordinator.resume()
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
        #expect(h.events.events.last == .playbackStarted)
        #expect(h.events.events.filter { $0 == .playbackStarted }.count == 1)
    }

    @Test func refusedResumeIsNotAnnouncedAsStarted() async {
        await coordinator.play(itemID: "A")
        coordinator.pause()
        engine.failingPlays = 1
        let paused = h.events.count

        await coordinator.resume()

        #expect(!coordinator.isPlaying)
        #expect(coordinator.error == activationFailure)
        #expect(h.events.since(paused) == [.failed(activationFailure)])
    }
}
