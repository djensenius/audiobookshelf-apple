import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct DownloadStoreTests {
    private let now = Fixtures.date
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2", episodeId: "ep_1")

    /// A store whose container holds a connection for each of `connections`.
    private func makeStore(connections: [UUID] = [Fixtures.connectionID]) throws -> (DownloadStore, ModelContainer) {
        let container = try DataStack(location: .inMemory).container
        let context = ModelContext(container)
        for (index, id) in connections.enumerated() {
            context.insert(Fixtures.connection(id: id, userId: "usr_\(index)"))
        }
        try context.save()
        return (DownloadStore(modelContainer: container), container)
    }

    static func part(
        id: UUID = UUID(), kind: DownloadPartKind = .audio, trackIndex: Int? = 1, filename: String = "ep1.mp3",
        state: DownloadPartState = .queued
    ) -> DownloadPartDTO {
        DownloadPartDTO(
            id: id,
            kind: kind,
            serverPath: "/api/items/li_2/file/13/download",
            filename: filename,
            mimeType: kind == .cover ? "image/jpeg" : "audio/mpeg",
            serverIno: "13",
            trackIndex: trackIndex,
            episodeId: kind == .cover ? nil : "ep_1",
            expectedBytes: 3_000_000_000,
            destinationRelativePath: "li_2/\(filename)",
            state: state
        )
    }

    static func record(
        key: MediaKey, title: String = "Episode 1", parts: [DownloadPartDTO], state: DownloadState = .queued
    ) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: key,
            mediaType: .podcast,
            title: title,
            state: state,
            relativeDirectory: "li_2",
            media: Fixtures.podcastSnapshot,
            parts: parts
        )
    }

    @Test func createsAndReadsRecordWithOrderedParts() async throws {
        let (store, _) = try makeStore()
        let cover = Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")
        let track2 = Self.part(trackIndex: 2, filename: "b.mp3")
        let track1 = Self.part(trackIndex: 1, filename: "a.mp3")
        let created = try await store.upsertRecord(Self.record(key: key, parts: [cover, track2, track1]), now: now)
            .record

        #expect(created.key == key)
        #expect(created.createdAt == now)
        #expect(created.updatedAt == now)
        #expect(created.media == Fixtures.podcastSnapshot)
        #expect(created.parts == [track1, track2, cover])
        #expect(try await store.record(id: created.id) == created)
        #expect(try await store.record(key: key) == created)
        #expect(try await store.part(id: track2.id) == track2)
    }

    @Test func upsertSameKeyKeepsIDAndReconcilesParts() async throws {
        let (store, container) = try makeStore()
        let kept = Self.part(trackIndex: 1, filename: "a.mp3")
        let dropped = Self.part(trackIndex: 2, filename: "b.mp3")
        let first = try await store.upsertRecord(Self.record(key: key, parts: [kept, dropped]), now: now).record

        var keptUpdate = kept
        keptUpdate.bytesWritten = 42
        let added = Self.part(trackIndex: 3, filename: "c.mp3")
        var input = Self.record(key: key, title: "Renamed", parts: [keptUpdate, added], state: .downloading)
        input.id = UUID()
        let later = now.addingTimeInterval(5)
        let result = try await store.upsertRecord(input, now: later)
        let second = result.record

        #expect(second.id == first.id)
        #expect(second.createdAt == now)
        #expect(second.updatedAt == later)
        #expect(second.title == "Renamed")
        #expect(second.state == .downloading)
        #expect(second.parts == [keptUpdate, added])
        // The dropped part is returned so the caller can delete its resume data.
        #expect(result.removedParts == [dropped])
        #expect(try await store.allRecords().count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DownloadPart>()) == 2)
    }

    @Test func queriesByStateConnectionAndCompletion() async throws {
        let otherConnection = UUID()
        let (store, _) = try makeStore(connections: [Fixtures.connectionID, otherConnection])
        let done = try await store.upsertRecord(
            Self.record(key: key, parts: [Self.part(state: .completed)], state: .downloading), now: now
        ).record
        let queued = try await store.upsertRecord(
            Self.record(
                key: MediaKey(serverConnectionID: otherConnection, libraryItemId: "li_3"), parts: [Self.part()]),
            now: now.addingTimeInterval(1)
        ).record
        let empty = try await store.upsertRecord(
            Self.record(key: MediaKey(serverConnectionID: otherConnection, libraryItemId: "li_4"), parts: []),
            now: now.addingTimeInterval(2)
        ).record

        #expect(try await store.allRecords().map(\.id) == [done.id, queued.id, empty.id])
        #expect(try await store.records(state: .downloading).map(\.id) == [done.id])
        #expect(try await store.records(state: .queued).map(\.id) == [queued.id, empty.id])
        #expect(try await store.records(serverConnectionID: otherConnection).map(\.id) == [queued.id, empty.id])
        #expect(try await store.completedRecords().map(\.id) == [done.id])
    }

    @Test func progressUpdatesNeverChangeState() async throws {
        let (store, _) = try makeStore()
        let part = Self.part()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [part]), now: now).record
        let later = now.addingTimeInterval(3)
        #expect(try await store.setPartState(.failed, partID: part.id, taskIdentifier: nil, error: "timed out"))
        #expect(
            try await store.updateProgress(
                partID: part.id, bytesWritten: 20, expectedBytes: 20, now: now.addingTimeInterval(1)))
        #expect(try await store.part(id: part.id)?.state == .failed)
        #expect(try await store.setPartState(.running, partID: part.id, taskIdentifier: 7, hasResumeData: true))
        #expect(try await store.completePart(partID: part.id, finalBytes: 20, now: later))
        // A late, throttled progress write after completion is ignored.
        #expect(
            try await store.updateProgress(
                partID: part.id, bytesWritten: 10, expectedBytes: 20, now: later.addingTimeInterval(1)) == false)

        let updated = try #require(try await store.part(id: part.id))
        #expect(updated.state == .completed)
        #expect(updated.bytesWritten == 20)
        #expect(updated.expectedBytes == 20)
        #expect(updated.retryCount == 1)
        // Completion clears the task and the resume-data flag.
        #expect(!updated.hasResumeData)
        #expect(updated.taskIdentifier == nil)
        #expect(try await store.record(id: created.id)?.updatedAt == later)
        #expect(try await store.completedRecords().map(\.id) == [created.id])
        #expect(try await store.updateProgress(partID: UUID(), bytesWritten: 1, expectedBytes: 1) == false)
    }

    @Test func completedPartIsFinalUnlessRequeued() async throws {
        let (store, _) = try makeStore()
        let part = Self.part()
        _ = try await store.upsertRecord(Self.record(key: key, parts: [part]), now: now)
        #expect(try await store.setPartState(.running, partID: part.id, taskIdentifier: 3))
        #expect(try await store.setPartState(.failed, partID: part.id, taskIdentifier: nil, error: "lost"))
        #expect(try await store.setPartState(.failed, partID: part.id, taskIdentifier: nil, error: "again"))
        var current = try #require(try await store.part(id: part.id))
        #expect(current.retryCount == 1)
        #expect(current.lastError == "again")

        await #expect(throws: DownloadStore.StoreError.completionNeedsFinalBytes) {
            try await store.setPartState(.completed, partID: part.id, taskIdentifier: nil)
        }
        #expect(try await store.completePart(partID: part.id, finalBytes: 100))
        #expect(try await store.setPartState(.running, partID: part.id, taskIdentifier: 4) == false)
        current = try #require(try await store.part(id: part.id))
        #expect(current.state == .completed)
        #expect(current.taskIdentifier == nil)
        #expect(current.lastError == nil)

        #expect(try await store.setPartState(.queued, partID: part.id, taskIdentifier: nil, requeue: true))
        #expect(try await store.part(id: part.id)?.state == .queued)
        #expect(try await store.setPartState(.running, partID: UUID(), taskIdentifier: nil) == false)
        #expect(try await store.completePart(partID: UUID(), finalBytes: 1) == false)
    }

    @Test func beginRunningStartsQueuedAndRetryableParts() async throws {
        let (store, _) = try makeStore()
        var queued = Self.part()
        queued.taskIdentifier = 4
        queued.lastError = "lost"
        queued.hasResumeData = true
        queued.bytesWritten = 20
        var retrying = Self.part(trackIndex: 2, filename: "b.mp3", state: .failed)
        retrying.retryCount = 2
        let created = try await store.upsertRecord(Self.record(key: key, parts: [queued, retrying]), now: now).record
        let later = now.addingTimeInterval(5)

        #expect(try await store.beginRunning(partID: queued.id, expecting: [.queued, .failed], now: later))
        var record = try #require(try await store.record(id: created.id))
        #expect(record.state == .downloading)
        #expect(record.updatedAt == later)
        var expected = queued
        expected.state = .running
        expected.taskIdentifier = nil
        expected.lastError = nil
        #expect(record.parts.first == expected)

        #expect(try await store.beginRunning(partID: retrying.id, expecting: [.queued, .failed]))
        record = try #require(try await store.record(id: created.id))
        #expect(record.state == .downloading)
        #expect(record.parts.map(\.state) == [.running, .running])
        #expect(record.parts.last?.retryCount == 2)

        // A compare-and-set: a part that is already running only starts again if expected.
        #expect(try await store.beginRunning(partID: queued.id, expecting: [.queued, .failed]) == false)
        #expect(try await store.beginRunning(partID: queued.id, expecting: [.running]))
    }

    /// Only the start that moves the record from queued to downloading reports it.
    @Test func startPartTellsWhetherTheRecordStarted() async throws {
        let (store, _) = try makeStore()
        let first = Self.part()
        let second = Self.part(trackIndex: 2, filename: "b.mp3")
        let created = try await store.upsertRecord(Self.record(key: key, parts: [first, second]), now: now).record

        #expect(try await store.startPart(partID: first.id, expecting: [.queued]) == .startedRecord(created.id))
        #expect(try await store.startPart(partID: second.id, expecting: [.queued]) == .started)
        #expect(try await store.startPart(partID: first.id, expecting: [.queued]) == .refused)
        #expect(try await store.record(id: created.id)?.state == .downloading)
    }

    @Test(arguments: [DownloadState.paused, .failed])
    func beginRunningRefusesStoppedAndFailedRecords(state: DownloadState) async throws {
        let (store, _) = try makeStore()
        let part = Self.part()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [part], state: state), now: now)
            .record
        #expect(try await store.beginRunning(partID: part.id, expecting: [.queued, .failed]) == false)
        #expect(try await store.record(id: created.id) == created)
    }

    @Test func beginRunningRefusesCompletedAndDeletedParts() async throws {
        let (store, container) = try makeStore()
        let completed = Self.part()
        let removed = Self.part(trackIndex: 2, filename: "b.mp3")
        let created = try await store.upsertRecord(Self.record(key: key, parts: [completed, removed]), now: now)
            .record
        #expect(try await store.completePart(partID: completed.id, finalBytes: 10))
        let every = Set(DownloadPartState.allCases)
        #expect(try await store.beginRunning(partID: completed.id, expecting: every) == false)
        #expect(try await store.part(id: completed.id)?.state == .completed)

        // The part was removed from its record.
        let kept = try #require(try await store.record(id: created.id)?.parts.first)
        _ = try await store.upsertRecord(Self.record(key: key, parts: [kept]), now: now)
        #expect(try await store.beginRunning(partID: removed.id, expecting: every) == false)

        // The record was deleted, with its parts.
        let other = Self.part(filename: "c.mp3")
        let otherKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_9")
        let otherRecord = try await store.upsertRecord(Self.record(key: otherKey, parts: [other]), now: now).record
        try await store.deleteRecord(otherRecord.id)
        #expect(try await store.beginRunning(partID: other.id, expecting: every) == false)

        // A part without a record.
        let orphan = Self.part(filename: "orphan.mp3")
        let context = ModelContext(container)
        context.insert(orphan.makeModel())
        try context.save()
        #expect(try await store.beginRunning(partID: orphan.id, expecting: every) == false)
        #expect(try await store.part(id: orphan.id)?.state == .queued)
        #expect(await store.hasUncommittedChanges == false)
    }

    @Test func beginRunningFailedSaveChangesNothing() async throws {
        let (store, _) = try makeStore()
        let part = Self.part()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [part]), now: now).record
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) {
            try await store.beginRunning(partID: part.id, expecting: [.queued], now: now.addingTimeInterval(5))
        }
        #expect(await store.hasUncommittedChanges == false)
        #expect(try await store.record(id: created.id) == created)
        let reread = DownloadStore(modelContainer: store.modelContainer)
        #expect(try await reread.record(id: created.id) == created)
    }

    @Test func queuePartOnlyRequeuesExpectedStates() async throws {
        let (store, _) = try makeStore()
        var running = Self.part(state: .running)
        running.taskIdentifier = 4
        running.lastError = "lost"
        running.hasResumeData = true
        running.bytesWritten = 20
        running.retryCount = 2
        let failed = Self.part(trackIndex: 2, filename: "b.mp3", state: .failed)
        let completed = Self.part(trackIndex: 3, filename: "c.mp3")
        let created = try await store.upsertRecord(
            Self.record(key: key, parts: [running, failed, completed], state: .downloading), now: now
        ).record
        #expect(try await store.completePart(partID: completed.id, finalBytes: 10, now: now))
        let later = now.addingTimeInterval(5)

        #expect(try await store.queuePart(partID: running.id, expecting: [.running], now: later))
        var record = try #require(try await store.record(id: created.id))
        var expected = running
        expected.state = .queued
        expected.taskIdentifier = nil
        expected.lastError = nil
        #expect(record.parts.first == expected)
        #expect(record.updatedAt == later)
        #expect(record.state == .downloading)

        // A compare-and-set: a part that failed (or completed) since it was read is left alone.
        #expect(try await store.queuePart(partID: failed.id, expecting: [.running]) == false)
        #expect(try await store.queuePart(partID: completed.id, expecting: Set(DownloadPartState.allCases)) == false)
        #expect(try await store.queuePart(partID: UUID(), expecting: [.running]) == false)
        record = try #require(try await store.record(id: created.id))
        #expect(record.parts.map(\.state) == [.queued, .failed, .completed])
        #expect(record.updatedAt == later)
    }

    @Test func updatePartChangesOnlyItsFlags() async throws {
        let (store, _) = try makeStore()
        var running = Self.part(state: .running)
        running.taskIdentifier = 4
        running.lastError = "lost"
        running.hasResumeData = true
        running.bytesWritten = 20
        running.retryCount = 2
        let completed = Self.part(trackIndex: 2, filename: "b.mp3")
        let created = try await store.upsertRecord(
            Self.record(key: key, parts: [running, completed], state: .downloading), now: now
        ).record
        #expect(try await store.completePart(partID: completed.id, finalBytes: 10, now: now))
        let later = now.addingTimeInterval(5)

        #expect(try await store.updatePart(partID: running.id, hasResumeData: false, now: later))
        #expect(try await store.updatePart(partID: running.id, retryCount: 0, now: later))
        let record = try #require(try await store.record(id: created.id))
        var expected = running
        expected.hasResumeData = false
        expected.retryCount = 0
        #expect(record.parts.first == expected)
        #expect(record.updatedAt == later)

        #expect(try await store.updatePart(partID: completed.id, retryCount: 3) == false)
        #expect(try await store.updatePart(partID: UUID(), hasResumeData: false) == false)
        #expect(try await store.part(id: completed.id)?.retryCount == 0)
    }

    /// The task finishes before its last throttled progress write lands, with an unknown length:
    /// the final size comes with the completion, and a late progress write can't change it.
    @Test func completionBeforeFinalProgressRecordsFinalSize() async throws {
        let (store, container) = try makeStore()
        var part = Self.part()
        part.expectedBytes = -1
        let created = try await store.upsertRecord(Self.record(key: key, parts: [part]), now: now).record
        #expect(try await store.setPartState(.running, partID: part.id, taskIdentifier: 5))
        #expect(try await store.updateProgress(partID: part.id, bytesWritten: 600, expectedBytes: -1))
        #expect(try await store.completePart(partID: part.id, finalBytes: 1_000, now: now.addingTimeInterval(1)))
        #expect(try await store.updateProgress(partID: part.id, bytesWritten: 900, expectedBytes: -1) == false)

        let completed = try #require(try await store.completedRecords().first)
        #expect(completed.id == created.id)
        #expect(completed.parts.map(\.state) == [.completed])
        #expect(completed.parts.map(\.bytesWritten) == [1_000])
        #expect(completed.parts.map(\.expectedBytes) == [1_000])
        let item = try await LocalItemStore(modelContainer: container).upsertFromDownload(completed, now: now)
        #expect(item.files.map(\.size) == [1_000])
    }

    @Test func taskIdentifierLookupPrefersTheLatestRecord() async throws {
        let (store, _) = try makeStore()
        var stale = Self.part()
        stale.taskIdentifier = 7
        var fresh = Self.part(filename: "z.mp3")
        fresh.taskIdentifier = 7
        _ = try await store.upsertRecord(Self.record(key: key, parts: [stale]), now: now)
        let otherKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_9")
        _ = try await store.upsertRecord(Self.record(key: otherKey, parts: [fresh]), now: now.addingTimeInterval(1))
        #expect(try await store.part(taskIdentifier: 7)?.id == fresh.id)
        #expect(try await store.part(taskIdentifier: 8) == nil)

        // Assigning the identifier to a part clears it from every other part.
        #expect(try await store.setPartState(.running, partID: stale.id, taskIdentifier: 7))
        #expect(try await store.part(taskIdentifier: 7)?.id == stale.id)
        #expect(try await store.part(id: fresh.id)?.taskIdentifier == nil)
    }

    @Test func setStateAllowsEveryTransition() async throws {
        let (store, _) = try makeStore()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [Self.part()]), now: now).record
        let later = now.addingTimeInterval(3)
        for state in [DownloadState.downloading, .paused, .failed, .queued] {
            #expect(try await store.setState(state, forRecord: created.id, now: later))
            #expect(try await store.record(id: created.id)?.state == state)
        }
        #expect(try await store.record(id: created.id)?.updatedAt == later)
        #expect(try await store.setState(.paused, forRecord: UUID()) == false)
    }

    @Test func conditionalFailureStateDoesNotOverwritePause() async throws {
        let (store, _) = try makeStore()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [Self.part()]), now: now).record
        #expect(try await store.setState(.paused, forRecord: created.id))

        #expect(try await store.setState(.failed, forRecord: created.id, expecting: [.queued, .downloading]) == false)
        #expect(try await store.record(id: created.id)?.state == .paused)
    }

    @Test func upsertRejectsConflictsAndMissingConnection() async throws {
        let (store, container) = try makeStore()
        let part = Self.part()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [part]), now: now).record
        let otherKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_9")

        var reusedID = Self.record(key: otherKey, parts: [])
        reusedID.id = created.id
        await #expect(throws: DownloadStore.StoreError.recordIDConflict(created.id)) {
            try await store.upsertRecord(reusedID)
        }
        await #expect(throws: DownloadStore.StoreError.partIDConflict(part.id)) {
            try await store.upsertRecord(Self.record(key: otherKey, parts: [part]))
        }
        let twice = Self.part()
        await #expect(throws: DownloadStore.StoreError.partIDConflict(twice.id)) {
            try await store.upsertRecord(Self.record(key: key, parts: [twice, twice]))
        }
        let missing = UUID()
        await #expect(throws: DownloadStore.StoreError.connectionNotFound(missing)) {
            try await store.upsertRecord(
                Self.record(key: MediaKey(serverConnectionID: missing, libraryItemId: "li_1"), parts: []))
        }
        #expect(await store.hasUncommittedChanges == false)
        #expect(try await store.allRecords() == [created])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DownloadPart>()) == 1)
    }

    @Test func failedSaveIsRolledBackAndNotCommittedLater() async throws {
        let (store, _) = try makeStore()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [Self.part()]), now: now).record
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.deleteRecord(created.id) }
        #expect(await store.hasUncommittedChanges == false)

        // A later, unrelated save doesn't commit the failed deletion.
        #expect(try await store.setState(.paused, forRecord: created.id))
        let reread = DownloadStore(modelContainer: store.modelContainer)
        #expect(try await reread.record(id: created.id)?.state == .paused)
        #expect(try await reread.record(id: created.id)?.parts.count == 1)
    }

    @Test func deleteRecordCascadesToPartsOnly() async throws {
        let (store, container) = try makeStore()
        let created = try await store.upsertRecord(
            Self.record(key: key, parts: [Self.part(), Self.part(trackIndex: 2, filename: "b.mp3")]), now: now
        ).record
        let other = try await store.upsertRecord(
            Self.record(
                key: MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_9"),
                parts: [Self.part(filename: "z.mp3")]), now: now
        ).record
        let context = ModelContext(container)
        context.insert(Fixtures.progress())
        try context.save()

        let deleted = try await store.deleteRecord(created.id)
        #expect(deleted == created)
        #expect(try await store.record(id: created.id) == nil)
        #expect(try await store.deleteRecord(created.id) == nil)
        #expect(try await store.record(id: other.id) == other)
        #expect(try context.fetchCount(FetchDescriptor<DownloadPart>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
    }

    @Test func deleteUnfinishedRecordKeepsACompleteOne() async throws {
        let (store, container) = try makeStore()
        let first = Self.part(state: .completed)
        let second = Self.part(trackIndex: 2, filename: "b.mp3")
        let created = try await store.upsertRecord(Self.record(key: key, parts: [first, second]), now: now).record
        #expect(try await store.completePart(partID: second.id, finalBytes: 7))

        #expect(try await store.deleteUnfinishedRecord(created.id) == .complete)
        #expect(try await store.record(id: created.id)?.isComplete == true)

        #expect(try await store.setPartState(.queued, partID: second.id, taskIdentifier: nil, requeue: true))
        let unfinished = try #require(try await store.record(id: created.id))
        #expect(try await store.deleteUnfinishedRecord(created.id) == .deleted(unfinished))
        #expect(try await store.deleteUnfinishedRecord(created.id) == .notFound)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DownloadPart>()) == 0)
        // A completion arriving after the deletion finds nothing to complete.
        #expect(try await store.completePart(partID: second.id, finalBytes: 7) == false)
    }

    @Test func addCoverPartKeepsTheOtherParts() async throws {
        let (store, _) = try makeStore()
        let audio = Self.part()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [audio]), now: now).record
        #expect(try await store.updateProgress(partID: audio.id, bytesWritten: 9, expectedBytes: 99))
        let cover = Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")
        let coverDate = now.addingTimeInterval(-60)
        let later = now.addingTimeInterval(5)

        #expect(try await store.addCoverPart(cover, coverUpdatedAt: coverDate, toRecord: created.id, now: later))

        let saved = try #require(try await store.record(id: created.id))
        #expect(saved.parts.map(\.id) == [audio.id, cover.id])
        #expect(saved.parts.first?.bytesWritten == 9)
        #expect(saved.parts.last == cover)
        #expect(saved.media.coverUpdatedAt == coverDate)
        #expect(saved.updatedAt == later)
        let another = Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")
        #expect(try await store.addCoverPart(another, coverUpdatedAt: nil, toRecord: created.id) == false)
        #expect(try await store.addCoverPart(another, coverUpdatedAt: nil, toRecord: UUID()) == false)
    }

    @Test func addCoverPartRefusesACompleteRecordAndATakenID() async throws {
        let (store, _) = try makeStore()
        let complete = try await store.upsertRecord(
            Self.record(key: key, parts: [Self.part(state: .completed)]), now: now
        ).record
        let otherKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2", episodeId: "ep_2")
        let taken = Self.part(filename: "ep2.mp3")
        let other = try await store.upsertRecord(Self.record(key: otherKey, parts: [taken]), now: now).record
        let cover = Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")

        #expect(try await store.addCoverPart(cover, coverUpdatedAt: nil, toRecord: complete.id) == false)
        #expect(try await store.record(id: complete.id) == complete)
        var reused = cover
        reused.id = taken.id
        await #expect(throws: DownloadStore.StoreError.partIDConflict(taken.id)) {
            try await store.addCoverPart(reused, coverUpdatedAt: nil, toRecord: other.id)
        }
        #expect(await store.hasUncommittedChanges == false)
        #expect(try await store.record(id: other.id) == other)
    }

    /// A cover fetched again is saved only as a new record of a signed-in connection.
    @Test func insertRecordIfSignedInRefusesATakenKeyAndASignedOutConnection() async throws {
        let (store, container) = try makeStore()
        let itemKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2")
        let cover = Self.record(
            key: itemKey, parts: [Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")])

        let saved = try #require(try await store.insertRecordIfSignedIn(cover, now: now))
        #expect(saved.isCoverOnly)
        #expect(saved.parts == cover.parts)
        #expect(saved.createdAt == now)
        #expect(try await store.record(key: itemKey) == saved)
        var again = Self.record(key: itemKey, parts: [Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")])
        #expect(try await store.insertRecordIfSignedIn(again) == nil)
        #expect(try await store.record(key: itemKey) == saved)

        _ = try await store.deleteRecord(saved.id)
        let context = ModelContext(container)
        let connection = try #require(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).first)
        connection.signedOutAt = now
        try context.save()
        #expect(try await store.insertRecordIfSignedIn(again) == nil)
        connection.signedOutAt = nil
        connection.isDisconnected = true
        try context.save()
        #expect(try await store.insertRecordIfSignedIn(again) == nil)
        #expect(try await store.allRecords().isEmpty)
        again.key = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_2")
        await #expect(throws: DownloadStore.StoreError.connectionNotFound(again.key.serverConnectionID)) {
            try await store.insertRecordIfSignedIn(again)
        }
    }
}
