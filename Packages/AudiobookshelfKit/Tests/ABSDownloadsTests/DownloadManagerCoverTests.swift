import ABSAPI
import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData
@testable import ABSDownloads

/// A podcast cover that no record can take over (#326): the local item gets it back, from the
/// file still on disk or from a cover-only record that fetches it again, once and only while
/// signed in. Uses the fake engine, whose finalise is the store's.
@Suite(.timeLimit(.minutes(1))) struct DownloadManagerCoverTests {
    private static let item = LibraryItemFixtures.podcast(episodes: [
        LibraryItemFixtures.episode(id: "ep_1", ino: "301"), LibraryItemFixtures.episode(id: "ep_2", ino: "302"),
        LibraryItemFixtures.episode(id: "ep_3", ino: "303"),
    ])

    /// Episode 1 holds the cover, still on its way; episode 2, planned without one, completed.
    /// Cancelling episode 1 can't hand the cover to anything, so a cover-only record fetches it
    /// again, and once it completes the local item has its cover.
    @Test func cancellingTheCoverHolderAfterTheOthersCompletedRefetchesTheCover() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let cover = try #require(first.parts.last { $0.kind == .cover })

        #expect(try await manager.cancel(recordID: first.id))

        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        #expect(refetch.isCoverOnly)
        let part = try #require(refetch.parts.first)
        #expect(refetch.parts.count == 1)
        #expect(part.serverPath == cover.serverPath)
        #expect(part.destinationRelativePath == cover.destinationRelativePath)
        #expect(part.state == .queued)
        #expect(refetch.media.coverUpdatedAt == first.media.coverUpdatedAt)
        #expect(await fixture.engine.started.last == [part.id])
        #expect(await events.next { _ in true } == .recordRemoved(recordID: first.id))
        #expect(await events.next { _ in true } == .recordChanged(refetch))

        try write(part.destinationRelativePath, fixture)
        try await Self.finalise(refetch, fixture)

        #expect(await events.next { _ in true } == .recordRemoved(recordID: refetch.id))
        let restored = try #require(try await fixture.localItems.item(id: local.id))
        #expect(restored.coverRelativePath == cover.destinationRelativePath)
        #expect(restored.coverUpdatedAt == first.media.coverUpdatedAt)
        #expect(restored.files == local.files)
        #expect(restored.media == local.media)
        #expect(exists(cover.destinationRelativePath, fixture))
        #expect(try await fixture.store.allRecords().isEmpty)
    }

    /// A cover the cancelled record had already fetched becomes the local item's, as it is: the
    /// file stays and nothing is fetched.
    @Test func aFetchedCoverNobodyTakesBecomesTheLocalItemsCover() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        try write(cover.destinationRelativePath, fixture)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)
        let starts = await fixture.engine.started.count

        #expect(try await manager.cancel(recordID: first.id))

        let restored = try #require(try await fixture.localItems.item(id: local.id))
        #expect(restored.coverRelativePath == cover.destinationRelativePath)
        #expect(restored.coverUpdatedAt == first.media.coverUpdatedAt)
        #expect(exists(cover.destinationRelativePath, fixture))
        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(await fixture.engine.started.count == starts)
    }

    /// The local item didn't exist yet when the cover was refused: episode 2 had completed and
    /// was being finalised. The cover is fetched again once episode 2's completion arrives.
    @Test func aCoverRefusedBeforeTheLocalItemExistedIsFetchedAtTheNextCompletion() async throws {
        let (fixture, manager, events) = try await Self.started()
        let first = try await Self.enqueue("ep_1", fixture, manager)
        let second = try await Self.enqueue("ep_2", fixture, manager)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        try write(cover.destinationRelativePath, fixture)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)
        for part in second.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 1) }
        try await fixture.engine.settle(second.id)

        #expect(try await manager.cancel(recordID: first.id))
        #expect(!exists(cover.destinationRelativePath, fixture))
        try await fixture.engine.finishSettling()

        #expect(await events.next { if case .completed = $0 { true } else { false } } != nil)
        let refetch = try #require(await Self.nextRecordChanged(events))
        #expect(refetch.isCoverOnly)
        #expect(refetch.key == fixture.key(Self.item))
        #expect(refetch.parts.map(\.serverPath) == [cover.serverPath])
    }

    /// A cover-only record that is cancelled isn't fetched once more.
    @Test func cancellingTheRefetchDoesNotRefetchAgain() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))

        #expect(try await manager.cancel(recordID: refetch.id))

        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(try await fixture.localItems.item(id: local.id)?.coverRelativePath == nil)
    }

    /// While a refetch is paused, another refused cover doesn't queue a second one.
    @Test func aPausedRefetchIsNotDuplicated() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, _) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        #expect(try await manager.pause(recordID: refetch.id))
        // Paused, the refetch doesn't count as the item's cover on its way: episode 3 plans one.
        let third = try await Self.enqueue("ep_3", fixture, manager)
        try #require(third.parts.contains { $0.kind == .cover })

        #expect(try await manager.cancel(recordID: third.id))

        let records = try await fixture.store.allRecords()
        #expect(records.map(\.id) == [refetch.id])
        #expect(records.first?.state == .paused)
    }

    /// Nothing is fetched for a connection that was signed out.
    @Test func nothingIsRefetchedAfterSignOut() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let context = ModelContext(fixture.container)
        let connection = try #require(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).first)
        connection.signedOutAt = .now
        try context.save()

        #expect(try await manager.cancel(recordID: first.id))

        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(try await fixture.localItems.item(id: local.id)?.coverRelativePath == nil)
    }

    /// The local item was deleted while its cover was fetched again: once the engine discards
    /// the refetch, its cover goes to an episode queued since, completed, or else is removed.
    @Test(arguments: [false, true])
    func aRefetchDiscardedAfterTheItemWasDeleted(episodeQueued: Bool) async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        let path = try #require(refetch.parts.first?.destinationRelativePath)
        #expect(try await manager.deleteLocalItem(id: local.id))
        let queued = episodeQueued ? try await Self.enqueue("ep_3", fixture, manager) : nil
        try #require(queued?.parts.contains { $0.kind == .cover } != true)
        var discarded = refetch
        discarded.parts[0].state = .completed
        discarded.parts[0].bytesWritten = 5
        try write(path, fixture)
        _ = try await fixture.store.deleteRecord(refetch.id)

        fixture.engine.updateContinuation.yield(.recordDiscarded(discarded))

        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        if let queued {
            let handed = try #require(try await fixture.store.record(id: queued.id)?.parts.last)
            #expect(handed.kind == .cover)
            #expect(handed.state == .completed)
            #expect(handed.destinationRelativePath == path)
            #expect(exists(path, fixture))
        } else {
            #expect(!exists(path, fixture))
            #expect(!exists(local.relativeDirectory, fixture))
        }
    }

    // MARK: - Helpers

    private static func started() async throws -> (ManagerFixture, DownloadManager, AsyncStream<DownloadManagerEvent>) {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager()
        try await manager.start()
        return (fixture, manager, await manager.events())
    }

    /// Episode 1 holds the item's cover, still on its way; episode 2, planned without a cover,
    /// completed into the local item. Returns episode 1's record and the local item.
    private static func secondEpisodeCompleted(
        _ fixture: ManagerFixture, _ manager: DownloadManager, _ events: AsyncStream<DownloadManagerEvent>
    ) async throws -> (DownloadRecordDTO, LocalLibraryItemDTO) {
        let first = try await enqueue("ep_1", fixture, manager)
        let second = try await enqueue("ep_2", fixture, manager)
        try #require(first.parts.contains { $0.kind == .cover } && !second.parts.contains { $0.kind == .cover })
        for part in second.parts { try write(part.destinationRelativePath, fixture) }
        try await finalise(second, fixture)
        guard
            case .completed(_, let itemID, _) = await events.next(where: {
                if case .completed = $0 { true } else { false }
            })
        else { throw UnexpectedEvent() }
        let local = try #require(try await fixture.localItems.item(id: itemID))
        try #require(local.coverRelativePath == nil)
        return (first, local)
    }

    /// Completes every part of `record`, then finalises it as the engine does.
    private static func finalise(_ record: DownloadRecordDTO, _ fixture: ManagerFixture) async throws {
        for part in record.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 5) }
        try await fixture.engine.settle(record.id)
        try await fixture.engine.finishSettling()
    }

    private static func enqueue(
        _ episodeID: String, _ fixture: ManagerFixture, _ manager: DownloadManager
    ) async throws -> DownloadRecordDTO {
        let result = try await manager.enqueue(item: item, episodeID: episodeID, connectionID: fixture.connectionID)
        guard case .started(let id) = result else { throw UnexpectedResult(result: result) }
        return try #require(try await fixture.store.record(id: id))
    }

    private static func nextRecordChanged(_ events: AsyncStream<DownloadManagerEvent>) async -> DownloadRecordDTO? {
        guard
            case .recordChanged(let record) = await events.next(where: {
                if case .recordChanged = $0 { true } else { false }
            })
        else { return nil }
        return record
    }

    private struct UnexpectedEvent: Error {}
}
