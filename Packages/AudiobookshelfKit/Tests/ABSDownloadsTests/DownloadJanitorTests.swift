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
        let context = ModelContext(fixture.container)
        let id = fixture.connectionID
        try context.delete(model: ServerConnectionRecord.self, where: #Predicate { $0.id == id })
        try context.save()

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
            now: { Self.now }
        ).sweep()

        #expect(report == SweepReport(outcome: .skipped(.notAppGroupStore)))
        #expect(exists(orphan, fixture))
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
        DownloadJanitor(
            manager: fixture.makeManager(), connections: fixture.connections, storeLocation: .appGroup,
            now: { Self.now },
            beforeRead: { if $0 == step { throw TestError() } })
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
