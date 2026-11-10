import ABSCore
import Foundation

/// Checks a server address before sign-in, signs in with a password, and re-checks the server
/// version after every login or authorize (ADR 0007: servers older than
/// ``ServerFeatures/minimumSupported`` are refused).
///
/// Methods throw ``ServerValidationError`` with a message the connect screen can show, or
/// `CancellationError`.
public struct ServerValidator: Sendable {
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    private let makeCookieStorage: @Sendable () -> HTTPCookieStorage?

    /// - Parameter sessionConfiguration: Tests return a configuration with stub protocol classes.
    public init(sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() }) {
        self.init(sessionConfiguration: sessionConfiguration, cookieStorage: { nil })
    }

    /// - Parameter cookieStorage: Makes the cookie jar shared by one candidate's `/status`
    ///   redirect chain and the sign-in after it; `nil` for a new in-memory jar. Tests use it
    ///   to observe the jar.
    init(
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration,
        cookieStorage: @escaping @Sendable () -> HTTPCookieStorage?
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.makeCookieStorage = cookieStorage
    }

    /// Normalizes `input` and reads `GET /status`.
    ///
    /// When the user typed no scheme, `https` is tried first. Plain `http` is tried only after a
    /// connection failure (never after an HTTP response or a certificate error), and only when
    /// there are no custom headers, so their secrets are never sent unencrypted without the
    /// user's consent. With custom headers it throws ``ServerValidationError/httpsUnavailable(_:)``
    /// instead; the UI warns and calls again with the explicit `http://` address. A result that
    /// fell back has ``ValidatedServer/fellBackToHTTP`` set so the UI can warn before sign-in.
    ///
    /// Redirects are followed here, not by `URLSession`, so each hop is checked before it is
    /// sent: a redirect to another host or from `https` to `http` is refused, and a redirect on
    /// the same host (for example to `https` or another port) is sent with the custom headers and
    /// adopted as the server address.
    public func validate(address input: String, customHeaders: [String: String] = [:]) async throws
        -> ValidatedServer
    {
        let candidates = ServerAddress.connectionCandidates(for: input)
        guard !candidates.isEmpty else { throw ServerValidationError.invalidAddress }
        do {
            try APIClientConfiguration.validate(customHeaders: customHeaders)
        } catch {
            throw ServerValidationError.reservedHeader(error)
        }

        for (index, candidate) in candidates.enumerated() {
            // Every candidate after the first is the inferred plain-http fallback.
            if index > 0, !customHeaders.isEmpty { throw ServerValidationError.httpsUnavailable(candidate) }
            let address: ServerAddress
            let status: ServerStatus
            let jar = makeCookieStorage() ?? URLSessionConfiguration.ephemeral.httpCookieStorage
            do {
                (address, status) = try await self.status(
                    at: candidate, customHeaders: customHeaders, cookieStorage: jar)
            } catch let error as APIError {
                if index < candidates.count - 1, Self.allowsHTTPFallback(after: error) { continue }
                throw Self.statusError(error)
            }
            guard status.isInit else { throw ServerValidationError.serverNotInitialized }
            let features = try Self.features(serverVersion: status.serverVersion)
            return ValidatedServer(
                configuration: try Self.configuration(address, customHeaders: customHeaders),
                address: address, status: status, features: features,
                fellBackToHTTP: index > 0 && address.url.scheme == "http", cookieStorage: jar)
        }
        // `candidates` is not empty, so the loop always returns or throws.
        throw ServerValidationError.invalidAddress
    }

    /// Signs in with `POST /login` and returns the user, the token pair to store, and the
    /// server's version gates. If the response is refused (unsupported version, no tokens, or a
    /// body that doesn't decode), the session the server just created is logged out, best effort.
    ///
    /// The request uses the cookie jar validation filled, so a cookie a proxy or load balancer
    /// in front of the server set during validation (a sticky session or a challenge) is sent
    /// with the password. The jar only ever holds that host's cookies: validation refuses other
    /// hosts, and `/status` creates no Audiobookshelf session. A redirect back to the same URL
    /// that sets cookies (a proxy's first-contact cookie) is retried once with them.
    public func login(to server: ValidatedServer, username: String, password: String) async throws -> LoginResult {
        let client = client(for: server)
        let reply: APIResponse<Data>
        do {
            reply = try await Self.sendRetryingCookieRedirect(
                Self.unparsed(AuthEndpoints.login(username: username, password: password)), client: client)
        } catch let error as APIError {
            throw Self.loginError(error)
        }
        return try await Self.loginResult(from: reply, client: client)
    }

    /// Turns a sign-in response (`POST /login` or `GET /auth/openid/callback`) into a
    /// ``LoginResult``, applying the version gate and requiring both tokens. If the response is
    /// refused, including when it fails to decode, the session the server just created is logged
    /// out through `client`, best effort.
    static func loginResult(from reply: APIResponse<Data>, client: APIClient) async throws -> LoginResult {
        guard !(300..<400).contains(reply.httpResponse.statusCode) else {
            throw ServerValidationError.loginRedirected
        }
        do {
            let response = try Self.decodeAuthResponse(reply.value)
            let features = try Self.features(of: response)
            guard let tokens = response.sessionTokens else { throw ServerValidationError.missingTokens }
            return LoginResult(response: response, tokens: tokens, features: features)
        } catch {
            // Read on its own: `AuthResponse.tokens` is `nil` without an access token, and the
            // rest of the body may not decode.
            let body = try? JSONDecoder().decode(LoginRefreshToken.self, from: reply.value)
            if let refreshToken = body?.user.refreshToken, !refreshToken.isEmpty {
                _ = try? await client.send(AuthEndpoints.logout(refreshToken: refreshToken))
            }
            throw error
        }
    }

    private struct LoginRefreshToken: Decodable {
        struct User: Decodable {
            let refreshToken: String?
        }
        let user: User
    }

    /// Calls `POST /api/authorize` with `client`'s stored tokens and re-checks the version, so
    /// a downgraded server is caught on launch.
    ///
    /// A redirect is not followed: a hop to another origin would answer without the token, so its
    /// response says nothing about the session. It throws
    /// ``ServerValidationError/loginRedirected``, except that a redirect back to the same URL
    /// that sets cookies (a proxy's first-contact cookie) is retried once with them.
    public func authorize(with client: APIClient) async throws -> AuthorizeResult {
        let reply: APIResponse<Data>
        do {
            reply = try await Self.sendRetryingCookieRedirect(Self.unparsed(AuthEndpoints.authorize()), client: client)
        } catch let error as APIError {
            throw Self.authorizeError(error)
        }
        guard !(300..<400).contains(reply.httpResponse.statusCode) else {
            throw ServerValidationError.loginRedirected
        }
        let response = try Self.decodeAuthResponse(reply.value)
        return AuthorizeResult(response: response, features: try Self.features(of: response))
    }

    /// The version gates for a login or authorize response.
    /// - Throws: ``ServerValidationError/unsupportedVersion(_:)`` if the version in
    ///   `serverSettings` is missing, unparseable, or older than the minimum.
    public static func features(of response: AuthResponse) throws(ServerValidationError) -> ServerFeatures {
        try features(serverVersion: response.serverSettings?.version)
    }

    static func features(serverVersion: String?) throws(ServerValidationError) -> ServerFeatures {
        guard let serverVersion, let features = ServerFeatures(serverVersion: serverVersion), features.isSupported
        else { throw .unsupportedVersion(serverVersion) }
        return features
    }

    // MARK: - Helpers

    /// The most redirects ``validate(address:customHeaders:)`` follows for one candidate.
    static let maxStatusRedirects = 5

    /// Reads `/status` at `candidate`, following same-host redirects itself so that each hop is
    /// checked before it is sent and keeps the custom headers. Every request of the chain shares
    /// `jar`, new for each candidate, so a load balancer or proxy that sets a cookie on its
    /// redirect gets it back; nothing is shared with other candidates or validations. Returns the
    /// address the status was finally served from.
    /// - Throws: `APIError` only when the first request fails, so only that can fall back to
    ///   `http`; otherwise ``ServerValidationError``.
    private func status(
        at candidate: ServerAddress, customHeaders: [String: String], cookieStorage jar: HTTPCookieStorage?
    ) async throws -> (ServerAddress, ServerStatus) {
        let configuration = try Self.configuration(candidate, customHeaders: customHeaders)
        let reply = try await client(configuration, cookieStorage: jar).response(for: Self.statusProbe())
        guard (300..<400).contains(reply.httpResponse.statusCode) else {
            return (candidate, try Self.decodeStatus(reply.value))
        }
        // The server answered on this scheme, so a later failure must not fall back to `http`.
        do {
            return try await followStatusRedirects(
                from: reply.httpResponse, candidate: candidate, customHeaders: customHeaders, cookieStorage: jar)
        } catch let error as APIError {
            throw Self.statusError(error)
        }
    }

    /// Follows the redirects of a `/status` request, up to ``maxStatusRedirects``. Each
    /// `Location` is requested as is (with its query and trailing slash); the server address is
    /// derived from the URL that finally answers.
    private func followStatusRedirects(
        from first: HTTPURLResponse, candidate: ServerAddress, customHeaders: [String: String],
        cookieStorage: HTTPCookieStorage?
    ) async throws -> (ServerAddress, ServerStatus) {
        var response = first
        var url = first.url ?? candidate.url
        for _ in 0..<Self.maxStatusRedirects {
            url = try Self.redirectTarget(of: response, from: url, candidate: candidate)
            let (configuration, endpoint) = try Self.statusRequest(for: url, customHeaders: customHeaders)
            let reply = try await client(configuration, cookieStorage: cookieStorage).response(for: endpoint)
            response = reply.httpResponse
            guard (300..<400).contains(response.statusCode) else {
                let status = try Self.decodeStatus(reply.value)
                return (try Self.serverAddress(statusURL: url), status)
            }
        }
        throw ServerValidationError.statusFailed(status: response.statusCode)
    }

    /// `GET /status` with redirects left to the validator.
    private static func statusProbe() -> Endpoint<Data> {
        var endpoint = unparsed(AuthEndpoints.status())
        endpoint.followsRedirects = false
        return endpoint
    }

    private static func decodeStatus(_ data: Data) throws -> ServerStatus {
        do {
            return try JSONDecoder().decode(ServerStatus.self, from: data)
        } catch {
            throw APIError.decoding("ServerStatus")
        }
    }

    /// The URL a `/status` redirect points to, checked before it is followed: same host as
    /// `candidate`, `http` or `https`, and never from `https` to `http`.
    private static func redirectTarget(
        of response: HTTPURLResponse, from current: URL, candidate: ServerAddress
    ) throws(ServerValidationError) -> URL {
        guard let location = response.value(forHTTPHeaderField: "Location"),
            let target = URL(string: location, relativeTo: current)?.absoluteURL,
            let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw .statusFailed(status: response.statusCode) }
        if current.scheme?.lowercased() == "https", scheme == "http" { throw .insecureRedirect }
        let host = target.host()?.lowercased() ?? ""
        guard host == candidate.url.host()?.lowercased() else { throw .redirectedToOtherHost(host) }
        return target
    }

    /// The client configuration and endpoint that request exactly `url`: its last path
    /// component (with any trailing slash) under the rest of the path as base URL. The query
    /// stays on the base URL as sent, since ``APIClient`` would re-encode query items (`+`).
    private static func statusRequest(
        for url: URL, customHeaders: [String: String]
    ) throws -> (APIClientConfiguration, Endpoint<Data>) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerValidationError.notAudiobookshelf
        }
        var endpoint = statusProbe()
        var path = components.percentEncodedPath
        let trailingSlash = path.hasSuffix("/") ? "/" : ""
        if !trailingSlash.isEmpty { path.removeLast() }
        let lastSlash = path.lastIndex(of: "/") ?? path.startIndex
        endpoint.path = String(path[lastSlash...]) + trailingSlash
        components.percentEncodedPath = String(path[..<lastSlash])
        components.fragment = nil
        guard let base = components.url else { throw ServerValidationError.notAudiobookshelf }
        do {
            return (try APIClientConfiguration(baseURL: base, customHeaders: customHeaders), endpoint)
        } catch {
            throw ServerValidationError.reservedHeader(error)
        }
    }

    /// Decodes a login or authorize body. The error carries no server text.
    private static func decodeAuthResponse(_ data: Data) throws(ServerValidationError) -> AuthResponse {
        do {
            return try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            throw .unexpected(.decoding("AuthResponse"))
        }
    }

    /// The client that signs in to `server`, with the cookie jar from its validation.
    func client(for server: ValidatedServer) -> APIClient {
        client(server.configuration, cookieStorage: server.cookieStorage)
    }

    /// - Parameter cookieStorage: `nil` for a new cookie jar.
    private func client(
        _ configuration: APIClientConfiguration, cookieStorage: HTTPCookieStorage? = nil
    ) -> APIClient {
        APIClient(
            configuration: configuration, tokenProvider: SignedOutTokenProvider(),
            sessionConfiguration: sessionConfiguration(), cookieStorage: cookieStorage)
    }

    private static func configuration(
        _ address: ServerAddress, customHeaders: [String: String]
    ) throws(ServerValidationError) -> APIClientConfiguration {
        do {
            return try APIClientConfiguration(baseURL: address.url, customHeaders: customHeaders)
        } catch {
            throw .reservedHeader(error)
        }
    }

    /// The same request, returning the raw body so a 3xx can be told apart from a bad body.
    private static func unparsed<Response>(_ endpoint: Endpoint<Response>) -> Endpoint<Data> {
        Endpoint<Data>(
            endpoint.method, endpoint.path, query: endpoint.query, headers: endpoint.headers, body: endpoint.body,
            requiresAuthentication: endpoint.requiresAuthentication, timeout: endpoint.timeout,
            followsRedirects: endpoint.followsRedirects, sendsCookies: endpoint.sendsCookies)
    }

    /// The server address for the URL `/status` was served from: its origin plus the path before
    /// the final `status` component, without the query.
    private static func serverAddress(statusURL: URL) throws(ServerValidationError) -> ServerAddress {
        guard var components = URLComponents(url: statusURL, resolvingAgainstBaseURL: false) else {
            throw .notAudiobookshelf
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard path.hasSuffix("/status") else { throw .notAudiobookshelf }
        path.removeLast("/status".count)
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        guard let string = components.string, let address = ServerAddress(string) else { throw .notAudiobookshelf }
        return address
    }

    /// A certificate error means the host speaks TLS, so plain `http` is not tried.
    static let certificateErrors: Set<URLError.Code> = [
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
    ]

    private static func allowsHTTPFallback(after error: APIError) -> Bool {
        switch error {
        case .timedOut: true
        case .network(let code): !certificateErrors.contains(code)
        default: false
        }
    }

    private static func statusError(_ error: APIError) -> ServerValidationError {
        switch error {
        case .notFound, .decoding: .notAudiobookshelf
        case .unauthorized: .accessDenied(status: 401)
        case .forbidden: .accessDenied(status: 403)
        case .http(let status, _): .statusFailed(status: status)
        default: genericError(error)
        }
    }

    private static func loginError(_ error: APIError) -> ServerValidationError {
        switch error {
        case .unauthorized: .invalidCredentials
        case .http(status: 429, _): .tooManyAttempts
        default: genericError(error)
        }
    }

    private static func authorizeError(_ error: APIError) -> ServerValidationError {
        switch error {
        case .sessionExpired, .notAuthenticated: .sessionExpired
        // A 403 is from a proxy (the client keeps the session), and a 401 that still reaches here
        // was not a verdict on the token, so neither means the session is over.
        case .unauthorized: .accessDenied(status: 401)
        case .forbidden: .accessDenied(status: 403)
        default: genericError(error)
        }
    }

    static func genericError(_ error: APIError) -> ServerValidationError {
        switch error {
        case .network(let code) where certificateErrors.contains(code): .untrustedCertificate
        case .network(let code): .cannotConnect(code)
        case .timedOut: .timedOut
        // The refusal could be a downgrade, another host or another port; `APIError` doesn't say.
        case .redirectRefused: .loginRedirected
        default: .unexpected(error)
        }
    }
}

