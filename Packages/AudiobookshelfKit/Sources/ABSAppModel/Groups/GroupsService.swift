import ABSAPI
import ABSCore
import Foundation

/// The collection and playlist endpoints the group lists and ``GroupDetailModel`` use.
/// `APIClient` conforms; tests use fakes.
public protocol GroupsService: Sendable {
    /// `GET /api/libraries/:id/collections`: one page, zero-based, without sort or filter.
    func collectionsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<LibraryCollection>
    /// `GET /api/libraries/:id/playlists`: one page of the user's playlists, zero-based. The
    /// legacy list also sent the library's sort and filter by accident; none are sent here.
    func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist>
    /// `GET /api/collections/:id`: the collection with expanded books.
    func collectionDetail(id: String) async throws -> LibraryCollection
    /// `GET /api/playlists/:id`: the playlist with expanded items.
    func playlistDetail(id: String) async throws -> Playlist
}

extension APIClient: GroupsService {
    public func collectionsPage(
        libraryID: String, page: Int, limit: Int
    ) async throws -> PagedResults<LibraryCollection> {
        try await send(
            LibraryEndpoints.collections(libraryID: libraryID, query: LibraryQuery(page: page, limit: limit)))
    }

    public func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist> {
        try await send(LibraryEndpoints.playlists(libraryID: libraryID, query: LibraryQuery(page: page, limit: limit)))
    }

    public func collectionDetail(id: String) async throws -> LibraryCollection {
        try await send(ItemEndpoints.collection(id: id))
    }

    public func playlistDetail(id: String) async throws -> Playlist {
        try await send(ItemEndpoints.playlist(id: id))
    }
}
