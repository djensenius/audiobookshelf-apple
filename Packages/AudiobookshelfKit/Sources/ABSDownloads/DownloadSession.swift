import ABSAPI
import Foundation

/// The parts of `URLSession` the engine uses. `URLSession` conforms; tests substitute an
/// ephemeral session with a stub `URLProtocol`, which background sessions don't support.
public protocol DownloadSession: AnyObject, Sendable {
    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask
    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask
    var allTasks: [URLSessionTask] { get async }
    /// Lets running tasks finish, then invalidates the session; the delegate then gets
    /// `urlSession(_:didBecomeInvalidWithError:)`.
    func finishTasksAndInvalidate()
}

extension URLSession: DownloadSession {}

/// Creates the engine's session with the engine's delegate. Called again after the session
/// is invalidated (for example when it loses `nsurlsessiond`).
public typealias DownloadSessionFactory = @Sendable (any URLSessionDelegate) -> any DownloadSession

extension URLSessionConfiguration {
    /// The identifier of the background download session. Only one session per process may
    /// use it at a time.
    public static let absDownloadsIdentifier = "org.davidjensenius.Audiobookshelf.downloads"

    /// The background configuration for downloads: transfers continue in `nsurlsessiond`
    /// while the app is suspended or terminated by the system, and on iOS the app is
    /// relaunched to handle their events.
    ///
    /// There is no `sharedContainerIdentifier`: only the app uses the session, and the
    /// delegate moves every file into the app's own container (ADR 0003). Cookies and the URL
    /// cache are off: downloads authenticate with headers only and the files are moved out of
    /// the session's temporary location. At most three transfers run at once per server, as in
    /// the legacy app; the engine creates every part's task, and the rest wait in the session.
    public static func absDownloads(identifier: String = absDownloadsIdentifier) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = nil
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// What a download request for one server connection needs: the server and its custom
/// headers, and a current access token.
public struct DownloadCredentials: Sendable {
    public var configuration: APIClientConfiguration
    public var accessToken: String

    public init(configuration: APIClientConfiguration, accessToken: String) {
        self.configuration = configuration
        self.accessToken = accessToken
    }
}

/// Supplies credentials for download requests; implemented by the account layer, which owns
/// the Keychain tokens and the ``APIClient`` refresh.
///
/// Contract:
/// - ``currentCredentials(for:)`` reads what is stored and never makes a network request.
/// - ``credentials(for:replacing:)`` refreshes through the connection's ``APIClient``, so
///   concurrent callers (several parts, or the app's own API calls) join its single
///   in-flight refresh instead of starting their own.
public protocol DownloadCredentialProviding: Sendable {
    /// The connection's stored credentials, without any network request, or `nil` when the
    /// connection is signed out or removed. Used to tell a 401 for an old token from one for
    /// the current token.
    func currentCredentials(for connectionID: UUID) async -> DownloadCredentials?

    /// Credentials for a new or resumed task (ADR 0007: refresh before creating each task).
    ///
    /// - Parameter rejectedAccessToken: `nil` before a task is created or resumed: refresh
    ///   the access token if it expires soon. After a 401, the token the server rejected:
    ///   refresh it unless the stored token has already changed. Either way, join the
    ///   ``APIClient``'s in-flight refresh if there is one.
    /// - Throws: when the connection is signed out or the refresh fails.
    func credentials(for connectionID: UUID, replacing rejectedAccessToken: String?) async throws
        -> DownloadCredentials
}
