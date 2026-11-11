import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// An unsent audio edit against server progress with a newer `lastUpdate`. That date is row-wide,
/// so it shows the audio changed only if its audio fields differ from what the row last saw.
@MainActor
struct PlaybackCoordinatorDirtyAudioTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
        h.settings.disableAutoRewind = true
    }

    /// What the server held when the row last saw it: 100 s, three hours ago.
    private var lastSeen: ProgressBaseline {
        ProgressBaseline(
            currentTime: 100, progress: 100.0 / 3600, duration: 3600, isFinished: false,
            lastUpdate: h.clock.ago(3 * 3600))
    }

    /// The row after that sync, with an unsent edit to 500 s from two hours ago.
    private func rowWithUnsentAudioEdit() async throws {
        try await h.progressStore.recordEdit(
            ProgressEdit(audio: .init(currentTime: 500, duration: 3600, progress: 500.0 / 3600)), for: h.key("A"),
            serverProgress: lastSeen, now: h.clock.ago(2 * 3600))
    }

    /// The row after that sync, with nothing unsent.
    private func cleanRow() async throws {
        try await h.progressStore.recordEdit(
            ProgressEdit(), for: h.key("A"), serverProgress: lastSeen, now: h.clock.ago(3 * 3600))
    }

    @Test(arguments: [false, true])
    func unsentAudioEditBeatsNewerServerRowWithTheSameAudio(finishedElsewhere: Bool) async throws {
        try await rowWithUnsentAudioEdit()
        // Another device changed only the finished flag or the ebook position an hour ago.
        h.setServerProgress("A", time: 100, updated: h.clock.ago(3600), finished: finishedElsewhere)
        if !finishedElsewhere {
            service.state.withLock {
                $0.progress["A"]?.ebookLocation = "epubcfi(/6/2)"
                $0.progress["A"]?.ebookProgress = 0.5
            }
        }

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [500])
    }

    @Test func newerServerAudioStillBeatsAnUnsentEdit() async throws {
        try await rowWithUnsentAudioEdit()
        h.setServerProgress("A", time: 800, updated: h.clock.ago(3600))

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [800])
    }

    @Test func cleanRowLosesToANewerServerRowWithTheSameAudio() async throws {
        try await cleanRow()
        h.setServerProgress("A", time: 100, updated: h.clock.ago(3600), finished: true)

        await coordinator.play(itemID: "A")

        // Nothing unsent to keep: the newer finished flag wins, and a finished item starts over.
        #expect(engine.loads.map(\.time) == [0])
    }
}
