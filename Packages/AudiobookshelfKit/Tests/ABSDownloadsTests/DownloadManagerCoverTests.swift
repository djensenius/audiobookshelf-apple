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
        LibraryItemFixtures.episode(id: "ep_3", ino: "303"), LibraryItemFixtures.episode(id: "ep_4", ino: "304"),
    ])

    /// Episode 1 holds the cover, still on its way; episode 2, planned without one, completed.
    /// Cancelling episode 1 can't hand the cover to anything, so a cover-only record fetches it
    /// again, and once it completes the local item has its cover.
    @Test func cancellingTheCoverHolderAfterTheOthersCompletedRefetchesTheCover() async throws {
        let linker = FakeProgressLinker()
        let (fixture, manager, events) = try await Self.started(progressLinking: linker)
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let cover = try #require(first.parts.last { $0.kind == .cover })

        #expect(try await manager.cancel(recordID: first.id))

        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        #expect(refetch.isCoverOnly)
        let part = try #require(refetch.parts.first)
        #expect(refetch.parts.count == 1)
        #expect(part.serverPath == cover.serverPath)
        // A file of its own, beside the cover it replaces.
        #expect(part.destinationRelativePath != cover.destinationRelativePath)
        #expect(Self.folder(part.destinationRelativePath) == Self.folder(cover.destinationRelativePath))
        #expect(part.state == .queued)
        #expect(refetch.media.coverUpdatedAt == first.media.coverUpdatedAt)
        #expect(await fixture.engine.started.last == [part.id])
        #expect(await events.next { $0 == .recordRemoved(recordID: first.id) } != nil)
        #expect(await events.next { $0 == .recordChanged(refetch) } != nil)

        try write(part.destinationRelativePath, fixture)
        try await Self.finalise(refetch, fixture)

        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        let restored = try #require(try await fixture.localItems.item(id: local.id))
        #expect(restored.coverRelativePath == part.destinationRelativePath)
        #expect(restored.coverUpdatedAt == first.media.coverUpdatedAt)
        #expect(restored.files == local.files)
        #expect(restored.media == local.media)
        #expect(exists(part.destinationRelativePath, fixture))
        #expect(try await fixture.store.allRecords().isEmpty)
        // Only episode 2 is linked: the refetch downloaded no media.
        #expect(linker.calls == [.link(fixture.key(Self.item, episodeID: "ep_2"), local.id)])
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

    /// While a refetch is paused, another refused cover resumes it instead of queueing a second
    /// one: hidden from the user, it would never be resumed otherwise.
    @Test func aPausedRefetchIsResumedNotDuplicated() async throws {
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
        #expect(records.first?.state == .queued)
        #expect(await fixture.engine.resumed == [refetch.id])
    }

    /// A refetch left failed (its drop failed) is resumed by the item's next episode
    /// completion, as nobody else can.
    @Test func aFailedRefetchIsResumedAtTheNextCompletion() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, _) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        let third = try await Self.enqueue("ep_3", fixture, manager)
        try #require(!third.parts.contains { $0.kind == .cover })
        // Failed in the store only: no `.partFailed`, so the manager doesn't drop it.
        _ = try await fixture.store.setState(.failed, forRecord: refetch.id)

        try write(third.parts[0].destinationRelativePath, fixture)
        try await Self.finalise(third, fixture)

        #expect(
            await events.next {
                if case .completed(third.id, _, _) = $0 { true } else { false }
            } != nil)
        let resumed = try #require(await Self.nextRecordChanged(events))
        #expect(resumed.id == refetch.id)
        #expect(await fixture.engine.resumed == [refetch.id])
        #expect(try await fixture.store.record(id: refetch.id)?.state == .queued)
    }

    /// A refetch left failed or paused is deleted once the local item has a cover without it:
    /// hidden, nothing would resume or remove it.
    @Test(arguments: [DownloadState.failed, .paused])
    func aStalledRefetchIsDroppedOnceTheItemHasACover(state: DownloadState) async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        let third = try await Self.enqueue("ep_3", fixture, manager)
        _ = try await fixture.store.setState(state, forRecord: refetch.id)
        _ = try await fixture.localItems.updateCover(itemID: local.id, relativePath: "elsewhere.jpg", updatedAt: nil)

        try write(third.parts[0].destinationRelativePath, fixture)
        try await Self.finalise(third, fixture)

        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(await fixture.engine.resumed.isEmpty)
        #expect(try await fixture.localItems.item(id: local.id)?.coverRelativePath == "elsewhere.jpg")
    }

    /// The item got a cover, at the usual path, while its refetch was on its way: the refetched
    /// file, of its own, doesn't replace it, and is removed once the refetch completes.
    @Test func aRefetchedCoverNeverReplacesOneTheItemGotMeanwhile() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        let episodeCover = Data("episode".utf8)
        try FileManager.default.createDirectory(
            at: fixture.locations.downloadsRoot.appending(path: Self.folder(cover.destinationRelativePath)),
            withIntermediateDirectories: true)
        try episodeCover.write(to: fixture.locations.downloadsRoot.appending(path: cover.destinationRelativePath))
        try #require(
            try await fixture.localItems.setCoverIfMissing(
                itemID: local.id, relativePath: cover.destinationRelativePath, updatedAt: nil))

        // The engine moves the refetched file into place, then finalises the record.
        try write(refetch.parts[0].destinationRelativePath, fixture)
        try await Self.finalise(refetch, fixture)

        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        await manager.holdingItem(fixture.key(Self.item)) {}
        #expect(
            try Data(contentsOf: fixture.locations.downloadsRoot.appending(path: cover.destinationRelativePath))
                == episodeCover)
        #expect(try await fixture.localItems.item(id: local.id)?.coverRelativePath == cover.destinationRelativePath)
        #expect(!exists(refetch.parts[0].destinationRelativePath, fixture))
    }

    /// A refetch the cover hand-off couldn't save, signed out, is kept and saved by the next
    /// completion after signing in, not dropped by one while still signed out.
    @Test func aCoverKeptWhileSignedOutIsFetchedAfterSigningIn() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, _) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        let third = try await Self.enqueue("ep_3", fixture, manager)
        let fourth = try await Self.enqueue("ep_4", fixture, manager)
        try #require(!(third.parts + fourth.parts).contains { $0.kind == .cover })
        // The refetch fails for good, so its cover is kept for the next completion.
        let part = try #require(refetch.parts.first)
        try await fixture.store.setPartState(.failed, partID: part.id, taskIdentifier: nil, error: "404")
        _ = try await fixture.store.setState(.failed, forRecord: refetch.id)
        fixture.engine.updateContinuation.yield(
            .partFailed(partID: part.id, recordID: refetch.id, code: .httpStatus, message: "404", willRetry: false))
        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        try Self.setSignedOut(true, fixture)

        try write(third.parts[0].destinationRelativePath, fixture)
        try await Self.finalise(third, fixture)
        _ = try await Self.completion(events, manager, fixture)
        #expect(try await fixture.store.record(key: fixture.key(Self.item)) == nil)

        try Self.setSignedOut(false, fixture)
        try write(fourth.parts[0].destinationRelativePath, fixture)
        try await Self.finalise(fourth, fixture)
        _ = try await Self.completion(events, manager, fixture)
        let again = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        #expect(again.isCoverOnly)
        #expect(again.parts.map(\.serverPath) == [part.serverPath])
    }

    /// A cancelled episode's fetched cover becomes the item's while its refetch is paused: the
    /// refetch, hidden and no longer needed, is deleted.
    @Test func aCoverHandedOffDropsAPausedRefetch() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        #expect(try await manager.pause(recordID: refetch.id))
        let third = try await Self.enqueue("ep_3", fixture, manager)
        let cover = try #require(third.parts.last { $0.kind == .cover })
        try write(cover.destinationRelativePath, fixture)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)

        #expect(try await manager.cancel(recordID: third.id))

        #expect(try await fixture.localItems.item(id: local.id)?.coverRelativePath == cover.destinationRelativePath)
        #expect(try await fixture.store.allRecords().isEmpty)
    }

    /// A refetch whose failure was saved before the process ended is dropped at start, its
    /// cover kept for the item's next completion.
    @Test func aRefetchFailedBeforeARelaunchIsDroppedAtStart() async throws {
        let fixture = try await ManagerFixture()
        let part = DownloadPartDTO(
            kind: .cover, serverPath: "/api/items/\(Self.item.id)/cover", filename: "cover.jpg", mimeType: "image/jpeg",
            expectedBytes: 0, bytesWritten: 0, destinationRelativePath: "show/cover-1.jpg", state: .failed)
        let record = try #require(
            try await fixture.store.insertRecordIfSignedIn(
                DownloadRecordDTO(
                    key: fixture.key(Self.item), mediaType: .podcast, title: "Show", relativeDirectory: "show",
                    media: LocalMediaSnapshot(metadata: .init(title: "Show")), parts: [part])))
        try #require(try await fixture.store.setState(.failed, forRecord: record.id))
        let manager = fixture.makeManager()

        try await manager.start()

        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(await manager.refusedCovers[fixture.key(Self.item)]?.serverPath == part.serverPath)
    }

    /// Nothing is fetched for a connection that was signed out or disconnected.
    @Test(arguments: [false, true])
    func nothingIsRefetchedAfterSignOut(disconnected: Bool) async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let context = ModelContext(fixture.container)
        let connection = try #require(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).first)
        if disconnected { connection.isDisconnected = true } else { connection.signedOutAt = .now }
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

    /// A refetch that fails for good is dropped, hidden as it is, and the item's next episode
    /// completion fetches the cover again in a fresh record.
    @Test func aRefetchThatFailsForGoodIsFetchedAgainAtTheNextCompletion() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, _) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        // Planned while the refetch is on its way: without a cover.
        let third = try await Self.enqueue("ep_3", fixture, manager)
        try #require(!third.parts.contains { $0.kind == .cover })
        let part = try #require(refetch.parts.first)
        try await fixture.store.setPartState(.failed, partID: part.id, taskIdentifier: nil, error: "404")
        _ = try await fixture.store.setState(.failed, forRecord: refetch.id)

        fixture.engine.updateContinuation.yield(
            .partFailed(partID: part.id, recordID: refetch.id, code: .httpStatus, message: "404", willRetry: false))

        let outcome = await events.next {
            switch $0 {
            case .recordRemoved(refetch.id), .failed: true
            default: false
            }
        }
        #expect(outcome == .recordRemoved(recordID: refetch.id))
        #expect(try await fixture.store.record(key: fixture.key(Self.item)) == nil)

        try write(third.parts[0].destinationRelativePath, fixture)
        try await Self.finalise(third, fixture)

        let again = try #require(await Self.nextRecordChanged(events))
        #expect(again.isCoverOnly)
        #expect(again.id != refetch.id)
        #expect(again.parts.map(\.serverPath) == [cover.serverPath])
        #expect(try await fixture.store.record(key: fixture.key(Self.item))?.id == again.id)
    }

    /// The engine finalised the last episode into a new local item between the hand-off's read
    /// of the local item and its read of the records: the hand-off reads the local item again
    /// and fetches the cover for it.
    @Test func aCoverRefusedWhileTheLastEpisodeIsFinalisedIsFetchedAgain() async throws {
        let (fixture, manager, events) = try await Self.started()
        let first = try await Self.enqueue("ep_1", fixture, manager)
        let second = try await Self.enqueue("ep_2", fixture, manager)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        for part in second.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 1) }
        try await fixture.engine.settle(second.id)
        fixture.holdCoverHandOff()

        let cancel = Task { try await manager.cancel(recordID: first.id) }
        #expect(await fixture.checkpoints.first { $0 == .coverHandOffReading } != nil)
        try await fixture.engine.finishSettling()
        fixture.releaseCoverHandOff()

        #expect(try await cancel.value)
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        #expect(refetch.isCoverOnly)
        #expect(refetch.parts.map(\.serverPath) == [cover.serverPath])
    }

    /// An episode completes into a podcast without a cover while the episode holding it is
    /// paused: the item's `cover.jpg`, still on disk, becomes its cover; without it, nothing is
    /// fetched, as the server may have no cover.
    @Test(arguments: [false, true])
    func aCompletionWithoutARefusedCover(coverOnDisk: Bool) async throws {
        let (fixture, manager, events) = try await Self.started()
        let first = try await Self.enqueue("ep_1", fixture, manager)
        let second = try await Self.enqueue("ep_2", fixture, manager)
        #expect(try await manager.pause(recordID: first.id))
        let path = try DownloadLayout(
            connectionID: fixture.connectionID, libraryItemID: Self.item.id, locations: fixture.locations
        ).coverPath()
        if coverOnDisk { try write(path, fixture) }
        let starts = await fixture.engine.started.count

        try await Self.finalise(second, fixture)

        let itemID = try await Self.completion(events, manager, fixture)
        let local = try #require(try await fixture.localItems.item(id: itemID))
        #expect(local.coverRelativePath == (coverOnDisk ? path : nil))
        #expect(try await fixture.store.allRecords().map(\.id) == [first.id])
        #expect(await fixture.engine.started.count == starts)
    }

    /// An episode completes into a podcast without a cover while the paused episode holding it
    /// has fetched it: the local item adopts that cover with the date its record had.
    @Test func aCompletedSiblingCoverIsAdoptedWithItsDate() async throws {
        let (fixture, manager, events) = try await Self.started()
        let first = try await Self.enqueue("ep_1", fixture, manager)
        let second = try await Self.enqueue("ep_2", fixture, manager)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        let coverDate = try #require(first.media.coverUpdatedAt)
        #expect(try await manager.pause(recordID: first.id))
        try write(cover.destinationRelativePath, fixture)
        try await fixture.store.completePart(partID: cover.id, finalBytes: 5)

        try await Self.finalise(second, fixture)

        let itemID = try await Self.completion(events, manager, fixture)
        let local = try #require(try await fixture.localItems.item(id: itemID))
        #expect(local.coverRelativePath == cover.destinationRelativePath)
        #expect(local.coverUpdatedAt == coverDate)
    }

    /// A deleted podcast's cover can't go to its last episode, being finalised: that episode's
    /// completion, into a new local item, fetches it again.
    @Test func aDeletedItemsCoverIsFetchedAgainAtTheNextCompletion() async throws {
        let (fixture, manager, events) = try await Self.started()
        let first = try await Self.enqueue("ep_1", fixture, manager)
        let second = try await Self.enqueue("ep_2", fixture, manager)
        let cover = try #require(first.parts.last { $0.kind == .cover })
        for part in first.parts { try write(part.destinationRelativePath, fixture) }
        try await Self.finalise(first, fixture)
        let itemID = try await Self.completion(events, manager, fixture)
        for part in second.parts { try await fixture.store.completePart(partID: part.id, finalBytes: 1) }
        try await fixture.engine.settle(second.id)

        #expect(try await manager.deleteLocalItem(id: itemID))
        #expect(!exists(cover.destinationRelativePath, fixture))
        try await fixture.engine.finishSettling()

        let refetch = try #require(await Self.nextRecordChanged(events))
        #expect(refetch.isCoverOnly)
        #expect(refetch.parts.map(\.serverPath) == [cover.serverPath])
    }

    /// A refetch discarded after its item was deleted gives its cover to a local item made since.
    @Test func aRefetchDiscardedAfterTheItemWasMadeAgain() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        let refetch = try #require(try await fixture.store.record(key: fixture.key(Self.item)))
        let path = try #require(refetch.parts.first?.destinationRelativePath)
        #expect(try await manager.deleteLocalItem(id: local.id))
        let third = try await Self.enqueue("ep_3", fixture, manager)
        for part in third.parts { try write(part.destinationRelativePath, fixture) }
        try await Self.finalise(third, fixture)
        let itemID = try await Self.completion(events, manager, fixture)
        var discarded = refetch
        discarded.parts[0].state = .completed
        try write(path, fixture)
        _ = try await fixture.store.deleteRecord(refetch.id)

        fixture.engine.updateContinuation.yield(.recordDiscarded(discarded))

        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        #expect(try await fixture.localItems.item(id: itemID)?.coverRelativePath == path)
        #expect(exists(path, fixture))
    }

    /// A book's local item never gets a cover-only record: a book record always plans its own.
    @Test func aBookIsNeverRefetched() async throws {
        let (fixture, manager, _) = try await Self.started()
        let book = LibraryItemFixtures.book()
        let local = try await fixture.storeDownloaded(book)
        _ = try await fixture.localItems.updateCover(itemID: local.id, relativePath: nil, updatedAt: nil)
        let result = try await manager.enqueue(
            item: book, episodeID: nil, connectionID: fixture.connectionID, replacingExisting: true)
        guard case .started(let id) = result else { throw UnexpectedResult(result: result) }

        #expect(try await manager.cancel(recordID: id))

        #expect(try await fixture.store.allRecords().isEmpty)
        #expect(try await fixture.localItems.item(id: local.id)?.coverRelativePath == nil)
    }

    /// Enqueueing a podcast without an episode isn't taken for its refetch, which shares the
    /// podcast's key: the planner refuses it.
    @Test func aPodcastWithoutAnEpisodeIsNotTheRefetch() async throws {
        let (fixture, manager, events) = try await Self.started()
        let (first, local) = try await Self.secondEpisodeCompleted(fixture, manager, events)
        #expect(try await manager.cancel(recordID: first.id))
        try #require(try await fixture.store.record(key: fixture.key(Self.item))?.isCoverOnly == true)
        // Without a local item, whose episodes would make it already downloaded.
        #expect(try await manager.deleteLocalItem(id: local.id))

        await #expect(throws: DownloadManagerError.episodeNotFound) {
            try await manager.enqueue(item: Self.item, episodeID: nil, connectionID: fixture.connectionID)
        }
    }

    // MARK: - Helpers

    private static func started(
        progressLinking: (any LocalProgressLinking)? = nil
    ) async throws -> (ManagerFixture, DownloadManager, AsyncStream<DownloadManagerEvent>) {
        let fixture = try await ManagerFixture()
        let manager = fixture.makeManager(progressLinking: progressLinking)
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
        let itemID = try await Self.completion(events, manager, fixture)
        let local = try #require(try await fixture.localItems.item(id: itemID))
        try #require(local.coverRelativePath == nil)
        return (first, local)
    }

    /// Waits for the next completion, then for the manager to release its item, as the cover
    /// is restored (``DownloadManager/restoreCover(after:itemID:)``) after `completed` is
    /// reported. Returns the completed local item's id.
    private static func completion(
        _ events: AsyncStream<DownloadManagerEvent>, _ manager: DownloadManager, _ fixture: ManagerFixture
    ) async throws -> UUID {
        guard
            case .completed(_, let itemID, _) = await events.next(where: {
                if case .completed = $0 { true } else { false }
            })
        else { throw UnexpectedEvent() }
        await manager.holdingItem(fixture.key(item)) {}
        return itemID
    }

    private static func folder(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Signs the connection out, or back in.
    private static func setSignedOut(_ signedOut: Bool, _ fixture: ManagerFixture) throws {
        let context = ModelContext(fixture.container)
        let connection = try #require(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).first)
        connection.signedOutAt = signedOut ? .now : nil
        try context.save()
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

    /// The next cover-only record reported changed: episode records' changes are skipped.
    private static func nextRecordChanged(_ events: AsyncStream<DownloadManagerEvent>) async -> DownloadRecordDTO? {
        guard
            case .recordChanged(let record) = await events.next(where: {
                if case .recordChanged(let record) = $0 { record.isCoverOnly } else { false }
            })
        else { return nil }
        return record
    }

    private struct UnexpectedEvent: Error {}
}
