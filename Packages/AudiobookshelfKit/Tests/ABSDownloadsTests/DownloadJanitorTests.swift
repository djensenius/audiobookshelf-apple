import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``DownloadJanitor``'s sweep, against a fake engine, an in-memory store and a temporary
/// download root, at a fixed time: every file's modification date is set relative to it.
@Suite(.timeLimit(.minutes(1))) struct DownloadJanitorTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let old = now.addingTimeInterval(-3600)

    @Test func removesOrphanedFilesAndKeepsReferencedOnes() async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        let orphan = "\(setup.book.relativeDirectory)/stray.tmp"
        let unknown = "\(fixture.connectionID.uuidString)/li_gone/episodes/ep_9/old.mp3"
        try write(orphan, fixture)
        try write(unknown, fixture)
        try age(fixture)

        let report = await janitor(fixture).sweep()

        #expect(report.outcome == .completed)
        #expect(Set(report.removedFiles) == [orphan, unknown])
        #expect(!exists(orphan, fixture))
        #expect(!exists("\(fixture.connectionID.uuidString)/li_gone", fixture))
        #expect(
            Set(report.removedFolders)
                == Set(
                    ["li_gone/episodes/ep_9", "li_gone/episodes", "li_gone"].map {
                        "\(fixture.connectionID.uuidString)/\($0)"
                    }))
        #expect(setup.referenced.allSatisfy { exists($0, fixture) })
        #expect(try await fixture.localItems.item(id: setup.book.id) != nil)
        #expect(try await fixture.store.record(id: setup.record.id) != nil)
    }

    /// A read that fails stops the sweep before anything is deleted, even what it already knows
    /// is unreferenced.
    @Test(arguments: [SweepReport.Step.listingFiles, .readingRecords, .readingLocalItems, .readingConnections])
    func aFailedReadDeletesNothing(step: SweepReport.Step) async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        let orphan = "\(fixture.connectionID.uuidString)/li_gone/old.mp3"
        try write(orphan, fixture)
        let blob = try writeBlob(UUID(), fixture)
        try age(fixture)

        let report = await janitor(fixture, failing: step).sweep()

        #expect(report.outcome == .aborted(step))
        #expect(report.removedFiles.isEmpty)
        #expect(report.removedFolders.isEmpty)
        #expect(report.removedResumeData.isEmpty)
        #expect(exists(orphan, fixture))
        #expect(FileManager.default.fileExists(atPath: blob.path(percentEncoded: false)))
        #expect(setup.referenced.allSatisfy { exists($0, fixture) })
    }

    @Test func keepsARecentlyChangedFile() async throws {
        let fixture = try await ManagerFixture()
        _ = try await Setup(fixture)
        let recent = "\(fixture.connectionID.uuidString)/li_gone/landing.mp3"
        let stale = "\(fixture.connectionID.uuidString)/li_gone/stale.mp3"
        try write(recent, fixture)
        try write(stale, fixture)
        try age(fixture)
        try setModified(recent, Self.now.addingTimeInterval(-60), fixture)

        let report = await janitor(fixture).sweep()

        #expect(report.outcome == .completed)
        #expect(report.keptRecentFiles == [recent])
        #expect(report.removedFiles == [stale])
        #expect(exists(recent, fixture))
        #expect(!exists(stale, fixture))
    }

    /// Only blobs of parts no record has go; a recent one stays until a later sweep.
    @Test func removesResumeDataOfPartsThatAreGone() async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        let live = try writeBlob(setup.record.parts[0].id, fixture)
        let goneID = UUID()
        let gone = try writeBlob(goneID, fixture)
        let recent = try writeBlob(UUID(), fixture)
        let other = fixture.locations.resumeDataRoot.appending(path: "notes.txt")
        try Data().write(to: other)
        try age(fixture)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.now.addingTimeInterval(-60)], ofItemAtPath: recent.path(percentEncoded: false))

        let report = await janitor(fixture).sweep()

        #expect(report.removedResumeData == [goneID])
        #expect(!FileManager.default.fileExists(atPath: gone.path(percentEncoded: false)))
        for url in [live, recent, other] {
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    /// A disconnected connection is deleted once its last download is gone, not before.
    @Test func deletesADisconnectedConnectionWithNothingLeft() async throws {
        let fixture = try await ManagerFixture()
        let local = try await fixture.storeDownloaded(LibraryItemFixtures.book())
        #expect(try await fixture.connections.remove(id: fixture.connectionID) == .disconnected)

        #expect(await janitor(fixture).sweep().removedConnections.isEmpty)
        #expect(try await fixture.connections.connection(id: fixture.connectionID) != nil)

        try await fixture.localItems.deleteItem(id: local.id)
        let report = await janitor(fixture).sweep()

        #expect(report.removedConnections == [fixture.connectionID])
        #expect(try await fixture.connections.connection(id: fixture.connectionID) == nil)
    }

    /// Records and local items of a connection that no longer exists go, with their files.
    @Test func deletesMediaOfAConnectionThatIsGone() async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        try age(fixture)
        try deleteConnection(fixture.connectionID, fixture)

        let report = await janitor(fixture).sweep()

        #expect(report.outcome == .completed)
        #expect(report.removedRecords == [setup.record.id])
        #expect(report.removedItems == [setup.book.id])
        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(try await fixture.localItems.allItems().isEmpty)
        #expect(await fixture.engine.stopped.map(\.partIDs) == [setup.record.parts.map(\.id)])
        #expect(!exists(fixture.connectionID.uuidString, fixture))
    }

    /// Only the App Group store is swept: the fallback store (opened at a `.url`) and test
    /// stores don't hold the app's downloads.
    @Test(arguments: [DataStack.Location.inMemory, .url(URL(filePath: "/tmp/Audiobookshelf.store"))])
    func skipsAnyStoreButTheAppGroupOne(location: DataStack.Location) async throws {
        let fixture = try await ManagerFixture()
        let orphan = "\(fixture.connectionID.uuidString)/li_gone/old.mp3"
        try write(orphan, fixture)
        try age(fixture)

        let report = await DownloadJanitor(
            manager: fixture.makeManager(), connections: fixture.connections, storeLocation: location,
            now: { Self.now }, beforeRead: nil
        ).sweep()

        #expect(report == SweepReport(outcome: .skipped(.notAppGroupStore)))
        #expect(exists(orphan, fixture))
    }

    /// The public initialiser reads the location from the stack itself.
    @Test func readsTheLocationFromTheDataStack() async throws {
        let fixture = try await ManagerFixture()
        let orphan = "\(fixture.connectionID.uuidString)/li_gone/old.mp3"
        try write(orphan, fixture)
        try age(fixture)

        let report = await DownloadJanitor(
            manager: fixture.makeManager(), connections: fixture.connections,
            dataStack: try DataStack(location: .inMemory), now: { Self.now }
        ).sweep()

        #expect(report.outcome == .skipped(.notAppGroupStore))
        #expect(exists(orphan, fixture))
    }

    // MARK: - Races

    /// A download of an item the snapshot doesn't know, enqueued while the sweep reads the
    /// store, refers to a path an old file is at (its new file would replace it): the file
    /// stays.
    @Test func keepsAFileADownloadEnqueuedDuringTheSweepRefersTo() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book(id: "li_new")
        let planned = try DownloadPlanner(locations: fixture.locations).plan(
            item: item, episodeID: nil, connectionID: fixture.connectionID, existingCoverPath: nil)
        let cover = try #require(planned.parts.first { $0.kind == .cover }).destinationRelativePath
        try write(cover, fixture)
        try age(fixture)

        let report = await janitor(fixture, manager: manager) { step in
            if step == .readingLocalItems {
                _ = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
            }
        }.sweep()

        #expect(report.outcome == .completed)
        #expect(exists(cover, fixture))
        #expect(!report.removedFiles.contains(cover))
        #expect(try await fixture.store.allRecords().map(\.key.libraryItemId) == ["li_new"])
    }

    /// A disconnected connection logged in to again after the sweep read it stays, connected.
    @Test func keepsAConnectionLoggedInToDuringTheSweep() async throws {
        let fixture = try await ManagerFixture()
        let reconnect = { @Sendable in
            try await fixture.connections.upsertLogin(
                address: ServerAddress("https://abs.example.com")!, userId: "usr_1", username: "reader",
                authMethod: .local, serverVersion: "2.26.0")
        }
        // A connection with a download, so `remove` only disconnects it; the download then goes.
        let local = try await fixture.storeDownloaded(LibraryItemFixtures.book())
        #expect(try await fixture.connections.remove(id: fixture.connectionID) == .disconnected)
        try await fixture.localItems.deleteItem(id: local.id)
        // Media of a removed connection, so the sweep has something to delete after its reads.
        let gone = try await fixture.connections.upsertLogin(
            address: ServerAddress("https://other.example.com")!, userId: "usr_2", username: "other",
            authMethod: .local, serverVersion: "2.26.0")
        let goneItem = try await fixture.storeDownloaded(LibraryItemFixtures.book(id: "li_x"), connectionID: gone.id)
        try deleteConnection(gone.id, fixture)

        let report = await janitor(fixture) { step in
            if step == .deletingOrphanedMedia { _ = try await reconnect() }
        }.sweep()

        #expect(report.outcome == .completed)
        #expect(report.removedItems == [goneItem.id])
        #expect(report.removedConnections.isEmpty)
        let connection = try #require(try await fixture.connections.connection(id: fixture.connectionID))
        #expect(!connection.isDisconnected)
    }

    @Test func aSecondSweepWhileOneRunsIsSkipped() async throws {
        let fixture = try await ManagerFixture()
        let gate = StubGate()
        let (reached, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
        let janitor = janitor(fixture) { step in
            guard step == .readingRecords else { return }
            reachedContinuation.yield()
            await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
        }
        let first = Task { await janitor.sweep() }
        _ = await reached.first { _ in true }

        #expect(await janitor.sweep() == SweepReport(outcome: .skipped(.alreadySweeping)))

        gate.open()
        #expect(await first.value.outcome == .completed)
    }

    // MARK: - Aborts and folders

    /// A reread of an item that fails stops the sweep after the files removed before it, and
    /// before the folders.
    @Test func anAbortWhileRereadingAnItemReportsWhatWasRemoved() async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        let stray = "\(fixture.connectionID.uuidString)/stray.tmp"
        let held = "\(setup.book.relativeDirectory)/stray.tmp"
        let emptyFolder = "\(fixture.connectionID.uuidString)/li_empty"
        try write(stray, fixture)
        try write(held, fixture)
        try FileManager.default.createDirectory(
            at: fixture.locations.downloadsRoot.appending(path: emptyFolder), withIntermediateDirectories: true)
        try age(fixture)

        let report = await janitor(fixture, failing: .readingItem).sweep()

        #expect(report.outcome == .aborted(.readingItem))
        #expect(report.removedFiles == [stray])
        #expect(report.removedFolders.isEmpty)
        #expect(!exists(stray, fixture))
        #expect(exists(held, fixture))
        #expect(exists(emptyFolder, fixture))
    }

    /// A deletion of a removed connection's media that fails stops the sweep after the
    /// orphaned files, folders and resume data were removed.
    @Test func anAbortWhileDeletingOrphanedMediaReportsWhatWasRemoved() async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        let orphan = "\(fixture.connectionID.uuidString)/li_gone/old.mp3"
        try write(orphan, fixture)
        let blobID = UUID()
        _ = try writeBlob(blobID, fixture)
        try age(fixture)
        try deleteConnection(fixture.connectionID, fixture)

        let report = await janitor(fixture, failing: .deletingOrphanedMedia).sweep()

        #expect(report.outcome == .aborted(.deletingOrphanedMedia))
        #expect(report.removedFiles == [orphan])
        #expect(report.removedFolders == ["\(fixture.connectionID.uuidString)/li_gone"])
        #expect(report.removedResumeData == [blobID])
        #expect(report.removedRecords.isEmpty)
        #expect(report.removedItems.isEmpty)
        #expect(try await fixture.store.record(id: setup.record.id) != nil)
        #expect(setup.referenced.allSatisfy { exists($0, fixture) })
    }

    /// An old empty folder goes even though the sweep didn't empty it; a recent one stays, as
    /// does an old one that holds a referenced path's folder.
    @Test func removesOldEmptyFoldersAndKeepsRecentOnes() async throws {
        let fixture = try await ManagerFixture()
        let setup = try await Setup(fixture)
        let connection = fixture.connectionID.uuidString
        let old = "\(connection)/li_empty/episodes/ep_1"
        let recent = "\(connection)/li_recent"
        let pending = try #require(setup.record.parts.first { $0.kind == .audio }).destinationRelativePath
        try FileManager.default.removeItem(at: fixture.locations.fileURL(forRelativePath: pending))
        for folder in [old, recent] {
            try FileManager.default.createDirectory(
                at: fixture.locations.downloadsRoot.appending(path: folder), withIntermediateDirectories: true)
        }
        try age(fixture)
        try setModified(recent, Self.now.addingTimeInterval(-60), fixture)

        let report = await janitor(fixture).sweep()

        #expect(report.outcome == .completed)
        #expect(
            report.removedFolders == [
                "\(connection)/li_empty/episodes/ep_1", "\(connection)/li_empty/episodes", "\(connection)/li_empty",
            ])
        #expect(!exists("\(connection)/li_empty", fixture))
        #expect(exists(recent, fixture))
        let pendingFolder = pending.split(separator: "/").dropLast().joined(separator: "/")
        #expect(exists(pendingFolder, fixture))
    }

    // MARK: - Helpers

    /// A downloaded book with its files on disk, and a podcast episode record with its
    /// destinations on disk.
    struct Setup {
        var book: LocalLibraryItemDTO
        var record: DownloadRecordDTO
        var referenced: [String]

        init(_ fixture: ManagerFixture) async throws {
            book = try await fixture.storeDownloaded(LibraryItemFixtures.book())
            let result = try await fixture.makeManager().enqueue(
                item: LibraryItemFixtures.podcast(), episodeID: "ep_1", connectionID: fixture.connectionID)
            guard case .started(let recordID) = result else { throw UnexpectedResult(result: result) }
            record = try #require(try await fixture.store.record(id: recordID))
            referenced =
                book.files.map(\.relativePath) + [book.coverRelativePath].compactMap { $0 }
                + record.parts.map(\.destinationRelativePath)
            for path in referenced { try write(path, fixture) }
        }
    }

    private func janitor(_ fixture: ManagerFixture, failing step: SweepReport.Step? = nil) -> DownloadJanitor {
        janitor(fixture) { if $0 == step { throw TestError() } }
    }

    private func janitor(
        _ fixture: ManagerFixture, manager: DownloadManager? = nil,
        beforeRead: @escaping @Sendable (SweepReport.Step) async throws -> Void
    ) -> DownloadJanitor {
        DownloadJanitor(
            manager: manager ?? fixture.makeManager(), connections: fixture.connections, storeLocation: .appGroup,
            now: { Self.now }, beforeRead: beforeRead)
    }

    /// Deletes a connection's row, leaving what refers to it, as a removal racing a download can.
    private func deleteConnection(_ id: UUID, _ fixture: ManagerFixture) throws {
        let context = ModelContext(fixture.container)
        try context.delete(model: ServerConnectionRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    private func writeBlob(_ partID: UUID, _ fixture: ManagerFixture) throws -> URL {
        try FileManager.default.createDirectory(at: fixture.locations.resumeDataRoot, withIntermediateDirectories: true)
        let url = fixture.locations.resumeDataRoot.appending(path: "\(partID.uuidString).bin")
        try Data("sealed".utf8).write(to: url)
        return url
    }

    /// Dates everything under the fixture's root an hour before ``now``.
    private func age(_ fixture: ManagerFixture) throws {
        let manager = FileManager.default
        for root in [fixture.locations.downloadsRoot, fixture.locations.resumeDataRoot]
        where manager.fileExists(atPath: root.path(percentEncoded: false)) {
            for case let url as URL in manager.enumerator(at: root, includingPropertiesForKeys: nil)! {
                try manager.setAttributes([.modificationDate: Self.old], ofItemAtPath: url.path(percentEncoded: false))
            }
        }
    }

    private func setModified(_ relativePath: String, _ date: Date, _ fixture: ManagerFixture) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: fixture.locations.fileURL(forRelativePath: relativePath).path(percentEncoded: false))
    }
}