/// A server that answered `GET /status` and can be signed in to.
public struct ValidatedServer: Sendable {
    /// The client configuration for ``address`` with the user's custom headers.
    public let configuration: APIClientConfiguration
    public let address: ServerAddress
    public let status: ServerStatus
    public let features: ServerFeatures
    /// The user typed no scheme, `https` couldn't connect, and the server is used over `http`.
    /// Warn before sign-in.
    public let fellBackToHTTP: Bool
    /// The cookie jar of the validation's `/status` requests, reused by
    /// ``ServerValidator/login(to:username:password:)`` and ``makeClient(tokenProvider:sessionConfiguration:)``.
    /// A new validation has a new jar.
    let cookieStorage: HTTPCookieStorage?

    /// Whether credentials would be sent unencrypted.
    public var isInsecure: Bool { address.url.scheme == "http" }

    /// The client for the account signed in to this server: ``configuration`` (base URL and
    /// custom headers) and the validation's cookie jar, so a cookie a proxy or load balancer set
    /// during validation or sign-in keeps being sent.
    ///
    /// The jar is in memory only. A client made on a later launch (from a saved connection)
    /// starts with an empty jar; recovering from a proxy that then challenges again is #172.
    /// - Parameter sessionConfiguration: Tests pass a configuration with stub protocol classes.
    public func makeClient(
        tokenProvider: any TokenProvider, sessionConfiguration: URLSessionConfiguration = .absConnection()
    ) -> APIClient {
        APIClient(
            configuration: configuration, tokenProvider: tokenProvider, sessionConfiguration: sessionConfiguration,
            cookieStorage: cookieStorage)
    }
}

