import ABSCore
import Foundation
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``DownloadManager``'s pause, resume, retry, restart and cancel, against a fake engine (and
/// the real one for resume data): the shared podcast cover is handed over, and a cancel can't
/// undo a download the engine is finalising.
@Suite(.timeLimit(.minutes(1))) struct DownloadManagerControlTests {
    @Test func pauseResumeAndRetryPassThroughToTheEngine() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let record = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        let events = await manager.events()

        #expect(try await manager.pause(recordID: record.id))
        let paused = try #require(try await fixture.store.record(id: record.id))
        #expect(paused.state == .paused)
        #expect(await events.next { _ in true } == .recordChanged(paused))
        #expect(try await manager.resume(recordID: record.id))
        let resumed = try #require(try await fixture.store.record(id: record.id))
        #expect(resumed.state == .queued)
        #expect(await events.next { _ in true } == .recordChanged(resumed))
        try await fixture.store.setState(.failed, forRecord: record.id)
        #expect(try await manager.retry(recordID: record.id))

        #expect(await fixture.engine.calls == [.pause(record.id), .resume(record.id), .resume(record.id)])
        let retried = try #require(try await fixture.store.record(id: record.id))
        #expect(retried.state == .queued)
        #expect(await events.next { _ in true } == .recordChanged(retried))
        #expect(try await manager.pause(recordID: UUID()) == false)
    }

    /// Only a paused or failed record is resumed or retried. The engine would queue a
    /// downloading one while its transfers run on, so a restart for a stricter network policy
    /// would skip them.
    @Test func resumeAndRetryLeaveARunningRecordToTheRestart() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let queued = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        let downloading = try await enqueue(LibraryItemFixtures.podcast(), episodeID: "ep_1", fixture, manager)
        try await fixture.store.setState(.downloading, forRecord: downloading.id)

        for record in [queued, downloading] {
            #expect(try await manager.resume(recordID: record.id) == false)
            #expect(try await manager.retry(recordID: record.id) == false)
        }
        try await manager.restartActiveTransfers()

        #expect(await fixture.engine.calls == [.pause(downloading.id), .resume(downloading.id)])
        #expect(try await fixture.store.record(id: queued.id)?.state == .queued)
    }

    @Test func restartActiveTransfersPausesThenResumesDownloadingRecords() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let book = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        let episode = try await enqueue(LibraryItemFixtures.podcast(), episodeID: "ep_1", fixture, manager)
        try await fixture.store.setState(.downloading, forRecord: book.id)

        try await manager.restartActiveTransfers()

        #expect(await fixture.engine.calls == [.pause(book.id), .resume(book.id)])
        #expect(try await fixture.store.record(id: book.id)?.state == .queued)
        #expect(try await fixture.store.record(id: episode.id)?.state == .queued)
    }

    /// On a cold launch the engine has no session yet, so a pause can't stop a transfer that
    /// survived; the restart reattaches first, so the pause stops it and the resume starts anew.
    @Test func restartStopsATransferThatSurvivedARelaunch() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let book = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        try await fixture.store.setState(.downloading, forRecord: book.id)
        await fixture.engine.survive(book.id)

        try await manager.restartActiveTransfers()

        #expect(await fixture.engine.attaches == 1)
        #expect(await fixture.engine.calls == [.pause(book.id), .resume(book.id)])
        #expect(await fixture.engine.runningSurvivors.isEmpty)
    }

    /// Without a session nothing is restarted, and the caller learns it, so it can try again.
    @Test func restartFailsWithoutASession() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let book = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        try await fixture.store.setState(.downloading, forRecord: book.id)
        await fixture.engine.makeSessionUnavailable()

        await #expect(throws: DownloadManagerError.storeFailure) { try await manager.restartActiveTransfers() }

        #expect(await fixture.engine.calls.isEmpty)
        #expect(try await fixture.store.record(id: book.id)?.state == .downloading)
    }

    /// A resume that fails twice leaves its record queued, not paused as if by the user; the
    /// other record still restarts, and the failure is thrown at the end.
    @Test func restartQueuesARecordItCouldNotResumeAndGoesOn() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let book = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        let episode = try await enqueue(LibraryItemFixtures.podcast(), episodeID: "ep_1", fixture, manager)
        for id in [book.id, episode.id] { try await fixture.store.setState(.downloading, forRecord: id) }
        await fixture.engine.failNextResumes(2)

        await #expect(throws: DownloadManagerError.storeFailure) { try await manager.restartActiveTransfers() }

        let calls = await fixture.engine.calls
        let order = calls.compactMap { if case .pause(let id) = $0 { id } else { nil } }
        try #require(Set(order) == [book.id, episode.id] && order.count == 2)
        #expect(calls == [.pause(order[0]), .resume(order[0]), .resume(order[0]), .pause(order[1]), .resume(order[1])])
        #expect(await fixture.engine.resumed == [order[1]])
        #expect(try await fixture.store.record(id: book.id)?.state == .queued)
        #expect(try await fixture.store.record(id: episode.id)?.state == .queued)
    }

    /// A restart waits for an enqueue of the item, and leaves a record paused meanwhile alone.
    @Test func restartSkipsARecordPausedMeanwhile() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let connectionID = fixture.connectionID
        let first = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        #expect(await fixture.nextCheckpoint() == .capacity)
        try await fixture.store.setState(.downloading, forRecord: first.id)
        fixture.capacity.hold()

        let second = Task { try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: connectionID) }
        #expect(await fixture.nextCheckpoint() == .capacity)
        let restart = Task { try await manager.restartActiveTransfers() }
        let reached = await fixture.nextCheckpoint()
        try await fixture.store.setState(.paused, forRecord: first.id)
        fixture.capacity.release()

        #expect(reached == .waiting(fixture.key(item)))
        try await restart.value
        _ = try await second.value
        #expect(await fixture.engine.calls.isEmpty)
        #expect(try await fixture.store.record(id: first.id)?.state == .paused)
    }

    @Test func cancelRemovesTheRecordAndItsFiles() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let record = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        let paths = record.parts.map(\.destinationRelativePath)
        for path in paths { try write(path, fixture) }
        let events = await manager.events()

        #expect(try await manager.cancel(recordID: record.id))

        #expect(try await fixture.store.record(id: record.id) == nil)
        #expect(await fixture.engine.stopped == [.init(partIDs: record.parts.map(\.id), keepingResumeData: false)])
        #expect(await events.next { _ in true } == .recordRemoved(recordID: record.id))
        #expect(paths.allSatisfy { !exists($0, fixture) })
        #expect(!exists(record.relativeDirectory, fixture))
        // A transfer settling during the cancel can't complete its part, so nothing comes back.
        #expect(try await fixture.store.completePart(partID: record.parts[0].id, finalBytes: 1) == false)
        #expect(try await manager.cancel(recordID: record.id) == false)
    }

    /// The server renamed a file in case only. On a case-insensitive volume the replacement's
    /// `chapter.mp3` is the stored `Chapter.mp3`, so cancelling the replacement keeps it (on a
    /// case-sensitive one, the replacement's own file is kept too, for the sweep).
    @Test func cancellingACaseOnlyRenamedReplacementKeepsTheStoredFile() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        var file = LibraryItemFixtures.BookFile(ino: "101", path: "/audiobooks/Dune/Chapter.mp3", size: 1_000)
        let local = try await fixture.storeDownloaded(LibraryItemFixtures.book(files: [file], ebook: nil))
        let stored = try #require(local.files.first).relativePath
        try write(stored, fixture)
        file.path = "/audiobooks/Dune/chapter.mp3"
        let result = try await manager.enqueue(
            item: LibraryItemFixtures.book(files: [file], ebook: nil), episodeID: nil,
            connectionID: fixture.connectionID, replacingExisting: true)
        guard case .started(let replacementID) = result else { throw UnexpectedResult(result: result) }
        let replacement = try #require(try await fixture.store.record(id: replacementID))
        let renamed = try #require(replacement.parts.first { $0.kind == .audio }).destinationRelativePath
        try #require(renamed != stored && renamed.lowercased() == stored.lowercased())
        try write(renamed, fixture)

        #expect(try await manager.cancel(recordID: replacementID))

        #expect(exists(stored, fixture))
        #expect(exists(renamed, fixture))
    }

    /// Every part completed before the cancel: the engine is finalising the record, so it's
    /// kept, and the download completes.
    @Test func cancelLeavesARecordTheEngineIsFinalising() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        try await manager.start()
        let item = LibraryItemFixtures.book()
        let record = try await enqueue(item, fixture, manager)
        for part in record.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 1) }
        try await fixture.engine.settle(record.id)
        let events = await manager.events()

        #expect(try await manager.cancel(recordID: record.id) == false)
        // Its state is put back, and reported.
        let kept = try #require(try await fixture.store.record(id: record.id))
        #expect(kept.state == record.state)
        #expect(await events.next { _ in true } == .recordChanged(kept))
        try await fixture.engine.finishSettling()

        let next = await events.next {
            switch $0 {
            case .completed, .recordRemoved: true
            default: false
            }
        }
        guard case .completed(record.id, _, let key) = next else {
            Issue.record("Unexpected \(String(describing: next))")
            return
        }
        #expect(key == fixture.key(item))
    }

    /// A refresh that read a record before a cancel deleted it reads again: nothing about the
    /// record is reported after its removal, and it isn't tracked again.
    @Test func aRefreshOverlappingACancelReportsNothingAfterTheRemoval() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        try await manager.start()
        let record = try await enqueue(LibraryItemFixtures.book(), fixture, manager)
        let other = try await enqueue(LibraryItemFixtures.podcast(), episodeID: "ep_1", fixture, manager)
        let events = await manager.events()
        fixture.holdRecordRead()

        fixture.engine.updateContinuation.yield(.partCompleted(partID: record.parts[0].id, recordID: record.id))
        #expect(await fixture.checkpoints.first { $0 == .recordRead(record.id) } != nil)
        #expect(try await manager.cancel(recordID: record.id))
        fixture.releaseRecordRead()
        fixture.engine.updateContinuation.yield(.partCompleted(partID: other.parts[0].id, recordID: other.id))

        #expect(await events.next { _ in true } == .recordRemoved(recordID: record.id))
        #expect(await events.next { _ in true } == .recordChanged(other))
    }

    /// Episode 2 was planned without a cover because episode 1's was on its way; cancelling
    /// episode 1 gives episode 2 a cover part, and starts it.
    @Test func cancellingTheCoverHolderHandsTheCoverOver() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let first = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        let second = try await enqueue(item, episodeID: "ep_2", fixture, manager)
        let cover = try #require(first.parts.last)
        try #require(cover.kind == .cover && !second.parts.contains { $0.kind == .cover })
        try write(first.parts[0].destinationRelativePath, fixture)
        let events = await manager.events()

        #expect(try await manager.cancel(recordID: first.id))

        let updated = try #require(try await fixture.store.record(id: second.id))
        let handed = try #require(updated.parts.last)
        #expect(updated.parts.dropLast() == second.parts[...])
        #expect(handed.kind == .cover)
        #expect(handed.id != cover.id)
        #expect(handed.serverPath == cover.serverPath)
        #expect(handed.destinationRelativePath == cover.destinationRelativePath)
        #expect(handed.state == .queued)
        #expect(updated.media.coverUpdatedAt == first.media.coverUpdatedAt)
        #expect(await fixture.engine.started.last == [handed.id])
        #expect(await events.next { _ in true } == .recordRemoved(recordID: first.id))
        #expect(await events.next { _ in true } == .recordChanged(updated))
        #expect(!exists(first.parts[0].destinationRelativePath, fixture))
    }

    /// A fetched cover goes over as it is, completed, and its file stays.
    @Test func aFetchedCoverIsHandedOverCompleted() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let first = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        let second = try await enqueue(item, episodeID: "ep_2", fixture, manager)
        let cover = try #require(first.parts.last)
        try write(cover.destinationRelativePath, fixture)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)

        #expect(try await manager.cancel(recordID: first.id))

        let handed = try #require(try await fixture.store.record(id: second.id)?.parts.last)
        #expect(handed.kind == .cover)
        #expect(handed.state == .completed)
        #expect(handed.bytesWritten == 5)
        #expect(exists(cover.destinationRelativePath, fixture))
        #expect(await fixture.engine.started.count == 2)
    }

    /// A cancelled episode's cover part isn't handed over, nor its file removed, while the
    /// local item has the cover.
    @Test func cancelKeepsACoverTheLocalItemUses() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let first = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_2")
        let coverPath = try #require(local.coverRelativePath)
        try write(coverPath, fixture)

        #expect(try await manager.cancel(recordID: first.id))

        #expect(exists(coverPath, fixture))
        #expect(try await fixture.store.allRecords().isEmpty)
    }

    /// A cancel waits for an enqueue of the same item: the episode it was planning without a
    /// cover is saved before the cancel looks for a record to hand the cover to.
    @Test func cancelWaitsForAnEnqueueOfTheSameItem() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let connectionID = fixture.connectionID
        let first = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        #expect(await fixture.nextCheckpoint() == .capacity)
        fixture.capacity.hold()

        let second = Task { try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: connectionID) }
        #expect(await fixture.nextCheckpoint() == .capacity)
        let cancel = Task { try await manager.cancel(recordID: first.id) }
        let reached = await fixture.nextCheckpoint()
        fixture.capacity.release()

        #expect(reached == .waiting(fixture.key(item)))
        #expect(try await cancel.value)
        guard case .started(let secondID) = try await second.value else {
            Issue.record("Not started")
            return
        }
        let record = try #require(try await fixture.store.record(id: secondID))
        #expect(record.parts.map(\.kind) == [.audio, .cover])
    }

    @Test func linksProgressWhenARecordCompletes() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        try await manager.start()
        let events = await manager.events()
        let item = LibraryItemFixtures.podcast()
        let record = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        let itemID = try await fixture.storeDownloaded(item, episodeID: "ep_1").id

        fixture.engine.updateContinuation.yield(.recordComplete(recordID: record.id, itemID: itemID))

        let completed = await events.next {
            if case .completed = $0 { true } else { false }
        }
        #expect(completed == .completed(recordID: record.id, itemID: itemID, key: record.key))
        #expect(linker.calls == [.link(record.key, itemID)])
    }

    /// The local item was deleted while the engine finalised the record: the completion is
    /// reported as a removal, and the deleted item isn't linked.
    @Test func aRecordCompletingIntoADeletedItemIsRemoved() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        try await manager.start()
        let item = LibraryItemFixtures.podcast()
        let record = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_1")
        try await fixture.store.deleteRecord(record.id)
        #expect(try await manager.deleteLocalItem(id: local.id))
        let events = await manager.events()

        fixture.engine.updateContinuation.yield(.recordComplete(recordID: record.id, itemID: local.id))

        #expect(await events.next { _ in true } == .recordRemoved(recordID: record.id))
        #expect(linker.calls == [.detachItem(local.id)])
    }

    /// The episode was deleted before its completion was handled, and another episode keeps
    /// the item: the completion is reported as a removal, and the episode isn't linked.
    @Test func aRecordCompletingIntoADeletedEpisodeIsRemoved() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        try await manager.start()
        let item = LibraryItemFixtures.podcast()
        let record = try await enqueue(item, episodeID: "ep_2", fixture, manager)
        try await fixture.storeDownloaded(item, episodeID: "ep_1")
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_2")
        try await fixture.store.deleteRecord(record.id)
        #expect(try await manager.deleteEpisode(itemID: local.id, episodeId: "ep_2"))
        let events = await manager.events()

        fixture.engine.updateContinuation.yield(.recordComplete(recordID: record.id, itemID: local.id))

        #expect(await events.next { _ in true } == .recordRemoved(recordID: record.id))
        #expect(linker.calls == [.detachKey(record.key)])
    }

    /// A completion waits while an enqueue, control or deletion of its item runs.
    @Test func aCompletionWaitsForItsItem() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        try await manager.start()
        #expect(await fixture.nextCheckpoint() == .trackingRecords)
        let item = LibraryItemFixtures.podcast()
        let connectionID = fixture.connectionID
        let record = try await enqueue(item, episodeID: "ep_1", fixture, manager)
        #expect(await fixture.nextCheckpoint() == .capacity)
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_1")
        fixture.capacity.hold()
        let second = Task { try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: connectionID) }
        #expect(await fixture.nextCheckpoint() == .capacity)
        let events = await manager.events()

        fixture.engine.updateContinuation.yield(.recordComplete(recordID: record.id, itemID: local.id))
        let reached = await fixture.nextCheckpoint()
        fixture.capacity.release()

        #expect(reached == .waiting(fixture.key(item)))
        _ = try await second.value
        let completed = await events.next { if case .completed = $0 { true } else { false } }
        #expect(completed == .completed(recordID: record.id, itemID: local.id, key: record.key))
    }

    /// With the real engine: a completed part's file and a failed part's resume data go.
    @Test func cancelDeletesFilesAndResumeData() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { request in
            request.url?.path().contains("/file/2/") == true
                ? .failure(resumeData: Data("resume".utf8), gate: gate) : .status(200)
        }
        let partIDs = [UUID(), UUID()]
        let record = try await harness.addRecord(parts: partIDs)
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: partIDs)
        #expect(await engine.next { if case .partCompleted(partIDs[0], _) = $0 { true } else { false } } != nil)
        gate.open()
        #expect(await engine.nextPermanentFailure() != nil)
        let blob = harness.vault.fileURL(partID: partIDs[1]).path(percentEncoded: false)
        try #require(harness.fileExists("li_1/1.mp3") && FileManager.default.fileExists(atPath: blob))
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: engine, locations: harness.locations,
            capacity: FakeCapacity(), clock: harness.clock)

        #expect(try await manager.cancel(recordID: record.id))

        #expect(try await harness.store.record(id: record.id) == nil)
        #expect(!harness.fileExists("li_1/1.mp3"))
        #expect(!harness.fileExists("li_1"))
        #expect(!FileManager.default.fileExists(atPath: blob))
    }

    // MARK: - Helpers

    private func enqueue(
        _ item: LibraryItem, episodeID: String? = nil, _ fixture: ManagerFixture, _ manager: DownloadManager
    ) async throws -> DownloadRecordDTO {
        let result = try await manager.enqueue(item: item, episodeID: episodeID, connectionID: fixture.connectionID)
        guard case .started(let id) = result else { throw UnexpectedResult(result: result) }
        return try #require(try await fixture.store.record(id: id))
    }
}

struct UnexpectedResult: Error {
    var result: DownloadManager.EnqueueResult
}

/// Writes a small file at `relativePath` under the fixture's downloads root.
func write(_ relativePath: String, _ fixture: ManagerFixture) throws {
    let url = try fixture.locations.fileURL(forRelativePath: relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("bytes".utf8).write(to: url)
}

func exists(_ relativePath: String, _ fixture: ManagerFixture) -> Bool {
    FileManager.default.fileExists(
        atPath: fixture.locations.downloadsRoot.appending(path: relativePath).path(percentEncoded: false))
}
