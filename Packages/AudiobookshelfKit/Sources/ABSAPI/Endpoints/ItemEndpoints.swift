import ABSCore
import Foundation

/// Endpoints for single library items, series, collections, and playlists.
public enum ItemEndpoints {
    /// `GET /api/items/:id?expanded=1&include=rssfeed`: the full item with tracks.
    public static func item(id: String) -> Endpoint<LibraryItem> {
        Endpoint(
            .get, "/api/items/\(pathSegment(id))",
            query: [URLQueryItem(name: "expanded", value: "1"), URLQueryItem(name: "include", value: "rssfeed")]
        )
    }

    /// `GET /api/items/:id/ebook[/:fileID]`: the raw bytes of the item's primary ebook, or of
    /// the ebook file with inode `fileID`.
    public static func ebook(itemID: String, fileID: String? = nil) -> Endpoint<Data> {
        Endpoint(.get, ebookPath(itemID: itemID, fileID: fileID))
    }

    /// `PATCH /api/items/:id/ebook/:fileID/status`: makes the ebook file with inode `fileID` the
    /// primary ebook if it's supplementary, else makes it supplementary (leaving the book without
    /// a primary ebook). No body; needs the user's update permission (403 without it).
    ///
    /// Only redirects on the server's origin are followed (``Endpoint/staysOnOrigin``): a 307 or
    /// 308 elsewhere would re-send the toggle to another host and report its reply as a
    /// successful change.
    public static func toggleEbookFileStatus(itemID: String, fileID: String) -> Endpoint<EmptyResponse> {
        Endpoint(.patch, "\(ebookPath(itemID: itemID, fileID: fileID))/status", staysOnOrigin: true)
    }

    /// `GET /api/series/:id`.
    public static func series(id: String) -> Endpoint<Series> {
        Endpoint(.get, "/api/series/\(pathSegment(id))")
    }

    /// `GET /api/collections/:id`: the collection with expanded books.
    public static func collection(id: String) -> Endpoint<LibraryCollection> {
        Endpoint(.get, "/api/collections/\(pathSegment(id))")
    }

    /// `GET /api/playlists/:id`: the playlist with expanded items.
    public static func playlist(id: String) -> Endpoint<Playlist> {
        Endpoint(.get, "/api/playlists/\(pathSegment(id))")
    }

    static func ebookPath(itemID: String, fileID: String?) -> String {
        var path = "/api/items/\(pathSegment(itemID))/ebook"
        if let fileID { path += "/\(pathSegment(fileID))" }
        return path
    }
}
