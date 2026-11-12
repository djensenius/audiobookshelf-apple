import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Loads and writes that overlap, session changes and cancelled callers.
extension BookmarkStoreTests {
    // MARK: A load older than a finished write

    @Test func olderLoadDoesNotUndoCommittedCreate() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()
        var loads = service.loads.calls.makeAsyncIterator()

        let refresh = Task { try await store.refresh() }
        let load = try #require(await loads.next())
        let create = Task { try await store.create(itemID: "item", time: 30, title: "New") }
        try #require(await writes.next()).reply.resume(returning: nil)
        _ = try await create.value

        load.reply.resume(returning: [bookmark("other", 1)])
        try await refresh.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "New")])
        #expect(store.bookmarks(itemID: "other") == [bookmark("other", 1)])
    }

    @Test func olderLoadDoesNotRestoreCommittedDelete() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()
        var loads = service.loads.calls.makeAsyncIterator()

        let refresh = Task { try await store.refresh() }
        let load = try #require(await loads.next())
        let delete = Task { try await store.delete(existing) }
        try #require(await writes.next()).reply.resume(returning: nil)
        try await delete.value

        load.reply.resume(returning: [existing])
        try await refresh.value
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    @Test func loadStartedAfterCommitIsAuthoritative() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "New") }
        try #require(await writes.next()).reply.resume(returning: nil)
        _ = try await create.value
        store.replaceAll(from: bookmarkUser([]))

        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    // MARK: A load during a write

    @Test func seedDuringPendingRenameKeepsOptimisticWhileServerIsUnchanged() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old")
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let rename = Task { try await store.rename(existing, to: "New") }
        let write = try #require(await writes.next())
        store.replaceAll(from: bookmarkUser([existing]))
        #expect(store.bookmarks(itemID: "item").map(\.title) == ["New"])

        write.reply.resume(throwing: BookmarkTestError.rejected)
        await #expect(throws: BookmarkTestError.rejected) { try await rename.value }
        #expect(store.bookmarks(itemID: "item") == [existing])
    }

    @Test func seedDuringPendingRenameWithOtherTitleWins() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old")
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let rename = Task { try await store.rename(existing, to: "New") }
        let write = try #require(await writes.next())
        let other = bookmark("item", 30, "Other device")
        store.replaceAll(from: bookmarkUser([other]))
        #expect(store.bookmarks(itemID: "item") == [other])

        write.reply.resume(returning: nil)
        try await rename.value
        #expect(store.bookmarks(itemID: "item") == [other])
    }

    @Test func seedDuringPendingDeleteKeepsItDeletedWhileServerIsUnchanged() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        let write = try #require(await writes.next())
        store.replaceAll(from: bookmarkUser([existing]))
        #expect(store.bookmarks(itemID: "item").isEmpty)

        write.reply.resume(returning: nil)
        try await delete.value
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    @Test func seedDuringPendingDeleteWithRenamedEntryWins() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old")
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        let write = try #require(await writes.next())
        let renamed = bookmark("item", 30, "Renamed elsewhere")
        store.replaceAll(from: bookmarkUser([renamed]))
        #expect(store.bookmarks(itemID: "item") == [renamed])

        write.reply.resume(throwing: BookmarkTestError.rejected)
        await #expect(throws: BookmarkTestError.rejected) { try await delete.value }
        #expect(store.bookmarks(itemID: "item") == [renamed])
    }

    @Test func serverAppliedRenameStaysWhenReplyFails() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old")
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let rename = Task { try await store.rename(existing, to: "New") }
        let write = try #require(await writes.next())
        // The server saved it and sent `user_updated`, then the reply timed out.
        store.replaceAll(from: bookmarkUser([bookmark("item", 30, "New")]))
        write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await rename.value }
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "New")])
    }

    @Test func serverAppliedDeleteStaysWhenReplyFails() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30)
        store.replaceAll(from: bookmarkUser([existing, bookmark("item", 60)]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        let write = try #require(await writes.next())
        store.replaceAll(from: bookmarkUser([bookmark("item", 60), bookmark("item", 90)]))
        write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await delete.value }
        #expect(store.bookmarks(itemID: "item").map(\.time) == [60, 90])
    }

    // MARK: Other write paths

    @Test func renameOfMissingBookmarkThrowsNotFound() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)

        await #expect(throws: BookmarkStoreError.notFound) {
            try await store.rename(bookmark("item", 30, "Gone"), to: "New")
        }
        #expect(store.bookmarks(itemID: "item").isEmpty)
        #expect(service.peakWrites == 0)
    }

    @Test func savedCopyAtAnotherTimeReplacesOptimisticEntry() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30.5, title: "New") }
        let saved = bookmark("item", 30, "New", createdAt: 9)
        try #require(await writes.next()).reply.resume(returning: saved)
        #expect(try await create.value == saved)
        #expect(store.bookmarks(itemID: "item") == [saved])
    }

    @Test func deleteThenCreateAtSameTime() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old", createdAt: 1)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        let create = Task { try await store.create(itemID: "item", time: 30, title: "Again") }
        let deleteWrite = try #require(await writes.next())
        #expect(deleteWrite.request == .delete(itemID: "item", time: 30))
        deleteWrite.reply.resume(returning: nil)
        try await delete.value

        let createWrite = try #require(await writes.next())
        #expect(createWrite.request == .create(itemID: "item", time: 30, title: "Again"))
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "Again")])
        createWrite.reply.resume(returning: nil)
        _ = try await create.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "Again")])
    }

    @Test func cancelledCallerStillCompletesTheWrite() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "Kept") }
        let write = try #require(await writes.next())
        create.cancel()
        write.reply.resume(returning: nil)
        _ = try? await create.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "Kept")])

        let rename = Task { try await store.rename(bookmark("item", 30, "Kept"), to: "Next") }
        try #require(await writes.next()).reply.resume(returning: nil)
        try await rename.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "Next")])
    }

    // MARK: Session changes

    @Test func sessionEndDuringWriteThrowsCancellation() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "Mine") }
        let write = try #require(await writes.next())
        await store.sessionWillEnd(.switch)
        #expect(store.bookmarks(itemID: "item").isEmpty)

        write.reply.resume(throwing: BookmarkTestError.rejected)
        await #expect(throws: CancellationError.self) { try await create.value }
        #expect(store.bookmarks(itemID: "item").isEmpty)
        #expect(!store.hasLoaded)
    }

    @Test func newSessionWriteDoesNotWaitForOldSession() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let old = Task { try await store.create(itemID: "item", time: 1, title: "Old") }
        let oldWrite = try #require(await writes.next())
        await store.sessionWillEnd(.switch)
        await store.sessionDidStart(bookmarkContext(client: try makeClient()))

        let first = Task { try await store.create(itemID: "item", time: 2, title: "First") }
        let firstWrite = try #require(await writes.next())
        #expect(firstWrite.request == .create(itemID: "item", time: 2, title: "First"))
        oldWrite.reply.resume(returning: nil)
        await #expect(throws: CancellationError.self) { try await old.value }

        // The old write finishing must not detach the new session's tail.
        let second = Task { try await store.create(itemID: "item", time: 3, title: "Second") }
        for _ in 0..<10 { await Task.yield() }
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 2, "First")])
        firstWrite.reply.resume(returning: nil)
        _ = try await first.value
        try #require(await writes.next()).reply.resume(returning: nil)
        _ = try await second.value
        #expect(store.bookmarks(itemID: "item").map(\.time) == [2, 3])
    }

    @Test func hasLoadedTracksAppliedSeeds() async throws {
        let store = try await makeBookmarkStore(FakeBookmarkService())
        #expect(!store.hasLoaded)
        store.replaceAll(from: bookmarkUser([]))
        #expect(store.hasLoaded)
        store.clear()
        #expect(!store.hasLoaded)
        store.replaceAll(from: bookmarkUser([]))
        await store.sessionWillEnd(.signOut)
        #expect(!store.hasLoaded)
    }

    @Test func deleteOfBookmarkGoneOnServerSucceeds() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        try #require(await writes.next()).reply.resume(throwing: APIError.notFound)
        try await delete.value
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    // MARK: A create on a key an earlier write finished, during an older load

    /// Starts a refresh, deletes and commits the bookmark at 30 s, then starts a create there.
    private func createAfterCommittedDeleteDuringLoad(
        _ service: FakeBookmarkService, _ store: BookmarkStore
    ) async throws -> CreateDuringLoad {
        let existing = bookmark("item", 30, "Old", createdAt: 1)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()
        var loads = service.loads.calls.makeAsyncIterator()

        let refresh = Task { try await store.refresh() }
        let load = try #require(await loads.next())
        let delete = Task { try await store.delete(existing) }
        try #require(await writes.next()).reply.resume(returning: nil)
        try await delete.value
        let create = Task { try await store.create(itemID: "item", time: 30, title: "Again") }
        let createWrite = try #require(await writes.next())
        return CreateDuringLoad(load: load, refresh: refresh, write: createWrite, create: create)
    }

    @Test func failedCreateAfterCommittedDeleteDuringOlderLoadRollsBack() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let setup = try await createAfterCommittedDeleteDuringLoad(service, store)

        setup.load.reply.resume(returning: [])
        try await setup.refresh.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "Again")])
        setup.write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await setup.create.value }
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    @Test func createAfterCommittedDeleteDuringOlderLoadKeepsServerCopy() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let setup = try await createAfterCommittedDeleteDuringLoad(service, store)

        setup.load.reply.resume(returning: [])
        try await setup.refresh.value
        let saved = bookmark("item", 30, "Again", createdAt: 42)
        setup.write.reply.resume(returning: saved)

        #expect(try await setup.create.value == saved)
        #expect(store.bookmarks(itemID: "item") == [saved])
    }
}

private struct CreateDuringLoad {
    let load: GatedCalls<Int, [AudioBookmark]>.Call
    let refresh: Task<Void, any Error>
    let write: GatedCalls<BookmarkRequest, AudioBookmark?>.Call
    let create: Task<AudioBookmark, any Error>
}
