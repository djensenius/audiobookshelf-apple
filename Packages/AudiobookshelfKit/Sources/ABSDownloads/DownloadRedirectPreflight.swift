import ABSAPI
import ABSCore
import Foundation
import Synchronization

/// Why ``DownloadRedirectPreflight`` didn't clear a download.
public enum DownloadRedirectPreflightError: Error, Equatable, Sendable {
    /// The download redirects off the server's origin, to `URL`: another scheme, host or port, or
    /// from `https` to `http`. The hop was refused before any request went there.
    case offOrigin(URL)
    /// The check couldn't reach the server.
    case unreachable(URLError.Code)
}

/// Checks a download's redirects in the foreground before its background task is made (#145).
public protocol DownloadRedirectPreflighting: Sendable {
    /// The request for the background task: `request`, or `request` at the end of its redirects
    /// when every hop stays on its origin.
    ///
    /// - Throws: ``DownloadRedirectPreflightError``.
    func check(_ request: URLRequest) async throws(DownloadRedirectPreflightError) -> URLRequest
}

/// Sends a download's request as `HEAD` (or as `GET` of `bytes=0-0` when the server rejects
/// `HEAD` with 405 or 501) on an ephemeral session, following redirects by ``RedirectPolicy``.
///
/// A background session follows redirects without asking its delegate and carries custom headers
/// (a proxy's `CF-Access-Client-Secret`, say) to any host, so a background task must not meet a
/// redirect off the server. The check refuses an off-origin hop before it is sent, and the task
/// starts at the end of same-origin hops, so it isn't redirected. A redirect that appears only
/// between the check and the transfer is still followed by the background session; its response
/// is then discarded (``DownloadFailureCode/offOrigin``), but its headers have been sent.
///
/// The check's status and body are ignored: the background task reports those. Cookies, caches
/// and credentials storage aren't used.
public struct DownloadRedirectPreflight: DownloadRedirectPreflighting {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter makeConfiguration: the session's configuration, ephemeral by default. Cookie,
    ///   cache and credential storage are cleared whatever it sets.
    public init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.makeConfiguration = makeConfiguration
    }

    public func check(_ request: URLRequest) async throws(DownloadRedirectPreflightError) -> URLRequest {
        let configuration = makeConfiguration()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var head = request
        head.httpMethod = "HEAD"
        var final = try await Self.probe(head, in: session)
        if final.status == 405 || final.status == 501 {
            var ranged = request
            ranged.httpMethod = "GET"
            ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            final = try await Self.probe(ranged, in: session)
        }
        var cleared = request
        cleared.url = final.url ?? request.url
        return cleared
    }

    /// Sends `request` until its response headers arrive, then cancels it.
    private static func probe(
        _ request: URLRequest, in session: URLSession
    ) async throws(DownloadRedirectPreflightError) -> (url: URL?, status: Int) {
        let guardian = RedirectGuard()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
            bytes.task.cancel()
            if let refused = guardian.refused { throw DownloadRedirectPreflightError.offOrigin(refused) }
            return (response.url, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            if let refused = guardian.refused { throw .offOrigin(refused) }
            if let error = error as? DownloadRedirectPreflightError { throw error }
            throw .unreachable((error as? URLError)?.code ?? .unknown)
        }
    }
}

/// Follows a hop only when ``DownloadRequests/redirect(following:to:original:)`` keeps it on the
/// origin; otherwise records it and cancels the task, so nothing is sent to the new address.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let state = Mutex<URL?>(nil)

    var refused: URL? { state.withLock { $0 } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let hop = DownloadRequests.redirect(following: response, to: request, original: task.originalRequest) {
            return hop
        }
        state.withLock { $0 = request.url ?? response.url }
        task.cancel()
        return nil
    }
}
