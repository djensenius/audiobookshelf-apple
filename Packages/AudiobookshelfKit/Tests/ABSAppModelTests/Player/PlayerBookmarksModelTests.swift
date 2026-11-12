import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

/// 14 November 2023, 22:13:20 UTC.
private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Runs `body` with a fake playback, a player over it and a bookmarks model over the player and a
/// store whose session uses `service` and reads `isOffline`, with settings in a fresh suite.
@MainActor
private func withBookmarks(
    service: FakeBookmarkService = FakeBookmarkService(),
    isOffline: @escaping @MainActor () -> Bool = { false },
    _ body: @MainActor (PlayerBookmarksModel, FakePlaybackControl, BookmarkStore) async throws -> Void
) async throws {
    let suiteName = "ABSAppModelTests.PlayerBookmarks.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let playback = FakePlaybackControl()
    let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
    let store = BookmarkStore(makeService: { _ in service }, isOffline: isOffline)
    await store.sessionDidStart(bookmarkContext(client: try makeClient()))
    try await body(PlayerBookmarksModel(player: player, store: store, now: { fixedDate }), playback, store)
}

/// Answers every write `service` receives with the bookmark it sent, so a test that expects no
/// write fails on `sentWrites` instead of hanging if one is sent; cancel it at the end.
private func answeringWrites(_ service: FakeBookmarkService) -> Task<Void, Never> {
    Task {
        for await call in service.writes.calls {
            call.reply.resume(returning: nil)
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlayerBookmarksModelTests {
    @Test func visibleForLoadedBook() async throws {
        try await withBookmarks { model, playback, _ in
            #expect(!model.isVisible)
            playback.load(FakePlaybackControl.bookSession(), at: 10)
            #expect(model.isVisible)
            #expect(model.isEnabled)
        }
    }

    @Test func hiddenForPodcastEpisode() async throws {
        try await withBookmarks { model, playback, store in
            store.replaceAll(from: bookmarkUser([bookmark("li_pod", 5)]))
            playback.load(FakePlaybackControl.bookSession(item: "li_pod"), at: 5)
            playback.mediaKey = FakePlaybackControl.key(item: "li_pod", episode: "ep_1")

            #expect(!model.isVisible)
            #expect(model.rows.isEmpty)
            #expect(!model.hasBookmarks)
            #expect(!model.canCreate)
            await #expect(throws: BookmarkStoreError.unavailable) {
                try await model.create(title: "", itemID: "li_pod", at: 5)
            }
        }
    }

    @Test func disabledWithoutClient() async throws {
        try await withBookmarks { model, playback, store in
            playback.load(FakePlaybackControl.bookSession(), at: 10)
            await store.sessionDidStart(bookmarkContext(client: nil))
            #expect(model.isVisible)
            #expect(!model.isEnabled)
            #expect(!model.canCreate)

            await store.sessionDidStart(bookmarkContext(client: try makeClient(), isOffline: true))
            #expect(!model.isEnabled)

            await store.sessionDidReconnect(bookmarkContext(client: try makeClient()))
            #expect(model.isEnabled)
            #expect(!model.canCreate)
            store.replaceAll(from: bookmarkUser([]))
            #expect(model.canCreate)
        }
    }

    @Test func rowsForCurrentItemOnlySortedByTime() async throws {
        try await withBookmarks { model, playback, store in
            store.replaceAll(
                from: bookmarkUser([
                    bookmark("li_book", 300, "Late"), bookmark("other", 1), bookmark("li_book", 20, "Early"),
                ]))
            #expect(model.rows.isEmpty)

            playback.load(FakePlaybackControl.bookSession(), at: 0)
            #expect(model.rows.map(\.title) == ["Early", "Late"])
            #expect(model.hasBookmarks)
        }
    }

    @Test func rowsFollowItemChange() async throws {
        try await withBookmarks { model, playback, store in
            store.replaceAll(from: bookmarkUser([bookmark("li_book", 20), bookmark("li_other", 40)]))
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            #expect(model.rows.map(\.time) == [20])

            playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 0)
            #expect(model.rows.map(\.time) == [40])

            playback.stop(reason: .user)
            #expect(model.rows.isEmpty)
            #expect(!model.isVisible)
        }
    }

    @Test func creationTimeFloors() async throws {
        try await withBookmarks { model, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 30.99)
            #expect(model.creationTime == 30)
            playback.currentTime = 0.4
            #expect(model.creationTime == 0)
            playback.currentTime = .nan
            #expect(model.creationTime == 0)
        }
    }

    @Test func currentBookmarkIsAtTheWholeSecond() async throws {
        try await withBookmarks { model, playback, store in
            store.replaceAll(from: bookmarkUser([bookmark("li_book", 30), bookmark("li_book", 31)]))
            playback.load(FakePlaybackControl.bookSession(), at: 30.7)
            #expect(model.currentBookmarkID == bookmark("li_book", 30).id)

            playback.currentTime = 32
            #expect(model.currentBookmarkID == nil)
        }
    }

    @Test func canCreateFalseAtExistingSecond() async throws {
        try await withBookmarks { model, playback, store in
            store.replaceAll(from: bookmarkUser([bookmark("li_book", 30)]))
            playback.load(FakePlaybackControl.bookSession(), at: 30.6)
            #expect(!model.canCreate)

            playback.currentTime = 31.2
            #expect(model.canCreate)
        }
    }

    @Test func defaultTitleIsTheDateAndTimeNow() async throws {
        try await withBookmarks { model, _, _ in
            let utc = try #require(TimeZone(identifier: "UTC"))
            // ICU puts a narrow no-break space before "PM".
            #expect(
                model.defaultTitle(locale: Locale(identifier: "en_US"), timeZone: utc)
                    == "Nov 14, 2023 at 10:13\u{202F}PM")
        }
    }

    @Test func emptyTitleUsesDefault() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            let locale = Locale(identifier: "en_US")
            var writes = service.writes.calls.makeAsyncIterator()

            let create = Task { try await model.create(title: "  \n", itemID: "li_book", at: 42.8, locale: locale) }
            let write = try #require(await writes.next())
            #expect(write.request == .create(itemID: "li_book", time: 42, title: model.defaultTitle(locale: locale)))
            // Optimistic: the row is there before the server answers.
            #expect(model.rows.map(\.time) == [42])
            write.reply.resume(returning: nil)
            try await create.value

            let named = Task { try await model.create(title: " Twist ", itemID: "li_book", at: 50, locale: locale) }
            let second = try #require(await writes.next())
            #expect(second.request == .create(itemID: "li_book", time: 50, title: "Twist"))
            second.reply.resume(returning: nil)
            try await named.value

            // The placeholder the form showed is what an empty title saves.
            let shown = Task { try await model.create(title: "", itemID: "li_book", at: 60, defaultTitle: "Shown") }
            let third = try #require(await writes.next())
            #expect(third.request == .create(itemID: "li_book", time: 60, title: "Shown"))
            third.reply.resume(returning: nil)
            try await shown.value
        }
    }

    @Test func createRejectsItemChangedSinceFormOpened() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            store.replaceAll(from: bookmarkUser([]))
            playback.load(FakePlaybackControl.bookSession(), at: 30)
            // The form opens on the first book.
            let itemID = try #require(model.currentItemID)
            let time = model.creationTime
            #expect(itemID == "li_book")

            let responder = answeringWrites(service)
            defer { responder.cancel() }
            // Another window, CarPlay or the lock screen switches the book.
            playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 30)
            await #expect(throws: PlayerBookmarksError.itemChanged) {
                try await model.create(title: "Mine", itemID: itemID, at: time)
            }
            #expect(service.sentWrites == 0)
            #expect(store.bookmarks(itemID: "li_book").isEmpty)
            #expect(store.bookmarks(itemID: "li_other").isEmpty)
        }
    }

    @Test func createRejectsDuplicateArrivedWhileFormOpen() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            store.replaceAll(from: bookmarkUser([]))
            playback.load(FakePlaybackControl.bookSession(), at: 30.4)
            #expect(model.canCreate)
            let itemID = try #require(model.currentItemID)
            let time = model.creationTime

            let responder = answeringWrites(service)
            defer { responder.cancel() }
            // Another device's bookmark at the same second arrives while the user types.
            store.replaceAll(from: bookmarkUser([bookmark("li_book", 30, "Theirs")]))
            await #expect(throws: PlayerBookmarksError.alreadyBookmarked) {
                try await model.create(title: "Mine", itemID: itemID, at: time)
            }
            #expect(service.sentWrites == 0)
            #expect(model.rows.map(\.title) == ["Theirs"])
        }
    }

    @Test func cannotCreateDuringFirstLoad() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 30)
            #expect(!model.canCreate)
            var loads = service.loads.calls.makeAsyncIterator()

            let appear = Task { await model.onAppear() }
            let load = try #require(await loads.next())
            #expect(model.isFirstLoadInProgress)
            #expect(!model.canCreate)
            load.reply.resume(returning: [bookmark("li_book", 30)])
            await appear.value

            #expect(!model.isFirstLoadInProgress)
            // Loaded: a bookmark is at this second.
            #expect(!model.canCreate)
            playback.currentTime = 31
            #expect(model.canCreate)
        }
    }

    @Test func cannotCreateAfterFailedLoadUntilALoadSucceeds() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 30)
            var loads = service.loads.calls.makeAsyncIterator()

            let appear = Task { await model.onAppear() }
            try #require(await loads.next()).reply.resume(throwing: BookmarkTestError.rejected)
            await appear.value
            // Not loading any more, but the list is unknown: a server bookmark at 30 would look new.
            #expect(!model.isFirstLoadInProgress)
            #expect(!model.canCreate)

            // Reopening the sheet retries.
            let retry = Task { await model.onAppear() }
            try #require(await loads.next()).reply.resume(returning: [])
            await retry.value
            #expect(service.sentLoads == 2)
            #expect(model.canCreate)
        }
    }

    @Test func createRejectsDuplicateQueuedBehindAnotherWrite() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            let existing = bookmark("li_book", 10, "Old")
            store.replaceAll(from: bookmarkUser([existing]))
            playback.load(FakePlaybackControl.bookSession(), at: 30)
            var writes = service.writes.calls.makeAsyncIterator()

            // An earlier write holds the book's queue.
            let rename = Task { try await store.rename(existing, to: "Older") }
            let held = try #require(await writes.next())
            // Two windows submit at the same second; neither row is there yet, so both pass the
            // model's own check.
            let first = Task { try await model.create(title: "A", itemID: "li_book", at: 30) }
            for _ in 0..<10 { await Task.yield() }
            let second = Task { try await model.create(title: "B", itemID: "li_book", at: 30) }
            for _ in 0..<10 { await Task.yield() }
            #expect(model.rows.map(\.time) == [10])

            let responder = answeringWrites(service)
            defer { responder.cancel() }
            held.reply.resume(returning: nil)
            try await rename.value
            try await first.value
            await #expect(throws: PlayerBookmarksError.alreadyBookmarked) { try await second.value }
            #expect(service.sentWrites == 2)
            #expect(model.rows.map(\.title) == ["Older", "A"])
        }
    }

    @Test func createAndSelectUseMediaTimeAtAnyRate() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            store.replaceAll(from: bookmarkUser([]))
            playback.load(FakePlaybackControl.bookSession(), at: 120.7)
            playback.rate = 2
            #expect(model.creationTime == 120)
            var writes = service.writes.calls.makeAsyncIterator()

            let create = Task {
                try await model.create(title: "Fast", itemID: "li_book", at: model.creationTime)
            }
            let write = try #require(await writes.next())
            #expect(write.request == .create(itemID: "li_book", time: 120, title: "Fast"))
            write.reply.resume(returning: nil)
            try await create.value

            playback.clearCalls()
            await model.select(bookmark("li_book", 300))
            #expect(playback.calls == [.seek(300)])
        }
    }

    @Test func renameWithEmptyTitleIsNoOp() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            let existing = bookmark("li_book", 30, "Old")
            store.replaceAll(from: bookmarkUser([existing]))
            playback.load(FakePlaybackControl.bookSession(), at: 0)

            try await model.rename(existing, to: " ")
            #expect(service.sentWrites == 0)
            #expect(model.rows == [existing])

            var writes = service.writes.calls.makeAsyncIterator()
            let rename = Task { try await model.rename(existing, to: "New ") }
            let write = try #require(await writes.next())
            #expect(write.request == .rename(itemID: "li_book", time: 30, title: "New"))
            write.reply.resume(returning: nil)
            try await rename.value
            #expect(model.rows.map(\.title) == ["New"])
        }
    }

    @Test func deleteRemovesTheRow() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            let existing = bookmark("li_book", 30)
            store.replaceAll(from: bookmarkUser([existing]))
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            var writes = service.writes.calls.makeAsyncIterator()

            let delete = Task { try await model.delete(existing) }
            let write = try #require(await writes.next())
            #expect(write.request == .delete(itemID: "li_book", time: 30))
            #expect(model.rows.isEmpty)
            write.reply.resume(returning: nil)
            try await delete.value
            #expect(!model.hasBookmarks)
        }
    }

    @Test func deleteFailurePropagatesError() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            let existing = bookmark("li_book", 30)
            store.replaceAll(from: bookmarkUser([existing]))
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            var writes = service.writes.calls.makeAsyncIterator()

            let delete = Task { try await model.delete(existing) }
            try #require(await writes.next()).reply.resume(throwing: BookmarkTestError.rejected)
            await #expect(throws: BookmarkTestError.rejected) { try await delete.value }
            #expect(model.rows == [existing])
        }
    }

    @Test func selectSeeksOnly() async throws {
        try await withBookmarks { model, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 10)
            playback.clearCalls()

            await model.select(bookmark("li_book", 120))
            #expect(playback.calls == [.seek(120)])
            #expect(playback.currentTime == 120)
            #expect(!playback.isPlaybackRequested)
        }
    }

    @Test func onAppearLoadsOnce() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            var loads = service.loads.calls.makeAsyncIterator()

            let appear = Task { await model.onAppear() }
            try #require(await loads.next()).reply.resume(returning: [bookmark("li_book", 7)])
            await appear.value
            #expect(store.hasLoaded)
            #expect(model.rows.map(\.time) == [7])

            // Already loaded: no second request.
            await model.onAppear()
            #expect(service.sentLoads == 1)
            #expect(model.rows.map(\.time) == [7])
        }
    }

    @Test func onAppearDoesNothingWhenDisabled() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, store in
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            await store.sessionDidStart(bookmarkContext(client: nil))
            #expect(!model.isEnabled)

            await model.onAppear()
            #expect(service.sentLoads == 0)
            #expect(!store.hasLoaded)
        }
    }

    @Test func disabledWhenOfflineWithoutLifecycleNotice() async throws {
        let offline = Locked(false)
        try await withBookmarks(isOffline: { offline.value }) { model, playback, store in
            store.replaceAll(from: bookmarkUser([]))
            playback.load(FakePlaybackControl.bookSession(), at: 10)
            #expect(model.isEnabled)
            #expect(model.canCreate)

            // The gate goes offline with the same client: no participant call.
            offline.value = true
            #expect(!model.isEnabled)
            #expect(!model.canCreate)
            await #expect(throws: BookmarkStoreError.unavailable) {
                try await model.create(title: "", itemID: "li_book", at: 10)
            }

            offline.value = false
            #expect(model.isEnabled)
        }
    }
}
