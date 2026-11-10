import Foundation
import Synchronization

/// Decides how each redirect hop is followed, so credentials never leave the server's origin.
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
enum RedirectPolicy {
    struct Hop {
        let request: URLRequest
        let isStripped: Bool
    }

    /// Returns the request for the next hop, or `nil` to refuse it. `wasStripped` is whether an
    /// earlier hop of the same task was stripped.
    static func hop(
        following response: HTTPURLResponse,
        to proposed: URLRequest,
        original: URLRequest?,
        wasStripped: Bool
    ) -> Hop? {
        guard let from = response.url, let to = proposed.url, let original, let origin = original.url,
            let toScheme = to.scheme?.lowercased(), toScheme == "http" || toScheme == "https"
        else { return nil }
        if from.scheme?.lowercased() == "https", toScheme == "http" { return nil }

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
    static func isSameOrigin(_ current: URL, _ next: URL) -> Bool {
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

/// The task delegate ``APIClient`` attaches to each request that follows redirects. It applies
/// ``RedirectPolicy`` and records whether the chain was stripped, so the client can tell that a
/// response (for example a 401) came from a hop that never saw the credentials.
final class RedirectChainDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let stripped = Mutex(false)
    private let staysOnOrigin: Bool

    /// - Parameter staysOnOrigin: Declines hops that would be stripped instead of following them.
    init(staysOnOrigin: Bool = false) {
        self.staysOnOrigin = staysOnOrigin
    }

    /// Whether any hop of this task was stripped of credentials.
    var credentialsStripped: Bool {
        stripped.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectDecisions.report(nextHop(following: response, to: request, task: task), for: task)
    }

    private func nextHop(following response: HTTPURLResponse, to request: URLRequest, task: URLSessionTask)
        -> URLRequest?
    {
        let wasStripped = credentialsStripped
        guard
            let hop = RedirectPolicy.hop(
                following: response, to: request, original: task.originalRequest, wasStripped: wasStripped)
        else { return nil }
        if hop.isStripped {
            if staysOnOrigin { return nil }
            stripped.withLock { $0 = true }
        }
        return hop.request
    }
}

/// The session delegate that applies ``RedirectPolicy`` to tasks without their own delegate and
/// remembers which tasks have left the origin. ``APIClient`` gives every request a task
/// delegate (``RedirectChainDelegate`` or ``RedirectSuppressingDelegate``), which takes
/// precedence, so this is a fallback for any other task on the session.
final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let strippedTasks = Mutex<Set<Int>>([])

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let id = task.taskIdentifier
        let wasStripped = strippedTasks.withLock { $0.contains(id) }
        guard
            let hop = RedirectPolicy.hop(
                following: response, to: request, original: task.originalRequest, wasStripped: wasStripped)
        else { return RedirectDecisions.report(nil, for: task) }
        if hop.isStripped {
            strippedTasks.withLock { _ = $0.insert(id) }
        }
        return RedirectDecisions.report(hop.request, for: task)
    }

    // Async `data(for:)` tasks don't forward `didCompleteWithError` to the session delegate, but they do
    // deliver metrics once the task finishes, so the flag is cleared in whichever callback arrives.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        strippedTasks.withLock { _ = $0.remove(task.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        strippedTasks.withLock { _ = $0.remove(task.taskIdentifier) }
    }
}

/// Reports every redirect decision made by this module's delegates to an optional observer.
///
/// Nothing observes it in production. Tests use it so a stub `URLProtocol` delivers a declined
/// redirect's 3xx response only once the delegate has declined: `URLSession` gives a protocol no
/// signal for a declined redirect, and delivering the response before the decision races it.
enum RedirectDecisions {
    typealias Observer = @Sendable (_ task: URLSessionTask, _ followed: Bool) -> Void

    static let observer = Mutex<Observer?>(nil)

    /// Reports `next` (the request to follow, or `nil` to decline) for `task` and returns it.
    static func report(_ next: URLRequest?, for task: URLSessionTask) -> URLRequest? {
        observer.withLock { $0 }?(task, next != nil)
        return next
    }
}
