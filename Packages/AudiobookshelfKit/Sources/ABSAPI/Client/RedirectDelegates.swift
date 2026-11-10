import ABSCore
import Foundation
import Synchronization

/// The task delegate ``APIClient`` attaches to each request that follows redirects. It applies
/// ``RedirectPolicy`` and records whether the chain was stripped, so the client can tell that a
/// response (for example a 401) came from a hop that never saw the credentials.
final class RedirectChainDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let stripped = Mutex(false)
    private let staysOnOrigin: Bool
    private let cookies: WrittenCookies?

    /// - Parameters:
    ///   - staysOnOrigin: Declines hops that would be stripped instead of following them.
    ///   - cookies: For a request whose cookies the client writes, stores each followed
    ///     same-origin hop's `Set-Cookie` and rebuilds the next hop's `Cookie` header with it.
    init(staysOnOrigin: Bool = false, cookies: WrittenCookies? = nil) {
        self.staysOnOrigin = staysOnOrigin
        self.cookies = cookies
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
            return hop.request
        }
        guard let cookies, let url = hop.request.url else { return hop.request }
        cookies.store(from: response)
        var next = hop.request
        next.httpShouldHandleCookies = false
        next.setValue(cookies.header(for: url), forHTTPHeaderField: "Cookie")
        return next
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
