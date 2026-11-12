import ABSCore
import Foundation
import Observation

extension PlayerViewModel {
    /// Whether the current item can have bookmarks: there is one and it isn't a podcast episode
    /// (D11). The player's bookmarks button is hidden otherwise.
    public var supportsBookmarks: Bool { hasSession && !isPodcastEpisode }
}

/// The current item's bookmarks for the player's bookmarks sheet (port of `BookmarksModal.vue`):
/// joins the player's item and position with the account's ``BookmarkStore``.
///
/// - **Visibility (D11).** Only books have bookmarks: ``isVisible`` is `false` for podcast
///   episodes and without an item, and ``isEnabled`` is `false` while the store has no usable
///   connection (no client, or offline).
/// - **Order (D8).** ``rows`` are sorted by time, as ``BookmarkStore/bookmarks(itemID:)`` returns them.
/// - **Time (D10).** A new bookmark is at a whole second, ``creationTime``, and can't be created
///   where one already exists; edit that one instead.
/// - **Writes.** ``create(title:at:locale:)``, ``rename(_:to:)`` and ``delete(_:)`` go through the
///   store, which applies them at once and rolls them back if the server rejects them.
///
/// The model holds no state of its own, so a view can make one whenever it needs it.
@MainActor
@Observable
public final class PlayerBookmarksModel {
    @ObservationIgnored private let player: PlayerViewModel
    @ObservationIgnored private let store: BookmarkStore
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameter now: The clock for ``defaultTitle(locale:)``; tests pass a fixed date.
    public init(player: PlayerViewModel, store: BookmarkStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.player = player
        self.store = store
        self.now = now
    }

    /// Whether the player shows bookmarks: there is an item and it isn't a podcast episode.
    public var isVisible: Bool { player.supportsBookmarks }

    /// Whether bookmarks can be loaded and changed: the store has a client and isn't offline.
    public var isEnabled: Bool { store.isAvailable }

    /// The current item's bookmarks, by time; empty for a podcast episode or without an item.
    public var rows: [AudioBookmark] {
        guard let itemID else { return [] }
        return store.bookmarks(itemID: itemID)
    }

    public var hasBookmarks: Bool { !rows.isEmpty }

    /// The whole second a new bookmark goes at: the playback position rounded down. Reads the
    /// playback time, so read it only in a small leaf view.
    public var creationTime: Double {
        Self.wholeSecond(player.playback.currentTime)
    }

    /// Whether a bookmark can be created at ``creationTime``: bookmarks are enabled and visible,
    /// and none is at that second. Reads the playback time, like ``creationTime``.
    public var canCreate: Bool {
        guard isVisible, isEnabled else { return false }
        return !isBookmarked(at: creationTime)
    }

    /// The bookmark at the playback position's whole second, which the sheet highlights; `nil`
    /// when there is none. Reads the playback time, like ``creationTime``.
    public var currentBookmarkID: AudioBookmark.ID? {
        let time = creationTime
        return rows.first { $0.time == time }?.id
    }

    /// The title a bookmark gets when the user leaves it empty (D9): the date and time now, such as
    /// "Nov 12, 2026 at 9:41 AM" in `locale`.
    public func defaultTitle(locale: Locale) -> String {
        now().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// Seeks to the bookmark without changing play or pause, as legacy `clickBookmark`.
    public func select(_ bookmark: AudioBookmark) async {
        await player.playback.seek(to: bookmark.time)
    }

    /// Adds a bookmark to the current item at `time`, rounded down to a whole second (D10). An
    /// empty or blank `title` becomes ``defaultTitle(locale:)``.
    ///
    /// The sheet passes the ``creationTime`` read when its form opened, so playing on while the
    /// user types doesn't move the bookmark. Throws ``BookmarkStoreError/unavailable`` without an
    /// item that supports bookmarks, and whatever ``BookmarkStore/create(itemID:time:title:)`` throws.
    public func create(title: String, at time: Double, locale: Locale = .autoupdatingCurrent) async throws {
        guard let itemID else { throw BookmarkStoreError.unavailable }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? defaultTitle(locale: locale) : trimmed
        try await store.create(itemID: itemID, time: Self.wholeSecond(time), title: title)
    }

    /// Renames the bookmark; an empty or blank `title` keeps the current one and does nothing.
    /// Throws whatever ``BookmarkStore/rename(_:to:)`` throws.
    public func rename(_ bookmark: AudioBookmark, to title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await store.rename(bookmark, to: trimmed)
    }

    /// Deletes the bookmark. Throws whatever ``BookmarkStore/delete(_:)`` throws.
    public func delete(_ bookmark: AudioBookmark) async throws {
        try await store.delete(bookmark)
    }

    /// Loads the bookmarks the first time the sheet opens in a session (D13). A failure leaves the
    /// list as it is; the socket's `user_updated` fills it in later.
    public func onAppear() async {
        guard isEnabled, !store.hasLoaded, !store.isLoading else { return }
        try? await store.refresh()
    }

    // MARK: Private

    /// The item whose bookmarks to show; `nil` for a podcast episode or without an item.
    private var itemID: String? {
        guard isVisible else { return nil }
        return player.playback.mediaKey?.libraryItemId
    }

    private func isBookmarked(at time: Double) -> Bool {
        rows.contains { $0.time == time }
    }

    private static func wholeSecond(_ time: Double) -> Double {
        time.isFinite ? max(time, 0).rounded(.down) : 0
    }
}