/// A successful `POST /login`.
public struct LoginResult: Sendable {
    public let response: AuthResponse
    /// The pair to store for ``TokenProvider``.
    public let tokens: AuthTokens
    public let features: ServerFeatures
}

/// A successful `POST /api/authorize`.
public struct AuthorizeResult: Sendable {
    public let response: AuthResponse
    public let features: ServerFeatures
}

/// A friendly reason a server can't be connected to or signed in to.
public enum ServerValidationError: Error, Sendable, Equatable, LocalizedError {
    case invalidAddress
    case reservedHeader(CustomHeaderError)
    case cannotConnect(URLError.Code)
    case timedOut
    /// The server's certificate isn't trusted, or it requires a client certificate.
    case untrustedCertificate
    /// `https` couldn't connect and the connection has custom headers. Ask before sending them
    /// unencrypted, then validate this explicit `http` address.
    case httpsUnavailable(ServerAddress)
    /// `/status` returned 404 or something that isn't an Audiobookshelf status.
    case notAudiobookshelf
    /// `/status` or `/api/authorize` returned 401 or 403 without ending the session, usually from
    /// a proxy that needs custom headers.
    case accessDenied(status: Int)
    /// `/status` returned another error status.
    case statusFailed(status: Int)
    case redirectedToOtherHost(String)
    /// The server redirected from `https` to `http`.
    case insecureRedirect
    /// The root user hasn't been created yet.
    case serverNotInitialized
    /// The server version (`nil` if missing) is unparseable or older than the minimum.
    case unsupportedVersion(String?)
    case invalidCredentials
    case tooManyAttempts
    /// `POST /login` or `POST /api/authorize` (or its token refresh) answered with a redirect,
    /// which is not followed.
    case loginRedirected
    /// The login response had no access or refresh token.
    case missingTokens
    /// The stored session is no longer valid; the user must sign in again.
    case sessionExpired
    /// Anything else. The user sees a generic message; ``diagnosticDescription`` has details.
    case unexpected(APIError)

