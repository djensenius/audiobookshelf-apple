import Foundation
import Synchronization

/// The per-task delegate of every image request: applies ``RedirectPolicy`` (ADR 0005,
/// "Redirects").
///
/// Hops within the request's origin keep the original headers. Once a hop leaves it, the
/// request is rebuilt with only `Accept`, and every later hop of the task stays stripped.
/// `https` → `http` is refused, and no hop uses cookies.
final class ImageTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let original: URLRequest
    private let isStripped = Mutex(false)

    init(original: URLRequest) {
        self.original = original
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let wasStripped = isStripped.withLock { $0 }
        guard
            let hop = RedirectPolicy.hop(
                following: response, to: request, original: original, wasStripped: wasStripped)
        else { return nil }
        var next = hop.request
        if hop.isStripped {
            isStripped.withLock { $0 = true }
            next.setValue(original.value(forHTTPHeaderField: "Accept") ?? "image/*", forHTTPHeaderField: "Accept")
        }
        next.cachePolicy = .reloadIgnoringLocalCacheData
        next.httpShouldHandleCookies = false
        return next
    }
}
