import ABSAPI
import ABSCore
import Foundation

/// The item endpoint ``ItemDetailModel`` uses. `APIClient` conforms; tests use fakes.
public protocol ItemDetailService: Sendable {
    /// `GET /api/items/:id?expanded=1&include=rssfeed`: the full item with tracks.
    func item(id: String) async throws -> LibraryItem
}

extension APIClient: ItemDetailService {
    public func item(id: String) async throws -> LibraryItem {
        try await send(ItemEndpoints.item(id: id))
    }
}
