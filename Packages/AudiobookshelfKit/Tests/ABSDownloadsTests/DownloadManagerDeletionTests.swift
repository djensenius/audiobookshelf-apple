import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``DownloadManager``'s deletion of downloaded items and podcast episodes, against a fake
/// engine: their files and folders go, progress is detached, and files or a cover that a
/// pending download uses stay.
@Suite(.timeLimit(.minutes(1))) struct DownloadManagerDeletionTests {
    @Test func deletingABookRemovesItsFolder() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        let local = try await fixture.storeDownloaded(LibraryItemFixtures.book())
        for path in Self.paths(of: local) { try write(path, fixture) }
        try write("\(local.relativeDirectory)/stray.tmp", fixture)

        #expect(try await manager.deleteLocalItem(id: local.id))

        #expect(try await fixture.localItems.item(id: local.id) == nil)
        #expect(!exists(local.relativeDirectory, fixture))
        #expect(!exists(fixture.connectionID.uuidString, fixture))
        #expect(FileManager.default.fileExists(atPath: fixture.locations.downloadsRoot.path(percentEncoded: false)))
        #expect(linker.calls == [.detachItem(local.id)])
        #expect(try await manager.deleteLocalItem(id: local.id) == false)
    }

    @Test func deletingAnEpisodeKeepsTheCoverAndTheOtherEpisodes() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        let item = LibraryItemFixtures.podcast()
        try await fixture.storeDownloaded(item, episodeID: "ep_1")
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_2")
        for path in Self.paths(of: local) { try write(path, fixture) }
        let first = try #require(local.files.first { $0.episodeId == "ep_1" }).relativePath
        let second = try #require(local.files.first { $0.episodeId == "ep_2" }).relativePath
        let cover = try #require(local.coverRelativePath)

        #expect(try await manager.deleteEpisode(itemID: local.id, episodeId: "ep_1"))

        #expect(try await fixture.localItems.item(id: local.id)?.files.map(\.relativePath) == [second])
        #expect(!exists(first, fixture))
        #expect(!exists(first.split(separator: "/").dropLast().joined(separator: "/"), fixture))
        #expect(exists(second, fixture))
        #expect(exists(cover, fixture))
        #expect(linker.calls == [.detachKey(fixture.key(item, episodeID: "ep_1"))])

        #expect(try await manager.deleteEpisode(itemID: local.id, episodeId: "ep_2"))

        #expect(try await fixture.localItems.item(id: local.id) == nil)
        #expect(!exists(local.relativeDirectory, fixture))
        #expect(
            linker.calls == [
                .detachKey(fixture.key(item, episodeID: "ep_1")), .detachKey(fixture.key(item, episodeID: "ep_2")),
                .detachItem(local.id),
            ])
    }

    /// An episode downloading again keeps its old file, which it will replace in place.
    @Test func deletingAnEpisodeKeepsAFileAPendingDownloadUses() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        try await fixture.storeDownloaded(item, episodeID: "ep_1")
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_2")
        for path in Self.paths(of: local) { try write(path, fixture) }
        _ = try await manager.enqueue(
            item: item, episodeID: "ep_1", connectionID: fixture.connectionID, replacingExisting: true)
        let first = try #require(local.files.first { $0.episodeId == "ep_1" }).relativePath

        #expect(try await manager.deleteEpisode(itemID: local.id, episodeId: "ep_1"))

        #expect(exists(first, fixture))
        #expect(try await fixture.localItems.item(id: local.id)?.files.count == 1)
    }

    /// The local item's cover was the only one: an episode still downloading gets it, as it
    /// is, and the cover file stays while the item's other files go.
    @Test func deletingAnItemHandsItsCoverToAPendingEpisode() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        let item = LibraryItemFixtures.podcast()
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_1")
        for path in Self.paths(of: local) { try write(path, fixture) }
        guard
            case .started(let recordID) = try await manager.enqueue(
                item: item, episodeID: "ep_2", connectionID: fixture.connectionID)
        else {
            Issue.record("Not started")
            return
        }
        let pending = try #require(try await fixture.store.record(id: recordID))
        try #require(!pending.parts.contains { $0.kind == .cover })
        let cover = try #require(local.coverRelativePath)

        #expect(try await manager.deleteLocalItem(id: local.id))

        let handed = try #require(try await fixture.store.record(id: recordID)?.parts.last)
        #expect(handed.kind == .cover)
        #expect(handed.destinationRelativePath == cover)
        #expect(handed.state == .completed)
        #expect(
            handed.serverPath
                == DownloadRequests.coverPath(itemID: item.id, updatedAt: LibraryItemFixtures.updatedAt))
        #expect(exists(cover, fixture))
        #expect(!exists(local.files[0].relativePath, fixture))
        #expect(await fixture.engine.started.count == 1)
        #expect(linker.calls == [.detachItem(local.id)])
    }

    private static func paths(of item: LocalLibraryItemDTO) -> [String] {
        item.files.map(\.relativePath) + [item.coverRelativePath].compactMap { $0 }
    }
}
