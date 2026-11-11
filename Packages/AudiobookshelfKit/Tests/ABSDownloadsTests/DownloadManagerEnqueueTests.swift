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

    /// Replacing a queued record pauses it, stops its transfers without resume data, deletes it
    /// and saves the new plan as a new record.
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
        #expect(result == .started(record.id))
        #expect(record.id != old.id)
        #expect(record.state == .queued)
        #expect(Set(record.parts.map(\.id)).isDisjoint(with: old.parts.map(\.id)))
        #expect(await fixture.engine.stopped == [.init(partIDs: old.parts.map(\.id), keepingResumeData: false)])
        #expect(await fixture.engine.started == [old.parts.map(\.id), record.parts.map(\.id)])
    }

    /// A stop skips a settling part, so the engine can finalise the old record after the
    /// replacement is saved, deleting it by ID: the new record survives that late delete.
    @Test func aLateFinaliseOfTheReplacedRecordKeepsTheNewOne() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        _ = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        let old = try #require(try await fixture.store.record(key: fixture.key(item)))
        for part in old.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 1) }
        try await fixture.engine.settle(old.id)

        let result = try await manager.enqueue(
            item: item, episodeID: nil, connectionID: fixture.connectionID, replacingExisting: true)
        try #require(try await fixture.store.record(id: old.id) == nil)
        try await fixture.engine.finishSettling()

        // The old record was finalised: it made the local item.
        let local = try await fixture.localItems.item(
            serverConnectionID: fixture.connectionID, libraryItemId: item.id)
        #expect(local?.files.count == old.parts.filter { $0.kind != .cover }.count)
        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(record.id != old.id)
        #expect(result == .started(record.id))
        #expect(await fixture.engine.started.last == record.parts.map(\.id))
    }

    /// A record finalised between reading it and resuming it is planned again.
    @Test func aRecordGoneBeforeItsResumeIsPlannedAgain() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        guard
            case .started(let oldID) = try await manager.enqueue(
                item: item, episodeID: nil, connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        try await fixture.store.setState(.paused, forRecord: oldID)
        await fixture.engine.finaliseOnResume()

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(record.id != oldID)
        #expect(result == .started(record.id))
    }

    /// An episode doesn't wait for a cover part whose record failed: it plans its own.
    @Test func aFailedRecordsCoverPartIsNotShared() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        guard
            case .started(let firstID) = try await manager.enqueue(
                item: item, episodeID: "ep_1", connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        try await fixture.store.setState(.failed, forRecord: firstID)

        _ = try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: fixture.connectionID)

        let second = try #require(try await fixture.store.record(key: fixture.key(item, episodeID: "ep_2")))
        #expect(second.parts.map(\.kind) == [.audio, .cover])
    }

    @Test func anUnreadableCapacityStillQueues() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        fixture.capacity.set(nil)

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(result == .started(record.id))
    }

    /// Server sizes too big to add up need `Int64.max`, which never fits, instead of trapping.
    @Test func hugeSizesSaturateTheRequirement() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book(
            files: [
                LibraryItemFixtures.BookFile(ino: "101", path: "/audiobooks/Dune/01.mp3", size: .max),
                LibraryItemFixtures.BookFile(ino: "102", path: "/audiobooks/Dune/02.mp3", size: 1),
            ], ebook: nil)
        fixture.capacity.set(1_000_000)

        await #expect(throws: DownloadManagerError.insufficientStorage(required: .max, available: 1_000_000)) {
            try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        }
    }

    /// Resuming a paused record needs its remaining bytes plus the headroom, like a new one.
    @Test func aStoppedRecordNeedsTheSpaceToResume() async throws {
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
        let first = try #require(try await fixture.store.record(id: recordID)?.parts.first)
        try await fixture.store.completePart(partID: first.id, finalBytes: first.expectedBytes)
        try await fixture.store.setState(.paused, forRecord: recordID)
        let required = Self.bookBytes - first.expectedBytes + DownloadManager.storageHeadroom
        fixture.capacity.set(required - 1)

        await #expect(throws: DownloadManagerError.insufficientStorage(required: required, available: required - 1)) {
            try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        }
        #expect(await fixture.engine.resumed.isEmpty)
        #expect(try await fixture.store.record(id: recordID)?.state == .paused)
    }

    /// A cover another episode's record has fetched, while that record failed, is carried into
    /// the next episode's record as a completed part, so its local item gets the cover.
    @Test func aFetchedCoverOfAFailedRecordIsCarried() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        guard
            case .started(let firstID) = try await manager.enqueue(
                item: item, episodeID: "ep_1", connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let cover = try #require(try await fixture.store.record(id: firstID)?.parts.first { $0.kind == .cover })
        let file = try fixture.locations.fileURL(forRelativePath: cover.destinationRelativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: file)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)
        try await fixture.store.setState(.failed, forRecord: firstID)

        _ = try await manager.enqueue(item: item, episodeID: "ep_2", connectionID: fixture.connectionID)

        var second = try #require(try await fixture.store.record(key: fixture.key(item, episodeID: "ep_2")))
        let carried = try #require(second.parts.first { $0.kind == .cover })
        #expect(carried.id != cover.id)
        #expect(carried.state == .completed)
        #expect(carried.destinationRelativePath == cover.destinationRelativePath)
        #expect(carried.bytesWritten == 5)
        // Finalising the episode attaches the carried cover.
        for index in second.parts.indices where second.parts[index].kind == .audio {
            second.parts[index].state = .completed
            second.parts[index].bytesWritten = second.parts[index].expectedBytes
        }
        let local = try await fixture.localItems.upsertFromDownload(second)
        #expect(local.coverRelativePath == cover.destinationRelativePath)
    }

    /// A cover fetched for an older version of the item isn't carried: the new plan's
    /// `coverUpdatedAt` would mark it current, so the new version is fetched.
    @Test func aCoverOfAnOlderVersionIsFetchedAgain() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let old = LibraryItemFixtures.podcast()
        guard
            case .started(let firstID) = try await manager.enqueue(
                item: old, episodeID: "ep_1", connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let cover = try #require(try await fixture.store.record(id: firstID)?.parts.first { $0.kind == .cover })
        let file = try fixture.locations.fileURL(forRelativePath: cover.destinationRelativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: file)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)
        try await fixture.store.setState(.failed, forRecord: firstID)
        let updated = LibraryItem(
            id: old.id, libraryId: old.libraryId, updatedAt: (old.updatedAt ?? 0) + 1_000, mediaType: .podcast,
            media: old.media)

        _ = try await manager.enqueue(item: updated, episodeID: "ep_2", connectionID: fixture.connectionID)

        let second = try #require(try await fixture.store.record(key: fixture.key(updated, episodeID: "ep_2")))
        let fetched = try #require(second.parts.first { $0.kind == .cover })
        #expect(fetched.state == .queued)
        #expect(fetched.serverPath != cover.serverPath)
    }

    /// A stopped part without resume data starts again from the beginning: its whole size counts.
    /// One with resume data needs only the rest.
    @Test func onlyResumableProgressIsSubtracted() async throws {
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
        let parts = try #require(try await fixture.store.record(id: recordID)).parts
        // Track 1 (1,000 bytes) stopped at 900 without resume data; track 2 (2,000) at 1,500 with it.
        try await fixture.store.updateProgress(partID: parts[0].id, bytesWritten: 900, expectedBytes: 1_000)
        try await fixture.store.updateProgress(partID: parts[1].id, bytesWritten: 1_500, expectedBytes: 2_000)
        try await fixture.store.updatePart(partID: parts[1].id, hasResumeData: true)
        try await fixture.store.setState(.paused, forRecord: recordID)
        let required = Self.bookBytes - 1_500 + DownloadManager.storageHeadroom
        fixture.capacity.set(required - 1)

        await #expect(throws: DownloadManagerError.insufficientStorage(required: required, available: required - 1)) {
            try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        }
    }

    /// With a file of unknown size left, the reported size stands in, less the bytes already on
    /// disk and kept: completed files and resumable progress.
    @Test func theReportedSizeFallbackSkipsKeptBytes() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let base = LibraryItemFixtures.book(
            files: [
                LibraryItemFixtures.BookFile(ino: "101", path: "/audiobooks/Dune/01.mp3", size: 1_000),
                LibraryItemFixtures.BookFile(ino: "102", path: "/audiobooks/Dune/02.mp3", size: 0),
                LibraryItemFixtures.BookFile(ino: "103", path: "/audiobooks/Dune/03.mp3", size: 0),
            ], ebook: nil)
        let item = LibraryItem(
            id: base.id, libraryId: base.libraryId, updatedAt: base.updatedAt, mediaType: .book, media: base.media,
            size: 5_000)
        guard
            case .started(let recordID) = try await manager.enqueue(
                item: item, episodeID: nil, connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let parts = try #require(try await fixture.store.record(id: recordID)).parts
        // Track 1 completed; track 2 stopped at 500 with resume data; track 3 at 300 without.
        try await fixture.store.completePart(partID: parts[0].id, finalBytes: 1_000)
        try await fixture.store.updateProgress(partID: parts[1].id, bytesWritten: 500, expectedBytes: 0)
        try await fixture.store.updatePart(partID: parts[1].id, hasResumeData: true)
        try await fixture.store.updateProgress(partID: parts[2].id, bytesWritten: 300, expectedBytes: 0)
        try await fixture.store.setState(.paused, forRecord: recordID)
        let required = 5_000 - 1_000 - 500 + DownloadManager.storageHeadroom
        fixture.capacity.set(required - 1)

        await #expect(throws: DownloadManagerError.insufficientStorage(required: required, available: required - 1)) {
            try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        }
        // It fits with exactly that much free.
        fixture.capacity.set(required)
        #expect(
            try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
                == .alreadyQueued(recordID))
    }

    /// A negative reported size counts as nothing, even with bytes kept on disk to subtract.
    @Test func aNegativeReportedSizeCountsAsZero() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let base = LibraryItemFixtures.book(
            files: [
                LibraryItemFixtures.BookFile(ino: "101", path: "/audiobooks/Dune/01.mp3", size: 1_000),
                LibraryItemFixtures.BookFile(ino: "102", path: "/audiobooks/Dune/02.mp3", size: 0),
            ], ebook: nil)
        let item = LibraryItem(
            id: base.id, libraryId: base.libraryId, updatedAt: base.updatedAt, mediaType: .book, media: base.media,
            size: .min)
        guard
            case .started(let recordID) = try await manager.enqueue(
                item: item, episodeID: nil, connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let completed = try #require(try await fixture.store.record(id: recordID)?.parts.first)
        try await fixture.store.completePart(partID: completed.id, finalBytes: 1_000)
        try await fixture.store.setState(.paused, forRecord: recordID)
        fixture.capacity.set(DownloadManager.storageHeadroom)

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        #expect(result == .alreadyQueued(recordID))
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
        let itemID = try await fixture.storeDownloaded(item).id
        fixture.engine.updateContinuation.yield(.recordComplete(recordID: recordID, itemID: itemID))
        #expect(
            await events.next { _ in true }
                == .completed(recordID: recordID, itemID: itemID, key: fixture.key(item)))
    }

    /// Expected lengths too big to add up as `Int64` still make a progress fraction.
    @Test func hugeExpectedLengthsDontOverflowProgress() async throws {
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
        let huge: Int64 = 1 << 62
        let partProgress = parts.prefix(3).map {
            DownloadProgress(partID: $0.id, recordID: recordID, bytesWritten: 1_000, expectedBytes: huge)
        }

        fixture.engine.progressContinuation.yield(partProgress[0])
        _ = await events.nextProgress()
        _ = await fixture.clock.started.first { _ in true }
        fixture.engine.progressContinuation.yield(partProgress[1])
        fixture.engine.progressContinuation.yield(partProgress[2])
        _ = await fixture.checkpoints.first { $0 == .progressHandled(partProgress[2]) }
        fixture.clock.fire()

        #expect(
            await events.nextProgress()
                == .progress(recordID: recordID, fraction: 3_000 / (3 * Double(huge)), bytes: 3_000))
    }

    /// Progress of a part handled after its completion was read is stale: the stored final
    /// size is kept.
    @Test func progressAfterAPartCompletedIsIgnored() async throws {
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
        try await fixture.store.completePart(partID: parts[0].id, finalBytes: 1_000)
        fixture.engine.updateContinuation.yield(.partCompleted(partID: parts[0].id, recordID: recordID))
        _ = await events.next { if case .recordChanged = $0 { true } else { false } }

        fixture.engine.progressContinuation.yield(
            DownloadProgress(partID: parts[0].id, recordID: recordID, bytesWritten: 500, expectedBytes: 900))
        fixture.engine.progressContinuation.yield(
            DownloadProgress(partID: parts[1].id, recordID: recordID, bytesWritten: 200, expectedBytes: 2_000))

        #expect(await events.nextProgress() == .progress(recordID: recordID, fraction: 0.2, bytes: 1_200))
    }

    /// A failure the engine retries changes the record but isn't reported as a failure.
    @Test func aRetriedFailureIsOnlyARecordChange() async throws {
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
        let record = try #require(try await fixture.store.record(id: recordID))
        let partID = try #require(record.parts.first?.id)
        let events = await manager.events()

        fixture.engine.updateContinuation.yield(
            .partFailed(partID: partID, recordID: recordID, code: .transfer, message: "offline", willRetry: true))
        fixture.engine.updateContinuation.yield(.partCompleted(partID: partID, recordID: recordID))

        // Updates are handled in order: a `.failed` would come between the two changes.
        #expect(await events.next { _ in true } == .recordChanged(record))
        #expect(await events.next { _ in true } == .recordChanged(record))
    }

    /// Overlapping starts read the engine's streams once, so updates are handled once each,
    /// in order.
    @Test func overlappingStartsReadTheEngineOnce() async throws {
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
        let record = try #require(try await fixture.store.record(id: recordID))
        let partID = try #require(record.parts.first?.id)
        let events = await manager.events()

        fixture.holdStart()
        let first = Task { try await manager.start() }
        #expect(await fixture.checkpoints.first { $0 == .trackingRecords } != nil)
        // The first call waits after making its readers: the second must not make more.
        let second = Task { try await manager.start() }
        try await second.value
        fixture.releaseStart()
        try await first.value

        #expect(fixture.engine.updatesReadCount == 1)
        fixture.engine.updateContinuation.yield(.partCompleted(partID: partID, recordID: recordID))
        #expect(await events.next { _ in true } == .recordChanged(record))
        try await fixture.store.deleteRecord(recordID)
        let itemID = try await fixture.storeDownloaded(item).id
        fixture.engine.updateContinuation.yield(.recordComplete(recordID: recordID, itemID: itemID))
        #expect(
            await events.next { _ in true }
                == .completed(recordID: recordID, itemID: itemID, key: fixture.key(item)))
    }

    /// Every subscriber gets every event; one that stops iterating is removed.
    @Test func everySubscriberGetsEveryEvent() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let first = await manager.events()
        let second = await manager.events()

        _ = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)

        let record = try #require(try await fixture.store.record(key: fixture.key(item)))
        #expect(await first.next { _ in true } == .recordChanged(record))
        #expect(await second.next { _ in true } == .recordChanged(record))
        let reader = Task { for await _ in second {} }
        reader.cancel()
        _ = await fixture.checkpoints.first { $0 == .subscriberRemoved }
        #expect(await manager.subscriberCount == 1)
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
