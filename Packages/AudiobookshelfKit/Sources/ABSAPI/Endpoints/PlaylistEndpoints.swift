import ABSCore

/// Authenticated, user-owned playlist writes. Ordinary owners need no update/delete permission.
/// All ID routes reject other users, including administrators, with 403.
public enum PlaylistEndpoints {
    /// `POST /api/playlists`: returns the expanded playlist in request order.
    public static func create(_ request: PlaylistCreateRequest) -> Endpoint<Playlist> {
        Endpoint(.post, "/api/playlists", body: request)
    }

    /// Metadata and full reorder only; nil/empty text and omitted/empty items are no-ops.
    public static func update(id: String, _ request: PlaylistUpdateRequest) -> Endpoint<Playlist> {
        Endpoint(.patch, path(id), body: request)
    }

    /// 200 plain `OK`, not JSON.
    public static func delete(id: String) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, path(id))
    }

    /// Existing members are no-ops; unknown library-item IDs reject the entire batch with 400.
    /// New members append, but removing earlier members can leave order-number ties.
    public static func addItems(id: String, _ request: PlaylistItemsRequest) -> Endpoint<Playlist> {
        Endpoint(.post, "\(path(id))/batch/add", body: request)
    }

    /// Unknown/nonmembers are no-ops. Removing the last member returns 200 with empty items,
    /// then GET returns 404 because the playlist was deleted. Empty batches return 400.
    public static func removeItems(id: String, _ request: PlaylistItemsRequest) -> Endpoint<Playlist> {
        Endpoint(.post, "\(path(id))/batch/remove", body: request)
    }

    /// `DELETE /api/playlists/:id/item/:itemId[/:episodeId]`: removes one member, a book or (with
    /// `episodeID`) a podcast episode. A nonmember is 404. Like ``removeItems(id:_:)``, removing
    /// the last member returns 200 with empty items and deletes the playlist.
    public static func removeItem(id: String, libraryItemID: String, episodeID: String? = nil) -> Endpoint<Playlist> {
        var itemPath = "\(path(id))/item/\(pathSegment(libraryItemID))"
        if let episodeID { itemPath += "/\(pathSegment(episodeID))" }
        return Endpoint(.delete, itemPath)
    }

    private static func path(_ id: String) -> String {
        "/api/playlists/\(pathSegment(id))"
    }
}
