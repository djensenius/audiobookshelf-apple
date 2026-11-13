import ABSAPI
import ABSCore
import Foundation
import Synchronization

/// Why ``DownloadRedirectPreflight`` didn't clear a download.
public enum DownloadRedirectPreflightError: Error, Equatable, Sendable {
    /// The download redirects off the server's origin, to `URL`: another scheme, host or port, or
    /// from `https` to `http`. The hop was refused before any request went there.
    case offOrigin(URL)
    /// No network the request may use: the device is offline, or the download's cellular or
    /// Low Data Mode settings forbid the current one. Wait with
    /// ``DownloadRedirectPreflighting/waitForNetwork(_:)`` rather than retrying.
    case noNetwork(URLError.Code)
    /// The check couldn't reach the server.
    case unreachable(URLError.Code)

    /// The failures that mean no allowed network rather than a failing server.
    static func classify(_ error: URLError) -> DownloadRedirectPreflightError {
        let offline: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        ]
        if offline.contains(error.code) || error.networkUnavailableReason != nil { return .noNetwork(error.code) }
        return .unreachable(error.code)
    }
}

/// Checks a download's redirects in the foreground before its background task is made (#145).
public protocol DownloadRedirectPreflighting: Sendable {
    /// The request for the background task: `request`, or `request` at the end of its redirects
    /// when every hop stays on its origin.
    ///
    /// - Throws: ``DownloadRedirectPreflightError``.
    func check(_ request: URLRequest) async throws(DownloadRedirectPreflightError) -> URLRequest

    /// Returns once a network `request` may use (by its cellular, expensive and constrained
    /// flags) is available, or when the calling task is cancelled.
    ///
    /// - Returns: `false` when the request failed without waiting: a network was available, so
    ///   the failure is the server's and counts as one.
    func waitForNetwork(_ request: URLRequest) async -> Bool
}

/// Sends a download's request exactly as its background task will (the same method and headers)
/// on an ephemeral session, following redirects by ``RedirectPolicy``, and cancels it once the
/// response headers arrive.
///
/// A background session follows redirects without asking its delegate ("For tasks in background
/// sessions, redirections will always be followed and this method will not be called",
/// `NSURLSession.h`) and carries custom headers (a proxy's `CF-Access-Client-Secret`, say) to any
/// host, so a background task must not meet a redirect off the server. The check refuses an
/// off-origin hop before it is sent, and the task starts at the end of same-origin hops, so it
/// isn't redirected. The check is the transfer's own request, so a server that redirects only
/// some methods or ranges redirects it too. A redirect that appears only after the check, or
/// only for a resumed transfer's `Range`, is still followed by the background session; its
/// response is then discarded (``DownloadFailureCode/offOrigin``), but its headers have been sent.
/// So connections with custom headers download in the engine's foreground session instead
/// (#467), whose delegate refuses such a hop before it is sent.
///
/// The check's status is ignored, and of its body only what arrives with the headers is read:
/// the background task reports the status. Cookies, caches and credentials storage aren't used.
public struct DownloadRedirectPreflight: DownloadRedirectPreflighting {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter makeConfiguration: the session's configuration, ephemeral by default. Cookie,
    ///   cache and credential storage are cleared whatever it sets.
    public init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.makeConfiguration = makeConfiguration
    }

    public func check(_ request: URLRequest) async throws(DownloadRedirectPreflightError) -> URLRequest {
        var cleared = request
        cleared.url = try await run(request, waitsForConnectivity: false).result.get() ?? request.url
        return cleared
    }

    /// Sends the check on a session that waits for an allowed network instead of failing. Any
    /// answer ends the wait, and so does a failure: `false` when it came without a wait, so a
    /// network was available and the failure is the server's.
    public func waitForNetwork(_ request: URLRequest) async -> Bool {
        let (result, waited) = await run(request, waitsForConnectivity: true)
        switch result {
        case .success, .failure(.offOrigin): return true
        case .failure: return waited
        }
    }

    /// Sends `request` until its response headers arrive, then cancels it.
    private func run(
        _ request: URLRequest, waitsForConnectivity: Bool
    ) async -> (result: Result<URL?, DownloadRedirectPreflightError>, waited: Bool) {
        let configuration = makeConfiguration()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = waitsForConnectivity
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let guardian = RedirectGuard()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
            bytes.task.cancel()
            if let refused = guardian.refused { return (.failure(.offOrigin(refused)), guardian.waited) }
            return (.success(response.url), guardian.waited)
        } catch {
            if let refused = guardian.refused { return (.failure(.offOrigin(refused)), guardian.waited) }
            return (.failure(.classify(error as? URLError ?? URLError(.unknown))), guardian.waited)
        }
    }
}

/// Follows a hop only when ``DownloadRequests/redirect(following:to:original:)`` keeps it on the
/// origin; otherwise records it and cancels the task, so nothing is sent to the new address.
/// Notes when the task waited for a network.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let state = Mutex<(refused: URL?, waited: Bool)>((nil, false))

    var refused: URL? { state.withLock { $0.refused } }
    var waited: Bool { state.withLock { $0.waited } }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        state.withLock { $0.waited = true }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let hop = DownloadRequests.redirect(following: response, to: request, original: task.originalRequest) {
            return hop
        }
        state.withLock { $0.refused = request.url ?? response.url }
        task.cancel()
        return nil
    }
}
