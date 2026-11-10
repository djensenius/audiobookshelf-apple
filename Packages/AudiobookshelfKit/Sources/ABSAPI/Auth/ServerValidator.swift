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

    /// - Parameter sessionConfiguration: Tests return a configuration with stub protocol classes.
    public init(sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() }) {
        self.sessionConfiguration = sessionConfiguration
    }

    /// Normalizes `input` and reads `GET /status`.
    ///
    /// When the user typed no scheme, `https` is tried first and plain `http` only after a
    /// connection failure (never after an HTTP response); the result then has
    /// ``ValidatedServer/fellBackToHTTP`` set so the UI can warn.
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
            let configuration = try Self.configuration(candidate, customHeaders: customHeaders)
            let reply: APIResponse<ServerStatus>
            do {
                reply = try await client(configuration).response(for: AuthEndpoints.status())
            } catch let error as APIError {
                if index < candidates.count - 1, Self.isConnectionFailure(error) { continue }
                throw Self.statusError(error)
            }
            let address = try Self.resolvedAddress(candidate, finalURL: reply.httpResponse.url)
            let status = reply.value
            guard status.isInit else { throw ServerValidationError.serverNotInitialized }
            let features = try Self.features(serverVersion: status.serverVersion)
            return ValidatedServer(
                configuration: try Self.configuration(address, customHeaders: customHeaders),
                address: address, status: status, features: features, fellBackToHTTP: index > 0)
        }
        // `candidates` is not empty, so the loop always returns or throws.
        throw ServerValidationError.invalidAddress
    }

    /// Signs in with `POST /login` and returns the user, the token pair to store, and the
    /// server's version gates.
    public func login(to server: ValidatedServer, username: String, password: String) async throws -> LoginResult {
        let response: AuthResponse
        do {
            response = try await client(server.configuration)
                .send(AuthEndpoints.login(username: username, password: password))
        } catch let error as APIError {
            throw Self.loginError(error)
        }
        let features = try Self.features(of: response)
        guard let tokens = response.sessionTokens else { throw ServerValidationError.missingTokens }
        return LoginResult(response: response, tokens: tokens, features: features)
    }

    /// Calls `POST /api/authorize` with `client`'s stored tokens and re-checks the version, so
    /// a downgraded server is caught on launch.
    public func authorize(with client: APIClient) async throws -> AuthorizeResult {
        let response: AuthResponse
        do {
            response = try await client.send(AuthEndpoints.authorize())
        } catch let error as APIError {
            throw Self.genericError(error)
        }
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

    private func client(_ configuration: APIClientConfiguration) -> APIClient {
        APIClient(
            configuration: configuration, tokenProvider: SignedOutTokenProvider(),
            sessionConfiguration: sessionConfiguration())
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

    /// Rejects a `/status` that was redirected to another host. A same-host upgrade to `https`
    /// is kept so later requests don't depend on the redirect; the client never follows a
    /// downgrade to `http`.
    private static func resolvedAddress(
        _ candidate: ServerAddress, finalURL: URL?
    ) throws(ServerValidationError) -> ServerAddress {
        guard let finalURL else { return candidate }
        let host = finalURL.host()?.lowercased() ?? ""
        guard host == candidate.url.host()?.lowercased() else { throw .redirectedToOtherHost(host) }
        guard finalURL.scheme?.lowercased() != candidate.url.scheme,
            var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)
        else { return candidate }
        var path = components.percentEncodedPath
        if path.hasSuffix("/status") { path.removeLast("/status".count) }
        components.percentEncodedPath = path
        components.query = nil
        return components.string.flatMap { ServerAddress($0) } ?? candidate
    }

    private static func isConnectionFailure(_ error: APIError) -> Bool {
        switch error {
        case .network, .timedOut: true
        default: false
        }
    }

    private static func statusError(_ error: APIError) -> ServerValidationError {
        switch error {
        case .notFound, .decoding: .notAudiobookshelf
        case .http(let status, _): .statusFailed(status: status)
        case .unauthorized: .statusFailed(status: 401)
        case .forbidden: .statusFailed(status: 403)
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

    private static func genericError(_ error: APIError) -> ServerValidationError {
        switch error {
        case .network(let code): .cannotConnect(code)
        case .timedOut: .timedOut
        case .redirectRefused: .insecureRedirect
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
    /// The user typed no scheme, `https` couldn't connect, and `http` did. Warn before sign-in.
    public let fellBackToHTTP: Bool

    /// Whether credentials would be sent unencrypted.
    public var isInsecure: Bool { address.url.scheme == "http" }
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
    /// `/status` returned 404 or something that isn't an Audiobookshelf status.
    case notAudiobookshelf
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
    /// The login response had no access or refresh token.
    case missingTokens
    case unexpected(APIError)

    public var errorDescription: String? {
        let minimum = ServerFeatures.minimumSupported
        switch self {
        case .invalidAddress:
            return "Enter a server address, for example https://abs.example.com."
        case .reservedHeader(let error):
            return error.errorDescription
        case .cannotConnect, .timedOut:
            return "Couldn't connect to the server. Check the address and your network connection."
        case .notAudiobookshelf:
            return "This doesn't seem to be an Audiobookshelf server."
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
        case .missingTokens:
            return "The server didn't return a sign-in token."
        case .unexpected(let error):
            return "Something went wrong (\(error))."
        }
    }
}

/// The token provider for the unauthenticated clients the validator creates.
private struct SignedOutTokenProvider: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}
