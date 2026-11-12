import ABSCore
import Foundation

/// RSS feeds of items, collections and series. Every route needs an admin or root user; others
/// get 403.
public enum FeedEndpoints {
    /// `POST /api/feeds/:kind/:id/open`: returns the minified feed. 400 with a plain-text reason
    /// when the slug is in use or the entity has no audio tracks, 404 when it doesn't exist.
    public static func open(_ target: RssFeedTarget, _ request: RssFeedOpenRequest) -> Endpoint<RssFeedOpenResponse> {
        Endpoint(.post, "/api/feeds/\(target.kind.rawValue)/\(pathSegment(target.id))/open", body: request)
    }

    /// `POST /api/feeds/:id/close`: 200 plain `OK`, or 404 when the feed isn't open.
    ///
    /// Only redirects on the server's origin are followed (``Endpoint/staysOnOrigin``): another
    /// origin's 200 or 404 says nothing about this feed, so a hop off the origin fails with
    /// ``APIError/redirectRefused(status:)`` instead of reporting the feed closed.
    public static func close(id: String) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/api/feeds/\(pathSegment(id))/close", staysOnOrigin: true)
    }

    /// The feed open for `target`, if any: its detail route with `include=rssfeed` (items also need
    /// `expanded=1`), decoding only `rssFeed`.
    public static func current(_ target: RssFeedTarget) -> Endpoint<RssFeedLookup> {
        let id = pathSegment(target.id)
        let include = URLQueryItem(name: "include", value: "rssfeed")
        return switch target.kind {
        case .item:
            Endpoint(.get, "/api/items/\(id)", query: [URLQueryItem(name: "expanded", value: "1"), include])
        case .collection: Endpoint(.get, "/api/collections/\(id)", query: [include])
        case .series: Endpoint(.get, "/api/series/\(id)", query: [include])
        }
    }
}