    // TODO: Localise these messages once ABSAPI has string catalogs.
    public var errorDescription: String? {
        let minimum = ServerFeatures.minimumSupported
        switch self {
        case .invalidAddress:
            return "Enter a server address, for example https://abs.example.com."
        case .reservedHeader(let error):
            return error.errorDescription
        case .cannotConnect, .timedOut:
            return "Couldn't connect to the server. Check the address and your network connection."
        case .untrustedCertificate:
            return "The server's security certificate isn't trusted, or the server requires a client certificate."
        case .httpsUnavailable(let address):
            return "Couldn't connect securely. To connect without encryption, use \(address). "
                + "Your custom headers and password would be sent unencrypted."
        case .notAudiobookshelf:
            return "This doesn't seem to be an Audiobookshelf server."
        case .accessDenied(let status):
            return "The server or a proxy in front of it refused access (HTTP \(status)). "
                + "Check the custom headers for this server."
        case .statusFailed(let status):
            return "Couldn't get the server's status (HTTP \(status))."
        case .redirectedToOtherHost(let host):
            return "The server redirected to a different address (\(host))."
        case .insecureRedirect:
            return "The server redirected from https to unencrypted http."
        case .serverNotInitialized:
            return "This server hasn't been set up yet. Finish setup in a web browser first."
        case .unsupportedVersion(let version?) where ServerVersion(version) != nil:
            return "This server runs Audiobookshelf \(version). Version \(minimum) or newer is required."
        case .unsupportedVersion:
            return "Couldn't determine this server's Audiobookshelf version. Version \(minimum) or newer is required."
        case .invalidCredentials:
            return "Incorrect username or password."
        case .tooManyAttempts:
            return "Too many sign-in attempts. Wait a few minutes and try again."
        case .loginRedirected:
            return "The server redirected the sign-in request. Check the server address."
        case .missingTokens:
            return "The server didn't return a sign-in token."
        case .sessionExpired:
            return "Your session has expired. Sign in again."
        case .unexpected:
            return "Something went wrong while talking to the server. Try again."
        }
    }

    /// Details for logs, never shown to the user. Server response text is left out.
    public var diagnosticDescription: String {
        guard case .unexpected(let error) = self else { return String(describing: self) }
        switch error {
        case .http(let status, _): return "unexpected(http(status: \(status)))"
        case .unauthorized: return "unexpected(unauthorized)"
        case .forbidden: return "unexpected(forbidden)"
        case .encoding: return "unexpected(encoding)"
        // `JSONDecoder` messages can quote the server's response.
        case .decoding: return "unexpected(decoding failed)"
        default: return "unexpected(\(error))"
        }
    }
}

/// The token provider for the unauthenticated clients the validator and OpenID sign-in create.
struct SignedOutTokenProvider: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}
