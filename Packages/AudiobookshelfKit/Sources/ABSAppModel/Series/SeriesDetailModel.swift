import ABSAPI
import ABSCore
import Foundation
import Observation
import os

/// A book (or, with `collapseseries`, a collapsed sub-series) of a series, with its sequence.
public struct SeriesBook: Sendable, Hashable, Identifiable {
    public let summary: ItemSummary
    /// The sequence in this series as the server sent it, for example `1`, `1.5` or `Prequel`.
    public let sequence: String?

    public var id: String { summary.id }

    public init(summary: ItemSummary, sequence: String?) {
        self.summary = summary
        self.sequence = sequence
    }

    /// Maps `item`, taking its sequence in the series `seriesID`: a collapsed sub-series' own
    /// sequence, else the list context's `series` when it is `seriesID`, else the book's metadata
    /// series with that ID, else `nil`.
    public init(item: LibraryItem, seriesID: String) {
        let sequence: String?
        if let collapsed = item.collapsedSeries {
            sequence = collapsed.sequence
        } else if let series = item.series, series.id == seriesID {
            sequence = series.sequence
        } else if case .book(let book) = item.media,
            let series = book.metadata.series?.first(where: { $0.id == seriesID })
        {
            sequence = series.sequence
        } else {
            sequence = nil
        }
        self.init(summary: ItemSummary(item: item), sequence: sequence)
    }
}

/// A loaded series: its metadata, the user's aggregate progress, and its books in server order.
public struct SeriesDetail: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// `nil` when blank.
    public let description: String?
    /// The user's aggregate progress from the server; `nil` when it sent none.
    public let progress: SeriesProgress?
    /// In the order the server sent them; see ``SeriesDetailModel``.
    public let books: [SeriesBook]
    /// The series' own library, when the server names it: its books load from there.
    public let libraryID: String?

    public init(response: SeriesDetailResponse, items: [LibraryItem]) {
        id = response.series.id
        name = response.series.name
        description = response.series.description.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        progress = response.progress
        let seriesID = response.series.id
        books = items.map { SeriesBook(item: $0, seriesID: seriesID) }
        libraryID = response.series.libraryId
    }
}

/// The series screen; a port of the legacy `pages/bookshelf/series/_id.vue`.
///
/// Loads `GET /api/series/:id?include=progress`, then the series' books from the library items
/// endpoint with the `series.<id>` filter (and `collapseseries=1` when ``collapseSeries``). The
/// books come from the series' own library when the server names it, else from ``libraryID``.
///
/// - The books keep the server's order, as in the legacy `LazyBookshelf.vue` (`series-books`),
///   which sends no sort and doesn't sort either. With no `sort`, the server orders a series
///   filter by `CAST(sequence AS FLOAT) ASC NULLS LAST`
///   (`libraryItemsBookFilters.getFilteredLibraryItems`), and with `collapseseries=1`
///   `libraryHelpers.handleCollapseSubseries` natural-sorts by sequence, falling back to the
///   title or collapsed series' name. Re-sorting here would diverge from both (`3a`, `1-3`).
/// - The books load in one request without `limit`, for which the server returns every book; a
///   series is small. If the server reports more books than it sent, a warning is logged.
/// - Loading keeps the last series while reloading and after a failed reload. When loads
///   overlap, only the last one started is applied. A 404 (``APIError/notFound``) from the
///   series request drops the series and ``phase`` becomes ``Phase/notFound`` for the view to
///   pop. A 404 from the books request (for example a wrong fallback library) doesn't mean the
///   series is gone, so it is an ordinary failure.
/// - ``continueBook`` is read from the ``ProgressCache`` on every access, so views showing it
///   update when the user's progress changes.
///
/// A model belongs to one series, client and account: views recreate it per series ID and under
/// the session's `.id(identity)` (ADR 0004), so a server or user switch never reuses it.
@MainActor
@Observable
public final class SeriesDetailModel {
    public enum Phase: Sendable, Hashable {
        /// Not loaded yet, and no load running.
        case idle
        /// The first load is running.
        case loading
        /// ``SeriesDetailModel/detail`` is set; a reload may be running or may have failed.
        case loaded
        /// The last load failed and nothing was loaded before; see ``SeriesDetailModel/error``.
        case failed
        /// The server answered 404.
        case notFound
    }

