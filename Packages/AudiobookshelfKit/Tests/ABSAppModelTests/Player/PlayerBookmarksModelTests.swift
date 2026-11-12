import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

/// 14 November 2023, 22:13:20 UTC.
private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Runs `body` with a fake playback, a player over it and a bookmarks model over the player and a
/// store whose session uses `service`, with settings in a fresh suite.
@MainActor
private func withBookmarks(
    service: FakeBookmarkService = FakeBookmarkService(),
    _ body: @MainActor (PlayerBookmarksModel, FakePlaybackControl, BookmarkStore) async throws -> Void
) async throws {
    let suiteName = "ABSAppModelTests.PlayerBookmarks.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let playback = FakePlaybackControl()
    let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
    let store = try await makeBookmarkStore(service)
    try await body(PlayerBookmarksModel(player: player, store: store, now: { fixedDate }), playback, store)
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
            await #expect(throws: BookmarkStoreError.unavailable) { try await model.create(title: "", at: 5) }
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
            let locale = Locale(identifier: "en_US")
            let expected = fixedDate.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            #expect(model.defaultTitle(locale: locale) == expected)
            #expect(model.defaultTitle(locale: locale).contains("2023"))
        }
    }

    @Test func emptyTitleUsesDefault() async throws {
        let service = FakeBookmarkService()
        try await withBookmarks(service: service) { model, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            let locale = Locale(identifier: "en_US")
            var writes = service.writes.calls.makeAsyncIterator()

            let create = Task { try await model.create(title: "  \n", at: 42.8, locale: locale) }
            let write = try #require(await writes.next())
            #expect(write.request == .create(itemID: "li_book", time: 42, title: model.defaultTitle(locale: locale)))
            // Optimistic: the row is there before the server answers.
            #expect(model.rows.map(\.time) == [42])
            write.reply.resume(returning: nil)
            try await create.value

            let named = Task { try await model.create(title: " Twist ", at: 50, locale: locale) }
            let second = try #require(await writes.next())
            #expect(second.request == .create(itemID: "li_book", time: 50, title: "Twist"))
            second.reply.resume(returning: nil)
            try await named.value
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
            #expect(model.rows.map(\.time) == [7])
        }
    }
}
