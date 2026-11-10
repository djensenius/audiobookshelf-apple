import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Where a new session starts when the local row, the last-played record and the server's progress
/// disagree: each candidate is dated by when its position was saved, and the newest wins.
@MainActor
struct PlaybackCoordinatorProgressSourceTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
    }

    /// A clean row whose last audio edit is `editedAgo` seconds old, with the server's progress merged in since.
    private func rowMergedFromServer(
        _ itemID: String, editedAgo: TimeInterval, mergedTime: Double, mergedAgo: TimeInterval
    ) async throws {
        let key = h.key(itemID)
        try await h.setLocalProgress(itemID, time: 100, updated: h.clock.ago(editedAgo))
        let patch = try #require(try await h.progressStore.beginSend(for: key, now: h.clock.ago(editedAgo)))
        try await h.progressStore.completeSend(patch, serverLastUpdate: h.clock.ago(editedAgo))
        let server = ProgressBaseline(
            currentTime: mergedTime, progress: mergedTime / 3600, duration: 3600, isFinished: false,
            lastUpdate: h.clock.ago(mergedAgo))
        let captured = await h.progressStore.captureGeneration()
        let merged = try await h.progressStore.applyServerProgress([key: server], capturedAt: captured, source: .fetch)
        #expect(merged == [key])
        #expect(try await h.progressStore.progress(for: key)?.currentTime == mergedTime)
    }

    // MARK: - Local row

    @Test func rowMergedFromTheServerIsDatedByTheMergeNotItsOldEdit() async throws {
        try await rowMergedFromServer("A", editedAgo: 3 * 3600, mergedTime: 800, mergedAgo: 3600)
        h.lastPlayed.record = h.record("A", position: 600, age: 2 * 3600)

        await coordinator.play(itemID: "A")

        // 800 was saved an hour ago, after the record: it wins, rewound 30 s.
        #expect(engine.loads.map(\.time) == [770])
    }

    @Test func finishedEditNewerThanTheAudioPositionRestartsFromZero() async throws {
        h.setServerProgress("A", time: 800, updated: h.clock.ago(3600))
        try await h.setLocalProgress("A", time: 500, updated: h.clock.ago(3 * 3600))
        try await h.progressStore.recordEdit(ProgressEdit(isFinished: true), for: h.key("A"), now: h.clock.ago(120))

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [0])
    }

    @Test func unfinishEditNewerThanTheAudioPositionBeatsOlderServerCompletion() async throws {
        h.setServerProgress("A", time: 3600, updated: h.clock.ago(3600), finished: true)
        try await h.setLocalProgress("A", time: 500, updated: h.clock.ago(3 * 3600))
        try await h.progressStore.recordEdit(ProgressEdit(isFinished: false), for: h.key("A"), now: h.clock.ago(120))

        await coordinator.play(itemID: "A")

        // The un-finish is the newest save, so 500 is resumed (2 min on: back 10 s).
        #expect(engine.loads.map(\.time) == [490])
    }

    @Test(arguments: [false, true])
    func ebookOnlyRowOffersNoAudioPosition(serverHasARow: Bool) async throws {
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        // What the server holds for media with only an ebook position: its audio fields are 0.
        let server = ProgressBaseline(
            currentTime: 0, progress: 0, duration: 0, isFinished: false, ebookLocation: "epubcfi(/6/2)",
            ebookProgress: 0.5, lastUpdate: h.clock.ago(300))
        try await h.progressStore.recordEdit(
            ProgressEdit(ebook: .init(location: "epubcfi(/6/2)", progress: 0.5)), for: h.key("A"),
            serverProgress: serverHasARow ? server : nil, now: h.clock.ago(60))

        await coordinator.play(itemID: "A")

        // The row's default position of 0 is not a saved position, however recent: the record wins.
        #expect(engine.loads.map(\.time) == [570])
    }

    // MARK: - Server progress

    @Test func fetchedProgressSuppliesItsOwnPositionNotTheSessions() async throws {
        h.settings.disableAutoRewind = true
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        h.setServerProgress("A", time: 800, updated: h.clock.ago(60))
        // `/play` captured an older position than the progress fetched alongside it.
        service.state.withLock { $0.serverTime["A"] = 300 }

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [800])
    }

    @Test func sessionPositionIsUsedWhenThereIsNoFetchedProgress() async {
        service.state.withLock { $0.serverTime["A"] = 300 }

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [300])
    }

    @Test func sessionPositionWithoutFetchedProgressLosesToADatedRecord() async {
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        service.state.withLock { $0.serverTime["A"] = 300 }

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [570])
    }

    // MARK: - Ties

    @Test func serverProgressWinsATieWithLocalProgress() async throws {
        h.settings.disableAutoRewind = true
        let saved = h.clock.ago(3600)
        try await h.setLocalProgress("A", time: 500, updated: saved)
        h.setServerProgress("A", time: 800, updated: saved)

        await coordinator.play(itemID: "A")

        // As in `ProgressSyncState`'s merge, equal dates favour the server.
        #expect(engine.loads.map(\.time) == [800])
    }
}
