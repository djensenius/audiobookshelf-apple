import ABSAPI
import ABSCore
import Foundation
import Observation

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
    /// sequence, else the list context's `series`, else the book's matching metadata series.
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
            sequence = item.series?.sequence
        }
        self.init(summary: ItemSummary(item: item), sequence: sequence)
    }
}

/// Series sequence ordering.
public enum SeriesSequence {
    /// Orders `a` before `b`, after or the same: numeric sequences (`1`, `1.5`, `10`) by value
    /// first, then other sequences by `localizedStandardCompare`, then missing or blank ones.
    public static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (normalized(a), normalized(b)) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let a?, let b?):
            switch (number(a), number(b)) {
            case (let x?, let y?): return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return a.localizedStandardCompare(b)
            }
        }
    }

    /// `books` in sequence order; books comparing the same keep their order.
    public static func sorted(_ books: [SeriesBook]) -> [SeriesBook] {
        books.enumerated().sorted { lhs, rhs in
            switch compare(lhs.element.sequence, rhs.element.sequence) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func normalized(_ sequence: String?) -> String? {
        guard let trimmed = sequence?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The value of a plain decimal such as `2`, `-1` or `1.5`; `nil` for anything else, so
    /// `1e3`, `inf` or `0x10` sort as text.
    private static func number(_ sequence: String) -> Double? {
        guard sequence.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        return Double(sequence)
    }
}

/// A loaded series: its metadata, the user's aggregate progress, and its books in sequence order.
public struct SeriesDetail: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// `nil` when blank.
    public let description: String?
    /// The user's aggregate progress from the server; `nil` when it sent none.
    public let progress: SeriesProgress?
    /// In sequence order (``SeriesSequence``).
    public let books: [SeriesBook]

    public init(response: SeriesDetailResponse, items: [LibraryItem]) {
        id = response.series.id
        name = response.series.name
        description = response.series.description.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        progress = response.progress
        let seriesID = response.series.id
        books = SeriesSequence.sorted(items.map { SeriesBook(item: $0, seriesID: seriesID) })
    }
}

/// The series screen; a port of the legacy `pages/bookshelf/series/_id.vue`.
///
/// Loads `GET /api/series/:id?include=progress`, then the series' books from the library items
/// endpoint with the `series.<id>` filter (and `collapseseries=1` when ``collapseSeries``), in
/// one unpaged request because the books are sorted here by sequence. The books come from the
/// series' own library when the server names it, else from ``libraryID``.
///
/// - Loading keeps the last series while reloading and after a failed reload. When loads
///   overlap, only the last one started is applied. A 404 (``APIError/notFound``) drops the
///   series and ``phase`` becomes ``Phase/notFound`` for the view to pop.
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
    /// `collapseBookSeries` setting).
    public let collapseSeries: Bool

    /// The last loaded series; kept while reloading and after a failed reload, dropped on 404.
    public private(set) var detail: SeriesDetail?
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?
    /// The last load answered 404.
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

    /// The books query: the series filter, no sort and no paging.
    public var booksQuery: LibraryQuery {
        LibraryQuery(filter: .series(id: seriesID), collapseSeries: collapseSeries)
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
        do {
            let response = try await service.seriesDetail(id: seriesID)
            let libraryID = response.series.libraryId ?? libraryID
            let page = try await service.filteredBooksPage(libraryID: libraryID, query: booksQuery)
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
            if error as? APIError == .notFound {
                isNotFound = true
                detail = nil
            }
        }
    }

    /// The user's progress on `book`, if any.
    public func progress(of book: SeriesBook) -> MediaProgress? {
        cache.progress(libraryItemID: book.summary.itemID)
    }

    /// Where "continue series" goes: the first book in sequence order that isn't finished, or
    /// `nil` when all are. Collapsed sub-series are skipped. A book counts as finished by its
    /// ``ProgressCache`` entry when it has one, else by the series response's finished IDs.
    public var continueBook: SeriesBook? {
        guard let detail else { return nil }
        let finished = Set(detail.progress?.libraryItemIdsFinished ?? [])
        return detail.books.first { book in
            guard book.summary.kind == .book else { return false }
            if let progress = progress(of: book) { return !progress.isFinished }
            return !finished.contains(book.summary.itemID)
        }
    }
}
