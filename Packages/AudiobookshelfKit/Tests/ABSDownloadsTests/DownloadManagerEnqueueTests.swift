import ABSCore
import Foundation
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``DownloadManager`` against a fake engine: queueing, duplicates, disk space, the shared
/// podcast cover, replacing a download, and the events it reports.
@Suite(.timeLimit(.minutes(1))) struct DownloadManagerEnqueueTests {
    /// The fixture book's files: three tracks and an ebook.
    static let bookBytes: Int64 = 1_000 + 2_000 + 3_000 + 4_000

    @Test func queuesAndStartsANewBook() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let events = await manager.events()
        let item = LibraryItemFixtures.book()

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(result == .started(record.id))
        #expect(record.state == .queued)
        #expect(record.parts.map(\.kind) == [.audio, .audio, .audio, .ebook, .cover])
        #expect(await fixture.engine.started == [record.parts.map(\.id)])
        #expect(await events.next { _ in true } == .recordChanged(record))
    }

    @Test func aQueuedRecordIsNotQueuedAgain() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let first = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        let second = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(first == .started(record.id))
        #expect(second == .alreadyQueued(record.id))
        #expect(await fixture.engine.started.count == 1)
        #expect(await fixture.engine.resumed.isEmpty)
    }

    @Test(arguments: [DownloadState.paused, .failed])
    func aStoppedRecordIsResumed(state: DownloadState) async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        guard
            case .started(let recordID) = try await manager.enqueue(
                item: item, episodeID: nil, connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        try await fixture.store.setState(state, forRecord: recordID)
        let events = await manager.events()

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        #expect(result == .alreadyQueued(recordID))
        #expect(await fixture.engine.resumed == [recordID])
        let record = try #require(try await fixture.store.record(id: recordID))
        #expect(record.state == .queued)
        #expect(await events.next { _ in true } == .recordChanged(record))
    }

    @Test func aDownloadedBookIsNotQueued() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let local = try await fixture.storeDownloaded(item)

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        #expect(result == .alreadyDownloaded(local.id))
        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(await fixture.engine.started.isEmpty)
    }

    /// A downloaded episode is skipped; another episode of the podcast is queued, without the
    /// cover the local item already has.
    @Test func onlyTheDownloadedEpisodeIsSkipped() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_1")
        try #require(local.coverRelativePath != nil)

        let downloaded = try await manager.enqueue(item: item, episodeID: "ep_1", connectionID: fixture.connectionID)
        let other = try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: fixture.connectionID)

        #expect(downloaded == .alreadyDownloaded(local.id))
        let record = try #require(try await fixture.store.record(key: fixture.key(item, episodeID: "ep_2")))
        #expect(other == .started(record.id))
        #expect(record.parts.map(\.kind) == [.audio])
        #expect(try await fixture.store.allRecords().count == 1)
    }

    /// Two episodes queued before either finishes plan one cover part between them.
    @Test func twoQueuedEpisodesShareOneCoverPart() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()

        _ = try await manager.enqueue(item: item, episodeID: "ep_1", connectionID: fixture.connectionID)
        _ = try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: fixture.connectionID)

        let first = try #require(try await fixture.store.record(key: fixture.key(item, episodeID: "ep_1")))
        let second = try #require(try await fixture.store.record(key: fixture.key(item, episodeID: "ep_2")))
        #expect(first.parts.map(\.kind) == [.audio, .cover])
        #expect(second.parts.map(\.kind) == [.audio])
        let covers = try await fixture.store.allRecords().flatMap(\.parts).filter { $0.kind == .cover }
        #expect(covers.count == 1)
    }

    /// The second of two overlapping calls for one book waits for the first, then finds its
    /// record: one record, started once.
    @Test func concurrentEnqueuesOfOneBookMakeOneRecord() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let connectionID = fixture.connectionID
        fixture.capacity.hold()

        let first = Task { try await manager.enqueue(item: item, episodeID: nil, connectionID: connectionID) }
        #expect(await fixture.nextCheckpoint() == .capacity)
        let second = Task { try await manager.enqueue(item: item, episodeID: nil, connectionID: connectionID) }
        // With the guard, the second call waits; without it, it would reach the capacity check.
        let reached = await fixture.nextCheckpoint()
        fixture.capacity.release()
        let results = [try await first.value, try await second.value]

        #expect(reached == .waiting(fixture.key(item)))
        let records = try await fixture.store.allRecords()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(results == [.started(record.id), .alreadyQueued(record.id)])
        #expect(await fixture.engine.started == [record.parts.map(\.id)])
    }

    @Test(arguments: [0, 1])
    func needsTheBytesToFetchPlusHeadroom(spare: Int64) async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let required = Self.bookBytes + DownloadManager.storageHeadroom
        fixture.capacity.set(required - 1 + spare)

        if spare == 0 {
            await #expect(throws: DownloadManagerError.insufficientStorage(required: required, available: required - 1))
            {
                try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
            }
            #expect(try await fixture.store.allRecords().isEmpty)
            #expect(await fixture.engine.started.isEmpty)
        } else {
            let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
            guard case .started = result else {
                Issue.record("Unexpected \(result)")
                return
            }
        }
    }

    /// Without file sizes, the item's (or episode's) reported size is used.
    @Test func unknownSizesUseTheReportedSize() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let base = LibraryItemFixtures.book(
            files: [LibraryItemFixtures.BookFile(ino: "101", path: "/audiobooks/Dune/01.mp3", size: 0)], ebook: nil)
        let book = LibraryItem(
            id: base.id, libraryId: base.libraryId, updatedAt: base.updatedAt, mediaType: .book, media: base.media,
            size: 500_000_000)
        let episode = LibraryItemFixtures.podcast(
            episodes: [LibraryItemFixtures.episode(id: "ep_1", ino: "301", hasAudioFile: false)])
        fixture.capacity.set(600_000_000)

        await #expect(
            throws: DownloadManagerError.insufficientStorage(
                required: 500_000_000 + DownloadManager.storageHeadroom, available: 600_000_000)
        ) {
            try await manager.enqueue(item: book, episodeID: nil, connectionID: fixture.connectionID)
        }
        // The episode's reported size (4,321 bytes) fits.
        let result = try await manager.enqueue(item: episode, episodeID: "ep_1", connectionID: fixture.connectionID)
        guard case .started = result else {
            Issue.record("Unexpected \(result)")
            return
        }
    }

    /// Downloading a stored book again plans the stored paths, so the new files replace the old
    /// ones in place instead of landing next to them with ` (2)` suffixes.
    @Test func replacingADownloadedBookReusesItsPaths() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let local = try await fixture.storeDownloaded(item)

        let result = try await manager.enqueue(
            item: item, episodeID: nil, connectionID: fixture.connectionID, replacingExisting: true)

        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(result == .started(record.id))
        let files = record.parts.filter { $0.kind != .cover }.map(\.destinationRelativePath)
        #expect(files == local.files.map(\.relativePath))
        #expect(record.parts.last?.destinationRelativePath == local.coverRelativePath)
    }

    /// Replacing a queued record pauses it, stops its transfers without resume data, and
    /// saves the new plan under the same record.
    @Test func replacingAQueuedRecordStopsItsTransfers() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        _ = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        let old = try #require(try await fixture.store.record(key: fixture.key(item)))

        let result = try await manager.enqueue(
            item: item, episodeID: nil, connectionID: fixture.connectionID, replacingExisting: true)

        let records = try await fixture.store.allRecords()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(result == .started(old.id))
        #expect(record.id == old.id)
        #expect(record.state == .queued)
        #expect(Set(record.parts.map(\.id)).isDisjoint(with: old.parts.map(\.id)))
        #expect(await fixture.engine.stopped == [.init(partIDs: old.parts.map(\.id), keepingResumeData: false)])
        #expect(await fixture.engine.started == [old.parts.map(\.id), record.parts.map(\.id)])
    }

    @Test func planErrorsAreMapped() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let longID = String(repeating: "x", count: 300)
        let book = LibraryItemFixtures.book(id: longID)

        await #expect(throws: DownloadManagerError.invalidIdentifier(longID)) {
            try await manager.enqueue(item: book, episodeID: nil, connectionID: fixture.connectionID)
        }
        await #expect(throws: DownloadManagerError.episodeNotFound) {
            try await manager.enqueue(
                item: LibraryItemFixtures.podcast(), episodeID: "ep_9", connectionID: fixture.connectionID)
        }
        await #expect(throws: DownloadManagerError.notPodcast) {
            try await manager.enqueue(
                item: LibraryItemFixtures.book(), episodeID: "ep_1", connectionID: fixture.connectionID)
        }
        await #expect(throws: DownloadManagerError.connectionNotFound(fixture.connectionID.inverted)) {
            try await manager.enqueue(
                item: LibraryItemFixtures.book(), episodeID: nil, connectionID: fixture.connectionID.inverted)
        }
        #expect(try await fixture.store.allRecords().isEmpty)
    }

    // MARK: - Events

    /// The first progress of a record is sent at once; later ones within a second are merged
    /// into one when the second ends; reaching the end is sent at once.
    @Test func progressIsPerRecordAndPaced() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        try await manager.start()
        let item = LibraryItemFixtures.book(ebook: nil)
        guard
            case .started(let recordID) = try await manager.enqueue(
                item: item, episodeID: nil, connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let parts = try #require(try await fixture.store.record(id: recordID)).parts
        let events = await manager.events()
        func send(_ index: Int, bytes: Int64) {
            fixture.engine.progressContinuation.yield(
                DownloadProgress(
                    partID: parts[index].id, recordID: recordID, bytesWritten: bytes,
                    expectedBytes: parts[index].expectedBytes))
        }

        send(0, bytes: 600)
        #expect(await events.nextProgress() == .progress(recordID: recordID, fraction: 0.1, bytes: 600))
        _ = await fixture.clock.started.first { _ in true }
        send(0, bytes: 1_000)
        send(1, bytes: 800)
        let last = DownloadProgress(partID: parts[1].id, recordID: recordID, bytesWritten: 800, expectedBytes: 2_000)
        _ = await fixture.checkpoints.first { $0 == .progressHandled(last) }
        fixture.clock.fire()
        #expect(await events.nextProgress() == .progress(recordID: recordID, fraction: 0.3, bytes: 1_800))
        send(1, bytes: 2_000)
        send(2, bytes: 3_000)
        #expect(await events.nextProgress() == .progress(recordID: recordID, fraction: 1, bytes: 6_000))
    }

    @Test func reportsFailuresAndCompletion() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        try await manager.start()
        let item = LibraryItemFixtures.book()
        guard
            case .started(let recordID) = try await manager.enqueue(
                item: item, episodeID: nil, connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let partID = try #require(try await fixture.store.record(id: recordID)?.parts.first?.id)
        let events = await manager.events()

        try await fixture.store.setState(.failed, forRecord: recordID)
        fixture.engine.updateContinuation.yield(
            .partFailed(partID: partID, recordID: recordID, code: .httpStatus, message: "404", willRetry: false))
        let failed = try #require(try await fixture.store.record(id: recordID))
        #expect(await events.next { _ in true } == .recordChanged(failed))
        #expect(await events.next { _ in true } == .failed(recordID: recordID, code: .httpStatus, message: "404"))

        // The engine deletes a record once it is a local item.
        try await fixture.store.deleteRecord(recordID)
        let itemID = UUID()
        fixture.engine.updateContinuation.yield(.recordComplete(recordID: recordID, itemID: itemID))
        #expect(
            await events.next { _ in true }
                == .completed(recordID: recordID, itemID: itemID, key: fixture.key(item)))
    }

    @Test func readsTheVolumeCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "capacity-\(UUID().uuidString)")
        // The downloads folder doesn't exist yet: its volume is still found.
        #expect(try VolumeStorageCapacity(locations: DownloadLocations(root: root)).availableCapacity() > 0)
    }
}

extension UUID {
    /// A different, fixed UUID.
    fileprivate var inverted: UUID {
        UUID(
            uuid: (
                uuid.0 ^ 0xFF, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7, uuid.8, uuid.9, uuid.10,
                uuid.11, uuid.12, uuid.13, uuid.14, uuid.15
            ))
    }
}
