import ABSCore
import ABSData
import Foundation
import Observation

/// The Downloaded shelf on Home (#76), shown offline and online: the active connection's
/// downloaded items, as legacy `pages/bookshelf/index.vue` builds its Local Books and Local
/// Podcasts shelves.
///
/// - Only the observed connection's items are listed; another connection's downloads, even of
///   the same server, never appear.
/// - Only completed downloads are listed. A local item exists only once a download completed
///   (`LocalItemStore.upsertFromDownload`), so downloads under way never show; an item left
///   without audio or ebook files (its last episode deleted) is left out too.
/// - Podcasts are grouped: one entry per podcast, with its downloaded episodes inside it, like
///   legacy's Local Podcasts shelf.
/// - Both shelves are most recently downloaded first (the item's `addedAt`), then by title.
///   Legacy ordered books by local listening progress; that needs the progress store and is
///   left to the shelf's view.
/// - The shelves follow the store live (`LocalItemStore.updates(serverConnectionID:)`): a
///   finished download or a deletion shows without a reload.
@MainActor
@Observable
public final class DownloadedShelfModel {
    /// The connection's local items as the store reports them, most recently added first.
    public typealias Updates = @Sendable (_ connectionID: UUID) async throws -> AsyncStream<[LocalLibraryItemDTO]>

    /// Downloaded books, most recently downloaded first.
    public private(set) var books: [LocalLibraryItemDTO] = []
    /// Downloaded podcasts, one per podcast with its downloaded episodes, most recently first.
    public private(set) var podcasts: [LocalLibraryItemDTO] = []
    /// Whether the observed connection's items have been read at least once, or couldn't be
    /// (``loadError``).
    public private(set) var isLoaded = false
    /// Why the items couldn't be read, or `nil`. ``retry()`` reads them again.
    public private(set) var loadError: (any Error)?
    /// The connection whose items are shown, or `nil` when none is observed.
    public private(set) var connectionID: UUID?

    @ObservationIgnored private let updates: Updates
    /// Wakes the read waiting after a failure (``retry()``); its token tells waits apart.
    @ObservationIgnored private var retries: (token: UUID, continuation: AsyncStream<Void>.Continuation)?

    /// - Parameter updates: the store's live snapshots, usually
    ///   `{ try await localItems.updates(serverConnectionID: $0) }` on the `LocalItemStore` the
    ///   downloads write through.
    public init(updates: @escaping Updates) {
        self.updates = updates
    }

    /// Whether there is nothing to show once loaded.
    public var isEmpty: Bool { books.isEmpty && podcasts.isEmpty }

    /// Shows `connectionID`'s downloads and follows them until the calling task is cancelled
    /// (run it from the view's `.task(id:)`). `nil`, such as while signed out, clears the shelves.
    /// Snapshots for another connection that arrive after a switch are dropped. When the items
    /// can't be read, it sets ``loadError`` and waits for ``retry()`` to read them again.
    public func observe(connectionID: UUID?) async {
        if self.connectionID != connectionID {
            self.connectionID = connectionID
            apply([], for: connectionID)
            isLoaded = false
        }
        loadError = nil
        guard let connectionID, let stream = await read(connectionID) else { return }
        for await items in stream {
            guard !Task.isCancelled else { return }
            guard self.connectionID == connectionID else { continue }
            apply(items, for: connectionID)
            isLoaded = true
        }
    }

    /// Reads the observed connection's items again after they couldn't be, then follows them
    /// (Home's Retry and pull to refresh). Does nothing while they are read or followed.
    public func retry() {
        retries?.continuation.yield()
    }

    /// `connectionID`'s live items. A failed read sets ``loadError`` and loaded, so Home says so
    /// rather than loading forever, then waits for ``retry()``. `nil` once the calling task is
    /// cancelled or another connection is observed.
    private func read(_ connectionID: UUID) async -> AsyncStream<[LocalLibraryItemDTO]>? {
        while true {
            do {
                return try await updates(connectionID)
            } catch {
                guard self.connectionID == connectionID, !Task.isCancelled else { return nil }
                loadError = error
                isLoaded = true
                guard await retried(), self.connectionID == connectionID else { return nil }
                loadError = nil
                isLoaded = false
            }
        }
    }

    /// Waits for ``retry()``: `true` when it's called, `false` when the calling task is cancelled
    /// or a later wait replaces this one.
    private func retried() async -> Bool {
        let token = UUID()
        let (signals, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        retries?.continuation.finish()
        retries = (token, continuation)
        defer { if retries?.token == token { retries = nil } }
        var iterator = signals.makeAsyncIterator()
        return await iterator.next() != nil && !Task.isCancelled
    }

    private func apply(_ items: [LocalLibraryItemDTO], for connectionID: UUID?) {
        let shown = Self.shelf(items, connectionID: connectionID)
        if books != shown.books { books = shown.books }
        if podcasts != shown.podcasts { podcasts = shown.podcasts }
    }

    /// The shelves' contents: `connectionID`'s items with downloaded media, books and podcasts
    /// apart, most recently added first, then by title and ID.
    nonisolated static func shelf(
        _ items: [LocalLibraryItemDTO], connectionID: UUID?
    ) -> (books: [LocalLibraryItemDTO], podcasts: [LocalLibraryItemDTO]) {
        let shown =
            items
            .filter { $0.serverConnectionID == connectionID && !$0.files.isEmpty }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
            }
        return (shown.filter { $0.mediaType == .book }, shown.filter { $0.mediaType == .podcast })
    }
}
