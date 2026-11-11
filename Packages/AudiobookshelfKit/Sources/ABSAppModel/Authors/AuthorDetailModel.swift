import ABSAPI
import ABSCore
import Foundation
import Observation

/// A loaded author: name and image (``summary``) and bio.
public struct AuthorDetail: Sendable, Hashable, Identifiable {
    public let summary: AuthorSummary
    /// The author's description; `nil` when blank.
    public let bio: String?

    public var id: String { summary.id }
    public var name: String { summary.name }

    public init(author: Author) {
        summary = AuthorSummary(author: author)
        bio = author.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// The author screen: the author from `GET /api/authors/:id`, and their books paged through
/// ``books`` from the library items endpoint with the `authors.<id>` filter.
///
/// - Loading the author keeps the last one while reloading and after a failed reload. When loads
///   overlap, only the last one started is applied. A 404 (``APIError/notFound``) drops the
///   author and ``phase`` becomes ``Phase/notFound`` for the view to pop.
/// - ``books`` is an ``ItemListModel`` and pages, refreshes and drops stale pages on its own.
///
/// A model belongs to one author, library, client and account: views recreate it per author ID
/// and under the session's `.id(identity)` (ADR 0004), so a server or user switch never reuses it.
@MainActor
@Observable
public final class AuthorDetailModel {
    public enum Phase: Sendable, Hashable {
        /// Not loaded yet, and no load running.
        case idle
        /// The first load is running.
        case loading
        /// ``AuthorDetailModel/detail`` is set; a reload may be running or may have failed.
        case loaded
        /// The last load failed and nothing was loaded before; see ``AuthorDetailModel/error``.
        case failed
        /// The server answered 404.
        case notFound
    }

    public let authorID: String
    public let libraryID: String
    /// The author's books. Nothing loads until ``loadIfNeeded()`` or `books.loadNextPage()`.
    public let books: ItemListModel<LibraryQuery, ItemSummary>

    /// The last loaded author; kept while reloading and after a failed reload, dropped on 404.
    public private(set) var detail: AuthorDetail?
    public private(set) var isLoading = false
    /// The error of the last author load, cleared by the next successful one.
    public private(set) var error: (any Error)?
    /// The last load answered 404.
    public private(set) var isNotFound = false

    @ObservationIgnored private let service: any SeriesAuthorsService
    @ObservationIgnored private var sequence = 0

    /// - Parameter query: The books' sort and `collapseseries`; its filter is replaced with the
    ///   author's, and its page and limit are set by ``books``.
    public init(
        authorID: String, libraryID: String, query: LibraryQuery = LibraryQuery(), service: any SeriesAuthorsService,
        pageSize: Int = 20, prefetchThreshold: Int = 5, connectionKey: LibraryConnectionKey? = nil
    ) {
        self.authorID = authorID
        self.libraryID = libraryID
        self.service = service
        var query = query
        query.filter = .authors(id: authorID)
        books = .filteredBooks(
            service: service, libraryID: libraryID, query: query, pageSize: pageSize,
            prefetchThreshold: prefetchThreshold, connectionKey: connectionKey)
    }

    public var phase: Phase {
        if isNotFound { return .notFound }
        if detail != nil { return .loaded }
        if isLoading { return .loading }
        return error == nil ? .idle : .failed
    }

    public var hasLoaded: Bool { detail != nil }

    /// Loads the author unless loaded, and the first page of books unless it loaded or is loading.
    /// Views call it each time they appear, so a load cancelled before it finished runs again.
    public func loadIfNeeded() async {
        if books.items.isEmpty, !books.reachedEnd { books.loadNextPage() }
        guard !hasLoaded else { return }
        await load()
    }

    /// Reloads the author and the books, for example on pull to refresh.
    public func refresh() async {
        books.refresh()
        await load()
    }

    /// Loads the author. A response to an older call that arrives after a newer one started is
    /// dropped.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<AuthorDetailResponse, any Error>
        do {
            result = .success(try await service.authorDetail(id: authorID))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let response):
            detail = AuthorDetail(author: response.author)
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
}
