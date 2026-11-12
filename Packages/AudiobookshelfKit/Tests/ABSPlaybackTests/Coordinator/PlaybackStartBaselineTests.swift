import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

private final class StartBaselineProbe: LocalProgressReading {
    let store: LocalProgressStore
    let failRead: Bool
    let holdIntake: Bool
    let entered = Gate()
    let release = Gate()
    let submissions = Mutex(0)

    init(store: LocalProgressStore, failRead: Bool = false, holdIntake: Bool = false) {
        self.store = store
        self.failRead = failRead
        self.holdIntake = holdIntake
    }

    func captureStartProgress(for key: MediaKey) async throws -> PlaybackStartProgressCapture {
        try await store.captureStartProgress(for: key)
    }

    func progress(for key: MediaKey) async throws -> LocalMediaProgressDTO? {
        if failRead { throw CocoaError(.fileReadNoPermission) }
        return try await store.progress(for: key)
    }

    func applyStartProgressChange(
        _ progress: MediaProgress, captured: PlaybackStartProgressCapture
    ) async throws -> ServerAudioPositionChange? {
        submissions.withLock { $0 += 1 }
        entered.open()
        if holdIntake { await release.wait() }
        return try await store.applyStartProgressChange(progress, captured: captured)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackStartBaselineTests {
    private func reply(_ h: CoordinatorHarness, episode: String? = nil, finished: Bool = false) -> MediaProgress {
        MediaProgress(
            id: "p-a", libraryItemId: "a", episodeId: episode, duration: 3600, progress: 0.25,
            currentTime: 900, isFinished: finished, ebookLocation: "server-page", ebookProgress: 0.4,
            lastUpdate: Int(h.clock.ago(60).timeIntervalSince1970 * 1000),
            startedAt: Int(h.clock.ago(600).timeIntervalSince1970 * 1000),
            finishedAt: finished ? Int(h.clock.ago(60).timeIntervalSince1970 * 1000) : nil)
    }

    private func expectOnlyStartTransport(_ h: CoordinatorHarness, key: MediaKey) {
        #expect(h.service.starts == ["a"])
        #expect(h.service.state.withLock { $0.progressReads } == [key])
        #expect(h.service.closes.isEmpty)
    }

    @Test(arguments: [false, true])
    func canonicalStartPersistsAllGroupsCleanlyAcrossReopen(finished: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.store")
        let connection = UUID()
        let key = MediaKey(serverConnectionID: connection, libraryItemId: "a", episodeId: "episode")
        let saved: LocalMediaProgressDTO
        do {
            let store = try LocalProgressStore(modelContainer: DataStack(location: .url(url)).container)
            let h = try CoordinatorHarness(progressStore: store, connectionID: connection)
            let response = reply(h, episode: "episode", finished: finished)
            h.service.state.withLock { $0.progress["a"] = response }
            let service = StubProgressSyncService(serverConnectionID: connection)
            let syncer = ProgressSyncer(source: h.coordinator, service: service, store: store)
            defer { syncer.detach() }
            await h.coordinator.play(itemID: "a", episodeID: "episode")
            await syncer.waitForIdle()
            #expect(h.coordinator.phase == .loaded)
            #expect(h.engine.loads.map(\.time) == [finished ? 0 : 890], "Resume rewinds, canonical storage does not")
            saved = try #require(try await store.progress(for: key))
            #expect(saved.currentTime == 900 && saved.duration == 3600 && saved.progress == 0.25)
            #expect(saved.isFinished == finished)
            #expect(saved.finishedAt == response.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
            #expect(saved.ebookLocation == "server-page" && saved.ebookProgress == 0.4)
            #expect(saved.serverBaseline?.lastUpdate == h.clock.ago(60))
            #expect(saved.dirtyGroups.isEmpty && !saved.needsServerSync)
            #expect(saved.audioEditedAt == nil && saved.finishedEditedAt == nil && saved.ebookEditedAt == nil)
            #expect(saved.unacknowledgedSends.isEmpty)
            #expect(await store.needsConfirmationFetch.isEmpty)
            #expect(service.log.isEmpty, "Baseline intake adds no sync, PATCH or confirmation GET")
            expectOnlyStartTransport(h, key: key)
        }
        let reopened = try LocalProgressStore(modelContainer: DataStack(location: .url(url)).container)
        #expect(try await reopened.progress(for: key) == saved)
        #expect(try await reopened.pendingSync(for: connection).isEmpty)
    }

    @Test(arguments: ["nil", "404", "undated", "item", "episode"])
    func unusableReplyNeverSeedsAndPreservesResumeFallback(kind: String) async throws {
        let h = try CoordinatorHarness()
        var response = reply(h)
        if kind == "undated" { response.lastUpdate = nil }
        if kind == "item" { response.libraryItemId = "wrong" }
        if kind == "episode" { response.episodeId = "wrong" }
        h.service.state.withLock {
            $0.serverTime["a"] = 300
            $0.progress["a"] = kind == "nil" || kind == "404" ? nil : response
            if kind == "404" { $0.progressError = .notFound }
        }
        h.lastPlayed.record = h.record("a", position: 600, age: 30)
        await h.coordinator.play(itemID: "a")
        #expect(h.engine.loads.map(\.time) == [597], "Thirty seconds paused rewinds three seconds")
        #expect(try await h.progressStore.progress(for: h.key("a")) == nil)
        #expect(await h.progressStore.needsConfirmationFetch.isEmpty)
        expectOnlyStartTransport(h, key: h.key("a"))
    }

    @Test(arguments: ["capture", "read", "save"], [false, true])
    func persistenceFailureDoesNotBlockPlaybackOrManufactureBaseline(failure: String, existing: Bool) async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let probe = StartBaselineProbe(store: store, failRead: failure == "read")
        let h = try CoordinatorHarness(progressStore: store, progressReader: probe)
        h.settings.disableAutoRewind = true
        h.service.state.withLock { $0.progress["a"] = reply(h) }
        if existing { try await h.setLocalProgress("a", time: 200, updated: h.clock.ago(120)) }
        let before = try await store.progress(for: h.key("a"))
        if failure == "capture" { await store.failNextRowFetch(with: CocoaError(.fileReadNoPermission)) }
        if failure == "save" { await store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }
        await h.coordinator.play(itemID: "a")
        #expect(h.coordinator.phase == .loaded && h.coordinator.isPlaying)
        #expect(h.engine.loads.map(\.time) == [900])
        #expect(try await store.progress(for: h.key("a")) == before)
        #expect(await store.needsConfirmationFetch.isEmpty)
        #expect(probe.submissions.withLock { $0 } == (failure == "save" ? 1 : 0))
        expectOnlyStartTransport(h, key: h.key("a"))
    }

    /// Model read snapshots at application, then holds delivery while the local writer mutates.
    private func holdingGET(_ h: CoordinatorHarness, body: () async throws -> Void) async throws {
        let model = ReconciliationSessionModel(clock: h.clock)
        let client = SessionModelClient(model: model)
        let seed = try await model.start(client, itemID: "a", episodeID: nil)
        try await model.close(client, id: seed.id, report: .init(currentTime: 900, timeListened: 0, duration: 3600))
        h.service.state.withLock { $0.sessionClient = client }
        let request = ReconciliationSessionModel.Request()
        request.enter.open()
        request.apply.open()
        await model.enqueue(request, for: .progress)
        let task = Task { await h.coordinator.play(itemID: "a") }
        await request.applicationFinished.wait()
        do {
            try await body()
        } catch {
            request.release()
            await task.value
            throw error
        }
        request.release()
        await task.value
    }

    @Test(arguments: ["edit", "ack", "delete", "replace", "missingABA"])
    func heldGETCannotOverwriteInterveningLocalHistory(kind: String) async throws {
        let h = try CoordinatorHarness()
        if kind != "missingABA" { try await h.setLocalProgress("a", time: 200, updated: h.clock.ago(120)) }
        let patch = kind == "ack" ? try await h.progressStore.beginSend(for: h.key("a")) : nil
        var before: LocalMediaProgressDTO?
        try await holdingGET(h) {
            switch kind {
            case "ack":
                try await h.progressStore.completeSend(try #require(patch), serverLastUpdate: nil)
            case "delete", "replace", "missingABA":
                if kind == "missingABA" { try await h.setLocalProgress("a", time: 200, updated: h.clock.ago(120)) }
                try await h.progressStore.deleteProgress(for: h.key("a"))
                if kind == "replace" { try await h.setLocalProgress("a", time: 300, updated: h.clock.ago(120)) }
            default:
                // Deliberately older than the held server date: timestamp ordering cannot save us.
                try await h.setLocalProgress("a", time: 300, updated: h.clock.ago(60))
            }
            before = try await h.progressStore.progress(for: h.key("a"))
        }
        #expect(h.coordinator.phase == .loaded)
        #expect(try await h.progressStore.progress(for: h.key("a")) == before)
        #expect(await h.progressStore.captureProgressFetch(for: h.key("a")).acknowledgement == patch?.token)
        expectOnlyStartTransport(h, key: h.key("a"))
    }

    @Test(arguments: ["stop", "cancel", "supersede"])
    func invalidatedStartSubmitsNoNewIntake(kind: String) async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let probe = StartBaselineProbe(store: store)
        let h = try CoordinatorHarness(progressStore: store, progressReader: probe)
        h.service.state.withLock { $0.progress["a"] = reply(h) }
        let load = Gate()
        h.engine.loadGates = [load]
        let task = Task { await h.coordinator.play(itemID: "a") }
        await yieldUntil { !h.engine.loads.isEmpty }
        if kind == "cancel" {
            task.cancel()
        } else if kind == "supersede" {
            await h.coordinator.play(itemID: "b")
        } else {
            h.coordinator.stop()
        }
        load.open()
        await task.value
        await h.coordinator.waitForPendingCloses()
        #expect(probe.submissions.withLock { $0 } == 0)
        #expect(try await store.progress(for: h.key("a")) == nil)
    }

    @Test(arguments: [false, true])
    func submittedIntakeIsNotRetroactivelyCancelledButStillChecksProvenance(editAfterSubmission: Bool) async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let probe = StartBaselineProbe(store: store, holdIntake: true)
        let h = try CoordinatorHarness(progressStore: store, progressReader: probe)
        h.service.state.withLock { $0.progress["a"] = reply(h) }
        let task = Task { await h.coordinator.play(itemID: "a") }
        await probe.entered.wait()
        h.coordinator.stop()
        do {
            if editAfterSubmission { try await h.setLocalProgress("a", time: 200, updated: h.clock.ago(120)) }
        } catch {
            probe.release.open()
            await task.value
            throw error
        }
        probe.release.open()
        await task.value
        await h.coordinator.waitForPendingCloses()
        #expect(probe.submissions.withLock { $0 } == 1)
        let row = try #require(try await store.progress(for: h.key("a")))
        #expect(row.currentTime == (editAfterSubmission ? 200 : 900))
        #expect(row.audioDirty == editAfterSubmission)
        #expect(h.coordinator.phase == .idle)
    }

