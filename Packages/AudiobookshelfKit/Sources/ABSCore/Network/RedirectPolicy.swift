import Foundation

/// Decides how each redirect hop is followed, so credentials never leave the server's origin.
/// Used by ABSAPI's `APIClient` and by ``ImagePipeline``.
///
/// `URLSession` drops `Authorization` on every redirect (even to the same origin) and carries
/// every other header to any host. Instead:
/// - While the chain stays on the original origin (same scheme, host and port, or the same
///   host upgraded from `http` to `https` on default ports), the original request's headers,
///   including `Authorization` and custom headers, are sent again.
/// - Once a hop leaves the origin, the request is stripped: it keeps the URL, method and body
///   `URLSession` proposed (so a 307 or 308 still posts its body) but no headers other than
///   `Content-Type`, and it doesn't use the cookie jar. Every later hop of that task is
///   stripped too, even back on the origin.
/// - A hop from `https` to `http`, or to a non-HTTP scheme, is refused.
/// - A hop that changes the method is refused: `URLSession` turns a POST into a GET on a 301
///   or 302, and any method but HEAD into a GET on a 303, so the request (a logout, a session
///   sync) would never be delivered while the GET's reply looked like its result. A 307 or 308
///   keeps the method and body and is followed.
public enum RedirectPolicy {
    public struct Hop: Sendable {
        public let request: URLRequest
        public let isStripped: Bool
    }

    /// Returns the request for the next hop, or `nil` to refuse it. `wasStripped` is whether an
    /// earlier hop of the same task was stripped.
    public static func hop(
        following response: HTTPURLResponse,
        to proposed: URLRequest,
        original: URLRequest?,
        wasStripped: Bool
    ) -> Hop? {
        guard let from = response.url, let to = proposed.url, let original, let origin = original.url,
            let toScheme = to.scheme?.lowercased(), toScheme == "http" || toScheme == "https"
        else { return nil }
        if from.scheme?.lowercased() == "https", toScheme == "http" { return nil }
        if (proposed.httpMethod ?? "GET") != (original.httpMethod ?? "GET") { return nil }

        guard !wasStripped, isSameOrigin(origin, from), isSameOrigin(from, to) else {
            return Hop(request: stripped(proposed, url: to), isStripped: true)
        }
        var request = proposed
        let hasBody = proposed.httpBody != nil || proposed.httpBodyStream != nil
        for (name, value) in original.allHTTPHeaderFields ?? [:] {
            if !hasBody, ["content-type", "content-length"].contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return Hop(request: request, isStripped: false)
    }

    /// Whether `next` has the same origin as `current`, or is `current` upgraded to `https`.
    public static func isSameOrigin(_ current: URL, _ next: URL) -> Bool {
        guard let host = current.host()?.lowercased(), host == next.host()?.lowercased(),
            let scheme = current.scheme?.lowercased(), let nextScheme = next.scheme?.lowercased()
        else { return false }
        let port = effectivePort(current, scheme: scheme)
        let nextPort = effectivePort(next, scheme: nextScheme)
        if scheme == nextScheme { return port == nextPort }
        return scheme == "http" && nextScheme == "https" && port == 80 && nextPort == 443
    }

    private static func stripped(_ proposed: URLRequest, url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: proposed.cachePolicy, timeoutInterval: proposed.timeoutInterval)
        request.httpMethod = proposed.httpMethod
        if let body = proposed.httpBody {
            request.httpBody = body
        } else if let stream = proposed.httpBodyStream {
            request.httpBodyStream = stream
        }
        if request.httpBody != nil || request.httpBodyStream != nil,
            let contentType = proposed.value(forHTTPHeaderField: "Content-Type")
        {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpShouldHandleCookies = false
        return request
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        url.port ?? ["http": 80, "https": 443][scheme]
    }
}
