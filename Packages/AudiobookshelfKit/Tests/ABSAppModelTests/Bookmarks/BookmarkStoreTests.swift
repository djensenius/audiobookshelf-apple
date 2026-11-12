import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BookmarkStoreTests {
    @Test func seedSortsByTimeAndGroupsByItem() async throws {
        let store = try await makeBookmarkStore(FakeBookmarkService())
        store.replaceAll(
            from: bookmarkUser([bookmark("a", 90), bookmark("b", 5), bookmark("a", 10), bookmark("a", 45)]))

        #expect(store.bookmarks(itemID: "a").map(\.time) == [10, 45, 90])
        #expect(store.bookmarks(itemID: "b") == [bookmark("b", 5)])
        #expect(store.bookmarks(itemID: "none").isEmpty)
    }

    @Test func refreshLoadsTheListAndReportsLoading() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var loads = service.loads.calls.makeAsyncIterator()

        let refresh = Task { try await store.refresh() }
        let load = try #require(await loads.next())
        #expect(store.isLoading)
        #expect(!store.hasLoaded)
        load.reply.resume(returning: [bookmark("a", 20), bookmark("a", 3)])
        try await refresh.value

        #expect(!store.isLoading)
        #expect(store.hasLoaded)
        #expect(store.bookmarks(itemID: "a").map(\.time) == [3, 20])
    }

    @Test func createAppearsBeforeServerReplies() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "Chapter end") }
        let write = try #require(await writes.next())
        #expect(write.request == .create(itemID: "item", time: 30, title: "Chapter end"))
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "Chapter end")])

        let saved = bookmark("item", 30, "Chapter end", createdAt: 1_700)
        write.reply.resume(returning: saved)
        #expect(try await create.value == saved)
        #expect(store.bookmarks(itemID: "item") == [saved])
    }

    @Test func createFailureRollsBack() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        store.replaceAll(from: bookmarkUser([bookmark("item", 10)]))
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "New") }
        let write = try #require(await writes.next())
        #expect(store.bookmarks(itemID: "item").count == 2)
        write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await create.value }
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 10)])
    }

    @Test func createAtExistingTimeRenamesInPlace() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old", createdAt: 1_000)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "New") }
        let write = try #require(await writes.next())
        #expect(write.request == .create(itemID: "item", time: 30, title: "New"))
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "New", createdAt: 1_000)])

        write.reply.resume(returning: bookmark("item", 30, "New", createdAt: 1_000))
        _ = try await create.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "New", createdAt: 1_000)])
    }

    @Test func addRejectsTheTimeOfAQueuedAdd() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        store.replaceAll(from: bookmarkUser([]))
        var writes = service.writes.calls.makeAsyncIterator()

        let first = Task { try await store.add(itemID: "item", time: 30, title: "A") }
        let write = try #require(await writes.next())
        // Queued behind the first, so it sees the first's optimistic entry.
        let second = Task { try await store.add(itemID: "item", time: 30, title: "B") }
        for _ in 0..<10 { await Task.yield() }
        write.reply.resume(returning: nil)
        _ = try await first.value

        await #expect(throws: BookmarkStoreError.alreadyExists) { _ = try await second.value }
        #expect(service.sentWrites == 1)
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "A")])
    }

    @Test func renameFailureRestoresOldTitle() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30, "Old")
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let rename = Task { try await store.rename(existing, to: "New") }
        let write = try #require(await writes.next())
        #expect(write.request == .rename(itemID: "item", time: 30, title: "New"))
        #expect(store.bookmarks(itemID: "item").map(\.title) == ["New"])
        write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await rename.value }
        #expect(store.bookmarks(itemID: "item") == [existing])
    }

    @Test func deleteFailureRestoresBookmark() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        let write = try #require(await writes.next())
        #expect(write.request == .delete(itemID: "item", time: 30))
        #expect(store.bookmarks(itemID: "item").isEmpty)
        write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await delete.value }
        #expect(store.bookmarks(itemID: "item") == [existing])
    }

    @Test func deleteSuccessRemovesBookmark() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        let existing = bookmark("item", 30)
        store.replaceAll(from: bookmarkUser([existing]))
        var writes = service.writes.calls.makeAsyncIterator()

        let delete = Task { try await store.delete(existing) }
        try #require(await writes.next()).reply.resume(returning: nil)
        try await delete.value
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    @Test func rollbackSkippedWhenSocketReplacedEntry() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "Mine") }
        let write = try #require(await writes.next())
        // Another device saved a bookmark at the same time while the request was in flight.
        let other = bookmark("item", 30, "Other device", createdAt: 5)
        store.replaceAll(from: bookmarkUser([other]))
        #expect(store.bookmarks(itemID: "item") == [other])
        write.reply.resume(throwing: BookmarkTestError.rejected)

        await #expect(throws: BookmarkTestError.rejected) { try await create.value }
        #expect(store.bookmarks(itemID: "item") == [other])
    }

    @Test func writesOnSameItemRunInOrder() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "First") }
        let first = try #require(await writes.next())
        let rename = Task { try await store.rename(bookmark("item", 30, "First"), to: "Second") }
        for _ in 0..<10 { await Task.yield() }
        #expect(service.peakWrites == 1)

        first.reply.resume(returning: nil)
        _ = try await create.value
        // The rename starts from the state the create left behind.
        let second = try #require(await writes.next())
        #expect(second.request == .rename(itemID: "item", time: 30, title: "Second"))
        #expect(store.bookmarks(itemID: "item").map(\.title) == ["Second"])
        second.reply.resume(throwing: BookmarkTestError.rejected)
        await #expect(throws: BookmarkTestError.rejected) { try await rename.value }
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 30, "First")])
        #expect(service.peakWrites == 1)
    }

    @Test func writesOnOtherItemsDontWait() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let first = Task { try await store.create(itemID: "a", time: 1, title: "A") }
        let firstWrite = try #require(await writes.next())
        let second = Task { try await store.create(itemID: "b", time: 1, title: "B") }
        let secondWrite = try #require(await writes.next())

        #expect(secondWrite.request.itemID == "b")
        #expect(service.peakWrites == 2)
        firstWrite.reply.resume(returning: nil)
        secondWrite.reply.resume(returning: nil)
        _ = try await first.value
        _ = try await second.value
    }

    @Test func staleSeedDropped() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var loads = service.loads.calls.makeAsyncIterator()

        let older = Task { try await store.refresh() }
        let olderLoad = try #require(await loads.next())
        let newer = Task { try await store.refresh() }
        let newerLoad = try #require(await loads.next())
        #expect(olderLoad.request == 1 && newerLoad.request == 2)

        newerLoad.reply.resume(returning: [bookmark("item", 2, "Newer")])
        try await newer.value
        olderLoad.reply.resume(returning: [bookmark("item", 1, "Older")])
        try await older.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 2, "Newer")])

        // A socket update after a request was sent is newer than its response.
        let refresh = Task { try await store.refresh() }
        let load = try #require(await loads.next())
        store.replaceAll(from: bookmarkUser([bookmark("item", 3, "Socket")]))
        load.reply.resume(returning: [])
        try await refresh.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 3, "Socket")])
    }

    @Test func seedDuringPendingCreateKeepsOptimistic() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "Mine") }
        let write = try #require(await writes.next())
        // The server hasn't seen the create yet, so its list doesn't have it.
        store.replaceAll(from: bookmarkUser([bookmark("item", 5), bookmark("other", 1)]))
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 5), bookmark("item", 30, "Mine")])
        #expect(store.bookmarks(itemID: "other") == [bookmark("other", 1)])

        write.reply.resume(returning: nil)
        _ = try await create.value
        #expect(store.bookmarks(itemID: "item") == [bookmark("item", 5), bookmark("item", 30, "Mine")])
    }

    @Test func writeAfterSessionEndIsUnavailable() async throws {
        let store = try await makeBookmarkStore(FakeBookmarkService())
        await store.sessionWillEnd(.signOut)

        #expect(!store.isAvailable)
        await #expect(throws: BookmarkStoreError.unavailable) {
            try await store.create(itemID: "item", time: 30, title: "Late")
        }
        await #expect(throws: BookmarkStoreError.unavailable) { try await store.refresh() }
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }

    @Test func clearDropsInFlightCommit() async throws {
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        var writes = service.writes.calls.makeAsyncIterator()
        var loads = service.loads.calls.makeAsyncIterator()

        let create = Task { try await store.create(itemID: "item", time: 30, title: "Mine") }
        let write = try #require(await writes.next())
        let refresh = Task { try await store.refresh() }
        let load = try #require(await loads.next())
        store.clear()
        #expect(store.bookmarks(itemID: "item").isEmpty)

        write.reply.resume(returning: nil)
        await #expect(throws: CancellationError.self) { try await create.value }
        load.reply.resume(returning: [bookmark("item", 1)])
        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(store.bookmarks(itemID: "item").isEmpty)
        #expect(!store.hasLoaded)
    }

    @Test func offlineContextIsUnavailable() async throws {
        let store = BookmarkStore(makeService: { _ in FakeBookmarkService() })
        #expect(!store.isAvailable)

        await store.sessionDidStart(bookmarkContext(client: try makeClient(), isOffline: true))
        #expect(!store.isAvailable)
        await #expect(throws: BookmarkStoreError.unavailable) {
            try await store.create(itemID: "item", time: 30, title: "Offline")
        }

        await store.sessionDidReconnect(bookmarkContext(client: try makeClient()))
        #expect(store.isAvailable)
        await store.sessionDidReconnect(bookmarkContext(client: nil))
        #expect(!store.isAvailable)
    }

    @Test func newSessionStartsEmpty() async throws {
        let store = try await makeBookmarkStore(FakeBookmarkService())
        store.replaceAll(from: bookmarkUser([bookmark("item", 1)]))

        await store.sessionDidStart(bookmarkContext(client: try makeClient()))
        #expect(store.bookmarks(itemID: "item").isEmpty)
    }
}
