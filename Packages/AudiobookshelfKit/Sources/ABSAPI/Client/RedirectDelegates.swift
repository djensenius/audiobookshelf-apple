import ABSCore
import Foundation
import Synchronization

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
        else { return nil }
        if hop.isStripped {
            strippedTasks.withLock { _ = $0.insert(id) }
        }
        return hop.request
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