    @Test(arguments: ["play", "resolve", "load"])
    func failedStartNeverSubmitsIntake(stage: String) async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let probe = StartBaselineProbe(store: store)
        let h = try CoordinatorHarness(progressStore: store, progressReader: probe)
        h.service.state.withLock {
            $0.progress["a"] = reply(h)
            if stage == "play" { $0.startError = .notFound }
            if stage == "resolve" { $0.resolveError = StreamResolutionError.missingAccessToken }
        }
        if stage == "load" { h.engine.loadError = .audioSessionActivationFailed(description: "fixture") }
        await h.coordinator.play(itemID: "a")
        await h.coordinator.waitForPendingCloses()
        #expect(probe.submissions.withLock { $0 } == 0)
        #expect(try await store.progress(for: h.key("a")) == nil)
        #expect(h.coordinator.error != nil)
    }

    @Test func ebookOnlyBaselineDoesNotBecomeAPreexistingLocalCandidate() async throws {
        let h = try CoordinatorHarness()
        var response = reply(h)
        response.currentTime = 0
        response.duration = 0
        response.progress = 0
        h.service.state.withLock {
            $0.progress["a"] = response
            $0.serverTime["a"] = 300
        }
        h.lastPlayed.record = h.record("a", position: 600, age: 3600)
        await h.coordinator.play(itemID: "a")
        #expect(h.engine.loads.map(\.time) == [570])
        let row = try #require(try await h.progressStore.progress(for: h.key("a")))
        #expect(row.currentTime == 0 && row.ebookLocation == "server-page")
        #expect(row.audioSavedAt == nil && row.dirtyGroups.isEmpty)
        expectOnlyStartTransport(h, key: h.key("a"))
    }
}
