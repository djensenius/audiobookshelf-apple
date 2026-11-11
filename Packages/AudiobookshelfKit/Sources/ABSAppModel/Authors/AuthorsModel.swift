import ABSAPI
import ABSCore
import Foundation
import Observation

/// The authors list of a library (`GET /api/libraries/:id/authors`), unpaged and in server
/// order; a port of the legacy `pages/bookshelf/authors.vue`.
///
/// Loading keeps the last list while reloading and after a failed reload, like ``StatsModel``.
/// When loads overlap, only the last one started is applied.
///
/// A model belongs to one library, client and account: views recreate it per library and under
/// the session's `.id(identity)` (ADR 0004).
@MainActor
@Observable
public final class AuthorsModel {
    public let libraryID: String
    /// The last loaded authors, in server order.
    public private(set) var authors: [AuthorSummary] = []
    /// The authors have been loaded at least once.
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?

    @ObservationIgnored private let service: any SeriesAuthorsService
    @ObservationIgnored private var sequence = 0

    public init(libraryID: String, service: any SeriesAuthorsService) {
        self.libraryID = libraryID
        self.service = service
    }

    /// Loaded, with no authors.
    public var isEmpty: Bool { hasLoaded && authors.isEmpty }

    /// Loads unless the authors have already loaded.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Loads the authors. A response to an older call that arrives after a newer one started is
    /// dropped.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<[Author], any Error>
        do {
            result = .success(try await service.authorList(libraryID: libraryID))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let loaded):
            authors = loaded.map(AuthorSummary.init(author:))
            hasLoaded = true
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }
}
