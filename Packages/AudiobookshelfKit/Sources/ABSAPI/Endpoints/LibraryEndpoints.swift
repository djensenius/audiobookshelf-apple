import ABSCore
import Foundation

/// Read endpoints for libraries and their browse lists.
public enum LibraryEndpoints {
    /// The `include` the legacy bookshelf and home page send with minified lists.
    static let listIncludes = "rssfeed,numEpisodesIncomplete"

    /// `GET /api/libraries`: the libraries the user can access.
    public static func libraries() -> Endpoint<LibrariesResponse> {
        Endpoint(.get, "/api/libraries")
    }

    /// `GET /api/libraries/:id?include=filterdata`: the library with its filter data.
    public static func library(id: String) -> Endpoint<LibraryWithFilterData> {
        Endpoint(.get, "/api/libraries/\(id)", query: [URLQueryItem(name: "include", value: "filterdata")])
    }

    /// `GET /api/libraries/:id/personalized`: the home page shelves.
    public static func personalized(libraryID: String) -> Endpoint<LossyArray<Shelf>> {
        Endpoint(.get, "/api/libraries/\(libraryID)/personalized", query: minifiedQuery)
    }

    /// `GET /api/libraries/:id/search?q=`. The server defaults `limit` to 12.
    public static func search(libraryID: String, query: String, limit: Int? = nil) -> Endpoint<LibrarySearchResults> {
        var items = [URLQueryItem(name: "q", value: query)]
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return Endpoint(.get, "/api/libraries/\(libraryID)/search", query: items)
    }

    /// `GET /api/libraries/:id/authors`: every author, unpaged.
    public static func authors(libraryID: String) -> Endpoint<AuthorsResponse> {
        Endpoint(.get, "/api/libraries/\(libraryID)/authors")
    }

    /// `GET /api/libraries/:id/recent-episodes` (podcast libraries only).
    public static func recentEpisodes(
        libraryID: String, page: Int = 0, limit: Int = 50
    ) -> Endpoint<RecentEpisodesPage> {
        Endpoint(
            .get, "/api/libraries/\(libraryID)/recent-episodes",
            query: [
                URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "page", value: String(page)),
            ]
        )
    }

    /// `GET /api/libraries/:id/items`: minified library items.
    public static func items(libraryID: String, query: LibraryQuery = LibraryQuery()) -> Endpoint<
        PagedResults<LibraryItem>
    > {
        paged(libraryID, "items", query)
    }

    /// `GET /api/libraries/:id/series`.
    public static func series(libraryID: String, query: LibraryQuery = LibraryQuery()) -> Endpoint<
        PagedResults<Series>
    > {
        paged(libraryID, "series", query)
    }

    /// `GET /api/libraries/:id/collections`.
    public static func collections(libraryID: String, query: LibraryQuery = LibraryQuery()) -> Endpoint<
        PagedResults<LibraryCollection>
    > {
        paged(libraryID, "collections", query)
    }

    /// `GET /api/libraries/:id/playlists`: the user's playlists.
    public static func playlists(libraryID: String, query: LibraryQuery = LibraryQuery()) -> Endpoint<
        PagedResults<Playlist>
    > {
        paged(libraryID, "playlists", query)
    }

    private static var minifiedQuery: [URLQueryItem] {
        [URLQueryItem(name: "minified", value: "1"), URLQueryItem(name: "include", value: listIncludes)]
    }

    private static func paged<Element>(
        _ libraryID: String, _ entity: String, _ query: LibraryQuery
    ) -> Endpoint<PagedResults<Element>> {
        Endpoint(.get, "/api/libraries/\(libraryID)/\(entity)", query: query.queryItems + minifiedQuery)
    }
}
