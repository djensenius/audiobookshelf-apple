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

    /// A stored folder shallower than the item's own (here the connection's) holds other items
    /// too: only the item's files go.
    @Test func deletingAnItemWithAShallowFolderKeepsOtherItems() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let sibling = try await fixture.storeDownloaded(LibraryItemFixtures.podcast(), episodeID: "ep_1")
        var record = try DownloadPlanner(locations: fixture.locations).plan(
            item: LibraryItemFixtures.book(), episodeID: nil, connectionID: fixture.connectionID,
            existingCoverPath: nil)
        for index in record.parts.indices { record.parts[index].state = .completed }
        record.relativeDirectory = fixture.connectionID.uuidString
        let local = try await fixture.localItems.upsertFromDownload(record)
        for path in Self.paths(of: sibling) + Self.paths(of: local) { try write(path, fixture) }

        #expect(try await manager.deleteLocalItem(id: local.id))

        #expect(Self.paths(of: sibling).allSatisfy { exists($0, fixture) })
        #expect(Self.paths(of: local).allSatisfy { !exists($0, fixture) })
    }

    @Test func deletingAnUnknownEpisodeDoesNothing() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker()
        let manager = fixture.makeManager(progressLinking: linker)
        let local = try await fixture.storeDownloaded(LibraryItemFixtures.podcast(), episodeID: "ep_1")
        for path in Self.paths(of: local) { try write(path, fixture) }

        #expect(try await manager.deleteEpisode(itemID: local.id, episodeId: "ep_9") == false)

        #expect(try await fixture.localItems.item(id: local.id) == local)
        #expect(Self.paths(of: local).allSatisfy { exists($0, fixture) })
        #expect(linker.calls.isEmpty)
    }

    /// A book downloading again keeps its folder, and the files the new download replaces.
    @Test func deletingABookKeepsTheFilesOfItsPendingReplacement() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let local = try await fixture.storeDownloaded(item)
        for path in Self.paths(of: local) { try write(path, fixture) }
        _ = try await manager.enqueue(
            item: item, episodeID: nil, connectionID: fixture.connectionID, replacingExisting: true)

        #expect(try await manager.deleteLocalItem(id: local.id))

        #expect(try await fixture.localItems.item(id: local.id) == nil)
        #expect(Self.paths(of: local).allSatisfy { exists($0, fixture) })
        #expect(try await fixture.store.record(key: fixture.key(item)) != nil)
    }

    /// Current behaviour: an episode the engine is finalising can't take a cover part, so a
    /// cancelled episode's cover, with no other episode to go to, is removed.
    @Test func aRefusedHandOffRemovesTheCover() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.podcast()
        let connectionID = fixture.connectionID
        let first = try #require(
            try await fixture.store.record(
                id: Self.started(manager.enqueue(item: item, episodeID: "ep_1", connectionID: connectionID))))
        let second = try #require(
            try await fixture.store.record(
                id: Self.started(manager.enqueue(item: item, episodeID: "ep_2", connectionID: connectionID))))
        let cover = try #require(first.parts.last { $0.kind == .cover })
        try write(cover.destinationRelativePath, fixture)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)
        for part in second.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 1) }

        #expect(try await manager.cancel(recordID: first.id))

        #expect(try await fixture.store.record(id: second.id)?.parts.map(\.id) == second.parts.map(\.id))
        #expect(!exists(cover.destinationRelativePath, fixture))
    }

    /// A link or detach that fails is logged; the deletion and the completion stand.
    @Test func aFailingProgressLinkerUndoesNothing() async throws {
        let fixture = try await ManagerFixture()
        let linker = FakeProgressLinker(failing: true)
        let manager = fixture.makeManager(progressLinking: linker)
        try await manager.start()
        let events = await manager.events()
        let item = LibraryItemFixtures.book()
        let local = try await fixture.storeDownloaded(item)
        for path in Self.paths(of: local) { try write(path, fixture) }

        #expect(try await manager.deleteLocalItem(id: local.id))

        #expect(try await fixture.localItems.item(id: local.id) == nil)
        #expect(!exists(local.relativeDirectory, fixture))
        let again = try await fixture.storeDownloaded(item)
        let recordID = UUID()
        fixture.engine.updateContinuation.yield(.recordComplete(recordID: recordID, itemID: again.id))
        #expect(
            await events.next { _ in true } == .completed(recordID: recordID, itemID: again.id, key: fixture.key(item)))
        #expect(linker.calls == [.detachItem(local.id), .link(fixture.key(item), again.id)])
    }

    /// The engine finalises another episode while the last stored one is being deleted: the
    /// item went with that episode, in one transaction, so the new episode makes a new item and
    /// keeps its files.
    @Test func anEpisodeFinalisedDuringTheLastEpisodesDeletionIsKept() async throws {
        let fixture = try await ManagerFixture()
        let gate = StubGate()
        let (detaches, detach) = AsyncStream.makeStream(of: Void.self)
        let linker = FakeProgressLinker { call in
            guard case .detachKey = call else { return }
            detach.yield()
            await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
        }
        let manager = fixture.makeManager(progressLinking: linker)
        let item = LibraryItemFixtures.podcast()
        let local = try await fixture.storeDownloaded(item, episodeID: "ep_1")
        for path in Self.paths(of: local) { try write(path, fixture) }
        let second = try #require(
            try await fixture.store.record(
                id: Self.started(manager.enqueue(item: item, episodeID: "ep_2", connectionID: fixture.connectionID))))
        for part in second.parts {
            try write(part.destinationRelativePath, fixture)
            try await fixture.store.completePart(partID: part.id, finalBytes: 5)
        }
        await fixture.engine.settle(second.id)

        let deletion = Task { try await manager.deleteEpisode(itemID: local.id, episodeId: "ep_1") }
        _ = await detaches.first { _ in true }
        try await fixture.engine.finishSettling()
        gate.open()

        #expect(try await deletion.value)
        let kept = try #require(
            try await fixture.localItems.item(serverConnectionID: fixture.connectionID, libraryItemId: item.id))
        #expect(kept.files.map(\.episodeId) == ["ep_2"])
        #expect(second.parts.allSatisfy { exists($0.destinationRelativePath, fixture) })
        #expect(!exists(local.files[0].relativePath, fixture))
    }

    /// A replacement finalised while the deletion of the item it replaces reads what is still in
    /// use: its record, or else its new local item, keeps its files.
    @Test func aReplacementFinalisedDuringTheCleanUpKeepsItsFiles() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let item = LibraryItemFixtures.book()
        let local = try await fixture.storeDownloaded(item)
        for path in Self.paths(of: local) { try write(path, fixture) }
        let replacement = try #require(
            try await fixture.store.record(
                id: Self.started(
                    manager.enqueue(
                        item: item, episodeID: nil, connectionID: fixture.connectionID, replacingExisting: true))))
        for part in replacement.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 5) }
        await fixture.engine.settle(replacement.id)
        fixture.holdUsedPaths()

        let deletion = Task { try await manager.deleteLocalItem(id: local.id) }
        #expect(await fixture.checkpoints.first { $0 == .usedPathsReading } != nil)
        try await fixture.engine.finishSettling()
        fixture.releaseUsedPaths()

        #expect(try await deletion.value)
        let replaced = try #require(
            try await fixture.localItems.item(serverConnectionID: fixture.connectionID, libraryItemId: item.id))
        #expect(replaced.id != local.id)
        #expect(Self.paths(of: replaced).allSatisfy { exists($0, fixture) })
    }

    /// The server path of a deleted item's cover carries the item's `updatedAt` again; one out
    /// of range falls back to 0 instead of trapping.
    @Test(
        arguments: [
            (nil, 0),
            (Date(timeIntervalSince1970: Double(LibraryItemFixtures.updatedAt) / 1000), LibraryItemFixtures.updatedAt),
            (Date(timeIntervalSince1970: Double(Int.max) / 1000), 0),
        ] as [(Date?, Int)])
    func coverTimestamps(date: Date?, milliseconds: Int) {
        #expect(DownloadManager.coverTimestamp(date) == milliseconds)
    }

    @Test func deletingAnItemWithAnOutOfRangeCoverTime() async throws {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        let local = try await fixture.storeDownloaded(LibraryItemFixtures.book(updatedAt: .max))
        try #require(local.coverUpdatedAt != nil)

        #expect(try await manager.deleteLocalItem(id: local.id))

        #expect(try await fixture.localItems.item(id: local.id) == nil)
    }

    private static func started(_ result: DownloadManager.EnqueueResult) throws -> UUID {
        guard case .started(let id) = result else { throw UnexpectedResult(result: result) }
        return id
    }

    private static func paths(of item: LocalLibraryItemDTO) -> [String] {
        item.files.map(\.relativePath) + [item.coverRelativePath].compactMap { $0 }
    }
}