    public let seriesID: String
    public let libraryID: String
    /// Sends `collapseseries=1`, so sub-series show as one entry (the legacy
    /// `collapseBookSeries` setting); change it with ``setCollapseSeries(_:)``.
    public private(set) var collapseSeries: Bool

    /// The last loaded series; kept while reloading and after a failed reload, dropped on 404.
    public private(set) var detail: SeriesDetail?
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?
    /// A series request answered 404 and no load has succeeded since.
    public private(set) var isNotFound = false

    @ObservationIgnored private let service: any SeriesAuthorsService
    @ObservationIgnored private let cache: ProgressCache
    @ObservationIgnored private var sequence = 0

    public init(
        seriesID: String, libraryID: String, collapseSeries: Bool = false, service: any SeriesAuthorsService,
        cache: ProgressCache
    ) {
        self.seriesID = seriesID
        self.libraryID = libraryID
        self.collapseSeries = collapseSeries
        self.service = service
        self.cache = cache
    }

    public var phase: Phase {
        if isNotFound { return .notFound }
        if detail != nil { return .loaded }
        if isLoading { return .loading }
        return error == nil ? .idle : .failed
    }

    public var hasLoaded: Bool { detail != nil }

    /// The library the loaded books are in: the series' own when the server names it, else ``libraryID``. Actions
    /// on a book, such as adding it to a playlist, belong there, not in the library the screen was opened in.
    public var booksLibraryID: String { detail?.libraryID ?? libraryID }

    /// The books query: the series filter, no sort (the server's sequence order) and no paging.
    public var booksQuery: LibraryQuery {
        LibraryQuery(filter: .series(id: seriesID), collapseSeries: collapseSeries)
    }

    /// Changes ``collapseSeries``. When it changed and the series has loaded or is loading, loads
    /// again with the new query (a load still running with the old one is then dropped).
    public func setCollapseSeries(_ collapse: Bool) async {
        guard collapse != collapseSeries else { return }
        collapseSeries = collapse
        guard hasLoaded || isLoading else { return }
        await load()
    }

    /// Loads unless the series has already loaded. Views call it each time they appear, so a
    /// load cancelled before it finished runs again.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Loads the series and its books. A response to an older call that arrives after a newer
    /// one started is dropped.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<SeriesDetail, any Error>
        var seriesNotFound = false
        do {
            let response: SeriesDetailResponse
            do {
                response = try await service.seriesDetail(id: seriesID)
            } catch {
                seriesNotFound = error as? APIError == .notFound
                throw error
            }
            let libraryID = response.series.libraryId ?? libraryID
            let page = try await service.filteredBooksPage(libraryID: libraryID, query: booksQuery)
            if let total = page.total, total > page.rawCount {
                Log.api.warning(
                    "Series books: the server sent \(page.rawCount, privacy: .public) of \(total, privacy: .public)")
            }
            result = .success(SeriesDetail(response: response, items: page.results))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let loaded):
            detail = loaded
            error = nil
            isNotFound = false
        case .failure(let error):
            if error is CancellationError { return }
            self.error = error
            if seriesNotFound {
                isNotFound = true
                detail = nil
            }
        }
    }

    /// The user's progress on `book`, if any.
    public func progress(of book: SeriesBook) -> MediaProgress? {
        cache.progress(libraryItemID: book.summary.itemID)
    }

    /// Where "continue series" goes: the playable book in progress (started and not finished),
    /// the one listened to last when there are several (ties keep list order); else the first
    /// playable book in list order that isn't finished; `nil` when there is none. Playable means a
    /// book (not a collapsed sub-series) that isn't missing and has audio, like the group screens'
    /// play targets. Progress is read from the ``ProgressCache`` alone, so a book whose progress
    /// was removed counts as not started.
    public var continueBook: SeriesBook? {
        let playable = (detail?.books ?? []).filter { book in
            let summary = book.summary
            return summary.kind == .book && !summary.isMissing && summary.hasAudio
        }
        let inProgress = playable.compactMap { book -> (book: SeriesBook, lastUpdate: Int)? in
            guard let progress = progress(of: book), ItemProgress(progress).isInProgress else { return nil }
            return (book, progress.lastUpdate ?? 0)
        }
        if let latest = inProgress.max(by: { $0.lastUpdate < $1.lastUpdate }) { return latest.book }
        return playable.first { !(progress(of: $0)?.isFinished ?? false) }
    }
}
