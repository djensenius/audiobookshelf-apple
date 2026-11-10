import Foundation
import Synchronization

/// The per-task delegate of every image download: applies the redirect policy and cancels
/// inputs over 4 MiB (ADR 0005, "Redirects" and "Input cap").
///
/// Redirects within the request's origin (same scheme, host and effective port, or the same
/// host upgraded from `http` to `https` on default ports) keep the original headers. Any other
/// origin gets a request rebuilt from the URL alone, with no custom, `Authorization` or
/// `Cookie` header, and every later hop of the task stays stripped. `https` → `http` is
/// refused.
final class ImageTaskDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let original: URLRequest
    private let state = Mutex((isStripped: false, exceededLimit: false))

    init(original: URLRequest) {
        self.original = original
    }

    /// Whether the download was cancelled for passing the input cap.
    var exceededLimit: Bool { state.withLock { $0.exceededLimit } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = response.url, let to = request.url, let origin = original.url,
            let scheme = to.scheme?.lowercased(), scheme == "http" || scheme == "https",
            !(from.scheme?.lowercased() == "https" && scheme == "http")
        else { return nil }
        let keepsHeaders = state.withLock { state in
            if !state.isStripped, Self.isSameOrigin(origin, from), Self.isSameOrigin(from, to) { return true }
            state.isStripped = true
            return false
        }
        var next: URLRequest
        if keepsHeaders {
            next = request
            for (name, value) in original.allHTTPHeaderFields ?? [:] {
                next.setValue(value, forHTTPHeaderField: name)
            }
        } else {
            next = URLRequest(url: to, timeoutInterval: original.timeoutInterval)
            next.setValue(original.value(forHTTPHeaderField: "Accept") ?? "image/*", forHTTPHeaderField: "Accept")
        }
        next.cachePolicy = .reloadIgnoringLocalCacheData
        next.httpShouldHandleCookies = false
        return next
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let limit = Int64(ImageCacheLimits.maxInputBytes)
        guard totalBytesWritten > limit || totalBytesExpectedToWrite > limit else { return }
        state.withLock { $0.exceededLimit = true }
        downloadTask.cancel()
    }

    // Required by the protocol; the async `download(for:)` returns the file itself.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {}

    /// Same scheme, host and effective port, or `current` upgraded from `http` to `https` on
    /// default ports.
    static func isSameOrigin(_ current: URL, _ next: URL) -> Bool {
        guard let host = current.host()?.lowercased(), host == next.host()?.lowercased(),
            let scheme = current.scheme?.lowercased(), let nextScheme = next.scheme?.lowercased()
        else { return false }
        let ports = ["http": 80, "https": 443]
        let port = current.port ?? ports[scheme]
        let nextPort = next.port ?? ports[nextScheme]
        if scheme == nextScheme { return port == nextPort }
        return scheme == "http" && nextScheme == "https" && port == 80 && nextPort == 443
    }
}
