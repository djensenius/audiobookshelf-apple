import ABSCore
import Foundation

/// Why ``DownloadRequests`` won't build a background download request.
public enum DownloadRequestError: Error, Equatable, Sendable {
    /// The connection sends custom headers (a proxy's `CF-Access-Client-Secret`, say). A
    /// background session follows redirects without asking its delegate and forwards custom
    /// headers to the new address, even on another server, so they could leak before the
    /// response is rejected. Downloads for such connections are refused until a foreground
    /// redirect check exists (#145).
    case customHeadersRequireRedirectCheck
}

/// Requests for background file downloads (ADR 0007).
///
/// A download carries the access token in the `Authorization` header, never as a `?token=`
/// query, so the URL that `URLSession` and the store keep holds no credential. `URLSession`
/// drops `Authorization` on a redirect, but not custom headers, so connections with custom
/// headers can't download in the background yet (#145).
public enum DownloadRequests {
    /// The token-free API path of a library file's download, which is what a download part
    /// stores as its `serverPath`.
    public static func filePath(itemID: String, ino: String) -> String {
        "/api/items/\(pathSegment(itemID))/file/\(pathSegment(ino))/download"
    }

    /// The token-free API path and query of an item's offline cover, a 1200 px JPEG
    /// (ADR 0005), which a cover download part stores as its `serverPath`. `updatedAt` is the
    /// item's `updatedAt` in milliseconds, so a changed cover is a different request.
    public static func coverPath(itemID: String, updatedAt: Int) -> String {
        "/api/items/\(pathSegment(itemID))/cover?width=1200&format=jpeg&ts=\(updatedAt)"
    }

    /// A background `GET` request for `path` on the configured server, with
    /// `Authorization: Bearer <accessToken>`. Cookies are never sent or stored.
    ///
    /// `path` may end in a `?query` (as ``coverPath(itemID:updatedAt:)`` does). The query is
    /// split off and sent as the URL's query, with `+` encoded as `%2B`, not as part of the path.
    /// A `#fragment` after it is dropped; no stored path has one, because `pathSegment` escapes `#`.
    ///
    /// - Throws: ``DownloadRequestError/customHeadersRequireRedirectCheck`` if the connection
    ///   has custom headers, or ``APIError/invalidURL`` if the server address and `path`
    ///   don't form a URL.
    public static func request(
        path: String, configuration: APIClientConfiguration, accessToken: String
    ) throws -> URLRequest {
        guard configuration.customHeaders.isEmpty else { throw DownloadRequestError.customHeadersRequireRedirectCheck }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [URLQueryItem] = []
        if parts.count == 2 {
            guard let components = URLComponents(string: "?" + parts[1]) else { throw APIError.invalidURL }
            query = components.queryItems ?? []
        }
        var request = URLRequest(
            url: try APIClient.url(base: configuration.baseURL, path: String(parts.first ?? ""), query: query))
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The request for a download's redirect hop, or `nil` to refuse it.
    ///
    /// Hops that stay on the original request's origin get its headers again (including
    /// `Authorization`, which `URLSession` drops). A download never follows a hop that leaves
    /// the origin: a stripped request would fetch an unrelated body into the media location,
    /// so the task fails instead.
    public static func redirect(
        following response: HTTPURLResponse, to proposed: URLRequest, original: URLRequest?
    ) -> URLRequest? {
        guard
            let hop = RedirectPolicy.hop(following: response, to: proposed, original: original, wasStripped: false),
            !hop.isStripped
        else { return nil }
        return hop.request
    }

    /// Whether `url` has the same origin as `origin`, or is `origin` upgraded from `http` to
    /// `https` on the default ports.
    public static func isSameOrigin(_ origin: URL, _ url: URL) -> Bool {
        RedirectPolicy.isSameOrigin(origin, url)
    }
}
