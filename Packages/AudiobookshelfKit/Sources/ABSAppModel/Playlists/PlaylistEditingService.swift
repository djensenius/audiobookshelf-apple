import ABSAPI
import ABSCore
import Foundation

/// The playlist writes of ``AddToPlaylistModel`` and ``PlaylistDetailEditor``.
/// `APIClient` conforms; tests and previews use fakes.
///
/// Playlists belong to the signed-in user; the server rejects another user's playlist with 403.
/// Removing a playlist's last member deletes the playlist on the server: the response then has
/// empty items.
public protocol PlaylistEditingService: Sendable {
    /// `GET /api/libraries/:id/playlists` without paging: all the user's playlists in the library,
    /// as the legacy add-to-playlist modal loaded them.
    func allPlaylists(libraryID: String) async throws -> [Playlist]
    /// `POST /api/playlists`: a new playlist in `libraryID` with `items`, in order.
    func createPlaylist(name: String, libraryID: String, items: [PlaylistItemReference]) async throws -> Playlist
    /// `POST /api/playlists/:id/batch/add`; members already in the playlist are no-ops.
    func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist
    /// `POST /api/playlists/:id/batch/remove`; nonmembers are no-ops. `items` must not be empty.
    func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist
    /// `DELETE /api/playlists/:id/item/:itemId[/:episodeId]`: one member; 404 when it isn't one.
    func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist
    /// `PATCH /api/playlists/:id` with only `items`: every member exactly once, in the new order.
    /// The server answers 400 when the count differs from its members'.
    func reorderPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist
    /// `DELETE /api/playlists/:id`.
    func deletePlaylist(id: String) async throws
}

extension APIClient: PlaylistEditingService {
    public func allPlaylists(libraryID: String) async throws -> [Playlist] {
        try await send(LibraryEndpoints.playlists(libraryID: libraryID)).results
    }

    public func createPlaylist(
        name: String, libraryID: String, items: [PlaylistItemReference]
    ) async throws -> Playlist {
        try await send(PlaylistEndpoints.create(PlaylistCreateRequest(name: name, libraryID: libraryID, items: items)))
    }

    public func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send(PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: items)))
    }

    public func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send(PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: items)))
    }

    public func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist {
        try await send(
            PlaylistEndpoints.removeItem(id: id, libraryItemID: item.libraryItemID, episodeID: item.episodeID))
    }

    public func reorderPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send(PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(itemsInOrder: items)))
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await send(PlaylistEndpoints.delete(id: id))
    }
}
