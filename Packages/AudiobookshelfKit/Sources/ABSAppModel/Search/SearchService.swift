import ABSAPI
import ABSCore
import Foundation

/// The search endpoint ``SearchModel`` uses. `APIClient` conforms; tests use fakes.
public protocol SearchService: Sendable {
    /// `GET /api/libraries/:id/search?q=`. `limit` caps each result group; `nil` keeps the
    /// server's default of 12.
    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults
}

extension APIClient: SearchService {
    public func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        try await send(LibraryEndpoints.search(libraryID: id, query: query, limit: limit))
    }
}
