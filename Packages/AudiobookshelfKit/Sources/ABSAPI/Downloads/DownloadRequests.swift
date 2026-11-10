import Foundation

/// Requests for background file downloads (ADR 0007).
///
/// A download carries the access token in the `Authorization` header, with the connection's
/// custom headers, and never as a `?token=` query, so the URL that `URLSession` and the store
/// keep holds no credential.
public enum DownloadRequests {
    /// The token-free API path of a library file's download, which is what a download part
    /// stores as its `serverPath`.
    public static func filePath(itemID: String, ino: String) -> String {
        "/api/items/\(pathSegment(itemID))/file/\(pathSegment(ino))/download"
    }

    /// A `GET` request for `path` on the configured server, with the custom headers and
    /// `Authorization: Bearer <accessToken>`. Cookies are never sent or stored.
    ///
    /// - Throws: ``APIError/invalidURL`` if the server address and `path` don't form a URL.
    public static func request(
        path: String, configuration: APIClientConfiguration, accessToken: String
    ) throws -> URLRequest {
        var request = URLRequest(url: try APIClient.url(base: configuration.baseURL, path: path, query: []))
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in configuration.customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
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
