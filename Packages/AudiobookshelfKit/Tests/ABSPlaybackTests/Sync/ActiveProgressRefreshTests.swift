import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
enum ActiveRefreshFixture {
    static func reply(_ s: SyncHarness, time: Double = 900, finished: Bool = false) -> MediaProgress {
        MediaProgress(
            id: "p-a", libraryItemId: "a", duration: 3600, progress: time / 3600,
            currentTime: time, isFinished: finished, ebookLocation: "server-page", ebookProgress: 0.4,
            lastUpdate: Int(s.h.clock.now.timeIntervalSince1970 * 1000),
            startedAt: Int(s.h.clock.ago(600).timeIntervalSince1970 * 1000),
            finishedAt: finished ? Int(s.h.clock.now.timeIntervalSince1970 * 1000) : nil)
    }

    static func edit(_ time: Double = 200) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600))
    }

    /// Pause while still starting: no loaded-position edit or report is manufactured.
    static func loadPaused(_ s: SyncHarness) async {
        let coordinator = s.coordinator
        let observer = coordinator.addObserver {
            if case .sessionStarted = $0 { coordinator.pause() }
        }
        defer { coordinator.removeObserver(observer) }
        await coordinator.play(itemID: "a")
        await s.settle()
        #expect(coordinator.phase == .loaded && !coordinator.isPlaying)
    }

    /// Always release and join this drain, even when the body throws.
    static func holdingGET(_ s: SyncHarness, body: () async throws -> Void) async throws {
        let started = Gate()
        let response = Gate()
        s.service.state.withLock {
            $0.fetchStarted = started
            $0.fetchGates = [response]
        }
        let task = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        do {
            try await body()
        } catch {
            s.syncer.quiesceTransport()
            response.open()
            await task.value
            throw error
        }
        response.open()
        await task.value
    }

    static func expectNoWrites(_ s: SyncHarness) {
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
        #expect(s.h.service.closes.isEmpty)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ActiveProgressRefreshTests {
    @Test(arguments: [false, true], [false, true])
    func missingOrCleanBaselineRefreshPersistsWithoutWriteTransport(finished: Bool, existing: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.store")
        let connection = UUID()
        let key = MediaKey(serverConnectionID: connection, libraryItemId: "a")
        let saved: LocalMediaProgressDTO
        do {
            let store = try LocalProgressStore(modelContainer: DataStack(location: .url(url)).container)
            let s = try SyncHarness(progressStore: store, connectionID: connection)
            defer { s.syncer.detach() }
            s.h.service.state.withLock {
                if existing {
                    $0.progress["a"] = ActiveRefreshFixture.reply(s, time: 300)
                } else {
                    $0.progressError = .timedOut
                }
            }
            await ActiveRefreshFixture.loadPaused(s)
            #expect(try await store.progress(for: key)?.currentTime == (existing ? 300 : nil))
            #expect(await store.needsConfirmationFetch.isEmpty)
            let lastPlayed = s.h.lastPlayed.record
            let position = s.coordinator.currentTime
            let state = s.h.engine.state
            s.h.clock.advance(by: 60)
            let response = ActiveRefreshFixture.reply(s, finished: finished)
            s.service.state.withLock { $0.serverProgress[key] = response }

            // Deliberately non-gated: the selection-only negative control must fail on state,
            // not hang waiting for a request which was never selected.
            await s.syncer.drainPendingProgress()

            #expect(s.service.state.withLock { $0.fetches } == [key])
            saved = try #require(try await store.progress(for: key))
            #expect(saved.currentTime == 900 && saved.duration == 3600 && saved.progress == 0.25)
            #expect(saved.isFinished == finished)
            #expect(saved.finishedAt == response.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
            #expect(saved.ebookLocation == "server-page" && saved.ebookProgress == 0.4)
            #expect(saved.serverBaseline?.lastUpdate == s.h.clock.now)
            #expect(saved.dirtyGroups.isEmpty && !saved.needsServerSync)
            #expect(saved.audioEditedAt == nil && saved.finishedEditedAt == nil && saved.ebookEditedAt == nil)
            #expect(saved.unacknowledgedSends.isEmpty)
            #expect(await store.needsConfirmationFetch.isEmpty)
            #expect(s.coordinator.currentTime == position && s.h.engine.state == state)
            #expect(s.h.engine.loads.count == 1 && s.h.engine.seeks.isEmpty)
            #expect(s.h.lastPlayed.record == lastPlayed)
            #expect(s.h.service.starts == ["a"] && s.h.service.state.withLock { $0.progressReads } == [key])
            ActiveRefreshFixture.expectNoWrites(s)
        }
        let reopened = try LocalProgressStore(modelContainer: DataStack(location: .url(url)).container)
        #expect(try await reopened.progress(for: key) == saved)
        #expect(try await reopened.pendingSync(for: connection).isEmpty)
    }

    @Test func otherDeviceAdvancesCleanBaselineWithoutChangingLoadedPlayback() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let model = ReconciliationSessionModel(clock: s.h.clock)
        let client = SessionModelClient(model: model)
        let other = SessionModelClient(model: model, deviceID: "other-device")
        let remote = try await model.start(other, itemID: "a", episodeID: nil)
        let initialReport = try #require(PlaybackSyncReport(currentTime: 300, timeListened: 0, duration: 3600))
        try await model.sync(other, id: remote.id, report: initialReport)
        s.h.service.state.withLock { $0.sessionClient = client }
        s.service.state.withLock { $0.sessionClient = client }
        await ActiveRefreshFixture.loadPaused(s)
        #expect(try await s.store.progress(for: key)?.currentTime == 300)
        let lastPlayed = s.h.lastPlayed.record
        let state = s.h.engine.state
        s.h.clock.advance(by: 60)
        let request = ReconciliationSessionModel.Request()
        request.enter.open()
        await model.enqueue(request, for: .progress)
        let drain = Task { await s.syncer.drainPendingProgress() }
        await request.entered.wait()
        do {
            // The read snapshots at application, not entry. Only this other-device report writes.
            let report = try #require(PlaybackSyncReport(currentTime: 900, timeListened: 0, duration: 3600))
            try await model.sync(other, id: remote.id, report: report)
        } catch {
            request.release()
            await drain.value
            throw error
        }
        request.apply.open()
        await request.applicationFinished.wait()
        request.release()
        await drain.value
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 900 && row.dirtyGroups.isEmpty)
        #expect(row.serverBaseline?.lastUpdate == s.h.clock.now)
        #expect(s.coordinator.currentTime == 300 && s.h.engine.state == state)
        #expect(s.h.engine.loads.map(\.time) == [300] && s.h.engine.seeks.isEmpty)
        #expect(s.h.lastPlayed.record == lastPlayed)
        #expect(s.service.state.withLock { $0.fetches } == [key])
        ActiveRefreshFixture.expectNoWrites(s)
    }

    @Test(arguments: ["nil", "404", "undated", "item", "episode"], [false, true])
    func unusableActiveReplyMakesOneAttemptAndLaterDrainRecovers(kind: String, existing: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        if existing {
            s.h.service.state.withLock { $0.progress["a"] = ActiveRefreshFixture.reply(s, time: 200) }
        }
        await ActiveRefreshFixture.loadPaused(s)
        let key = s.h.key("a")
        let before = try await s.store.progress(for: key)
        let valid = ActiveRefreshFixture.reply(s)
        var invalid = valid
        if kind == "undated" { invalid.lastUpdate = nil }
        if kind == "item" { invalid.libraryItemId = "wrong" }
        if kind == "episode" { invalid.episodeId = "wrong" }
        s.service.state.withLock {
            // The production canonical API maps 404 to nil; also tolerate a throwing adapter.
            $0.serverProgress[key] = kind == "nil" || kind == "404" ? nil : invalid
            if kind == "404" { $0.fetchErrors = [.notFound] }
        }
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(try await s.store.progress(for: key) == before)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        s.service.state.withLock { $0.serverProgress[key] = valid }
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key, key])
        #expect(try await s.store.progress(for: key)?.currentTime == 900)
        #expect(try await s.store.pendingSync(for: s.h.connectionID).isEmpty)
        ActiveRefreshFixture.expectNoWrites(s)
    }

    @Test(arguments: ["capture", "read", "GET", "save"], [false, true])
    func failuresPreserveWholeRowAndLaterDrainRecovers(failure: String, existing: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        if existing {
            s.h.service.state.withLock { $0.progress["a"] = ActiveRefreshFixture.reply(s, time: 300) }
        }
        await ActiveRefreshFixture.loadPaused(s)
        let before = try await s.store.progress(for: key)
        s.h.clock.advance(by: 60)
        s.service.state.withLock {
            $0.serverProgress[key] = ActiveRefreshFixture.reply(s, finished: true)
            if failure == "GET" { $0.fetchErrors = [.timedOut] }
        }
        if failure == "capture" {
            s.syncer.beforeActiveProgressCapture = {
                await s.store.failNextRowFetch(with: CocoaError(.fileReadNoPermission))
            }
            await s.syncer.drainPendingProgress()
            s.syncer.beforeActiveProgressCapture = nil
        } else {
            try await ActiveRefreshFixture.holdingGET(s) {
                if failure == "read" { await s.store.failNextRowFetch(with: CocoaError(.fileReadNoPermission)) }
                if failure == "save" { await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }
            }
        }
        #expect(s.service.state.withLock { $0.fetches.count } == (failure == "capture" ? 0 : 1))
        #expect(try await s.store.progress(for: key) == before)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches.count } == (failure == "capture" ? 1 : 2))
        let recovered = try #require(try await s.store.progress(for: key))
        #expect(recovered.currentTime == 900 && recovered.isFinished && recovered.ebookLocation == "server-page")
        #expect(recovered.dirtyGroups.isEmpty && recovered.unacknowledgedSends.isEmpty)
        ActiveRefreshFixture.expectNoWrites(s)
    }

    @Test(arguments: ["prefetch", "confirmation", "newACK"])
    func alreadyReadActiveKeyDoesNotGetAnExtraRead(path: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        await ActiveRefreshFixture.loadPaused(s)
        let key = s.h.key("a")
        try await s.store.recordEdit(ActiveRefreshFixture.edit(), for: key, now: s.h.clock.ago(60))
        if path == "confirmation" {
            let patch = try #require(try await s.store.beginSend(for: key))
            try await s.store.completeSend(patch, serverLastUpdate: nil)
        }
        s.service.state.withLock {
            let canonical = ActiveRefreshFixture.reply(s, time: path == "prefetch" ? 900 : 200)
            $0.fetchReplies = path == "newACK" ? [nil, canonical] : [canonical]
        }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == (path == "newACK" ? ["get a", "patch a", "get a"] : ["get a"]))
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
        #expect(s.service.reports.isEmpty && s.h.service.closes.isEmpty)
    }

    @Test(arguments: [false, true])
    func rejectedPredrainRetriesOnlyAGenuinelyNewACK(newACK: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        await ActiveRefreshFixture.loadPaused(s)
        let key = s.h.key("a")
        try await s.store.recordEdit(ActiveRefreshFixture.edit(), for: key, now: s.h.clock.ago(120))
        let first = try #require(try await s.store.beginSend(for: key))
        try await s.store.completeSend(first, serverLastUpdate: nil)
        try await s.store.recordEdit(ActiveRefreshFixture.edit(300), for: key, now: s.h.clock.ago(60))
        s.service.state.withLock { $0.serverProgress[key] = ActiveRefreshFixture.reply(s) }
        try await ActiveRefreshFixture.holdingGET(s) {
            if newACK {
                let next = try #require(try await s.store.beginSend(for: key))
                try await s.store.completeSend(next, serverLastUpdate: nil)
                s.service.state.withLock { $0.serverProgress[key] = ActiveRefreshFixture.reply(s, time: 300) }
            } else {
                try await s.store.recordEdit(ActiveRefreshFixture.edit(400), for: key, now: s.h.clock.ago(30))
                // A duplicate success Bool is not evidence of another ACK.
                _ = try await s.store.completeSend(first, serverLastUpdate: nil)
            }
        }
        #expect(s.service.state.withLock { $0.fetches } == (newACK ? [key, key] : [key]))
        #expect(await s.store.needsConfirmationFetch == (newACK ? [] : [key]))
        #expect(try await s.store.progress(for: key)?.currentTime == (newACK ? 300 : 400))
        ActiveRefreshFixture.expectNoWrites(s)
    }
}
