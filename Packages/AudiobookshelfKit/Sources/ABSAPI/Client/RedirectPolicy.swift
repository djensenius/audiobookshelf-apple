import Foundation

/// Decides how each redirect hop is followed, so credentials never leave the server's origin.
///
/// `URLSession` drops `Authorization` on every redirect (even to the same origin) and carries
/// every other header to any host. Instead:
/// - While the chain stays on the original origin (same scheme, host and port, or the same
///   host upgraded from `http` to `https` on default ports), the original request's headers,
///   including `Authorization` and custom headers, are sent again.
/// - Once a hop leaves the origin, the request is rebuilt from the URL alone, and later hops
///   never regain credentials, even back on the origin.
/// - A hop from `https` to `http`, or to a non-HTTP scheme, is refused.
enum RedirectPolicy {
    static func request(
        following response: HTTPURLResponse,
        to proposed: URLRequest,
        original: URLRequest?
    ) -> URLRequest? {
        guard let from = response.url, let to = proposed.url, let original, let origin = original.url,
            let toScheme = to.scheme?.lowercased(), toScheme == "http" || toScheme == "https"
        else { return nil }
        if from.scheme?.lowercased() == "https", toScheme == "http" { return nil }

        guard isSameOrigin(origin, from), isSameOrigin(from, to) else {
            return URLRequest(url: to, cachePolicy: proposed.cachePolicy, timeoutInterval: proposed.timeoutInterval)
        }
        var request = proposed
        let hasBody = proposed.httpBody != nil || proposed.httpBodyStream != nil
        for (name, value) in original.allHTTPHeaderFields ?? [:] {
            if !hasBody, ["content-type", "content-length"].contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Whether `next` has the same origin as `current`, or is `current` upgraded to `https`.
    static func isSameOrigin(_ current: URL, _ next: URL) -> Bool {
        guard let host = current.host()?.lowercased(), host == next.host()?.lowercased(),
            let scheme = current.scheme?.lowercased(), let nextScheme = next.scheme?.lowercased()
        else { return false }
        let port = effectivePort(current, scheme: scheme)
        let nextPort = effectivePort(next, scheme: nextScheme)
        if scheme == nextScheme { return port == nextPort }
        return scheme == "http" && nextScheme == "https" && port == 80 && nextPort == 443
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        url.port ?? ["http": 80, "https": 443][scheme]
    }
}

/// The session delegate that applies ``RedirectPolicy``. A task delegate such as
/// ``RedirectSuppressingDelegate`` takes precedence for its task.
final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectPolicy.request(following: response, to: request, original: task.originalRequest)
    }
}
