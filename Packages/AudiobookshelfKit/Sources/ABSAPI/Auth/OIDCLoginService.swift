import ABSCore
import Foundation

/// Opens an identity provider's sign-in page in a browser session.
///
/// The app implements this with SwiftUI's `WebAuthenticationSession`; tests use a fake.
public protocol WebAuthenticator: Sendable {
    /// Loads `url` and returns the first URL the session navigates to with `callbackScheme`.
    ///
    /// Throws ``OIDCLoginError/cancelled`` (or `CancellationError`) when the user closes the
    /// browser session.
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL
}

/// Signs in with the server's OpenID Connect mobile flow, using PKCE.
///
/// 1. `GET /auth/openid` with the PKCE challenge and `redirect_uri=audiobookshelf://oauth`. The
///    server stores the challenge in its session and redirects to the identity provider; the
///    redirect is not followed, and the identity provider's URL is read from `Location`.
/// 2. The ``WebAuthenticator`` opens that URL. After sign-in the identity provider redirects to
///    the server's `/auth/openid/mobile-redirect`, which redirects to
///    `audiobookshelf://oauth?code=…&state=…`.
/// 3. The callback's `state` must equal the `state` in the identity provider URL, which the
///    server generated.
/// 4. `GET /auth/openid/callback` with the state, code and PKCE verifier. The server exchanges
///    the code and answers like `POST /login`, including the refresh token.
///
/// The server keeps the OpenID state in its session cookie, so steps 1 and 4 go through one
/// ``APIClient`` and its cookie jar. The code, verifier, state and tokens are never logged.
///
/// Methods throw ``OIDCLoginError`` for problems specific to OpenID,
/// ``ServerValidationError`` for the failures password sign-in shares (connection, version
/// gate, missing tokens), or `CancellationError`. The UI ignores
/// ``OIDCLoginError/cancelled`` and `CancellationError`.
public struct OIDCLoginService: Sendable {
    /// The app's callback URL scheme, which `WebAuthenticationSession` intercepts.
    public static let callbackScheme = "audiobookshelf"
    /// The only mobile redirect URI the server allows by default
    /// (`authOpenIDMobileRedirectURIs`).
    static let redirectURI = "audiobookshelf://oauth"
    static let callbackHost = "oauth"
    static let clientID = "Audiobookshelf-App"

    private let makeClient: @Sendable (APIClientConfiguration) -> APIClient

    /// - Parameter sessionConfiguration: Tests return a configuration with stub protocol classes.
    public init(sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() }) {
        self.init { configuration in
            APIClient(
                configuration: configuration, tokenProvider: SignedOutTokenProvider(),
                sessionConfiguration: sessionConfiguration())
        }
    }

    /// - Parameter makeClient: Creates the unauthenticated client for one sign-in. Tests use it to
    ///   reach the client's cookie jar.
    init(makeClient: @escaping @Sendable (APIClientConfiguration) -> APIClient) {
        self.makeClient = makeClient
    }

    /// Signs in to `server` through its OpenID provider and returns the user, the token pair to
    /// store, and the server's version gates.
    public func login(to server: ValidatedServer, using authenticator: any WebAuthenticator) async throws
        -> LoginResult
    {
        guard server.status.supportsOpenID else { throw OIDCLoginError.notEnabled }
        // One client, and so one cookie jar, for the whole flow.
        let client = makeClient(server.configuration)
        let pkce = PKCE()

        let authorizationURL = try await authorizationURL(client: client, server: server, pkce: pkce)
        guard let state = Self.queryValue("state", in: authorizationURL), !state.isEmpty else {
            throw OIDCLoginError.invalidAuthorizationURL
        }

        let callbackURL: URL
        do {
            callbackURL = try await authenticator.authenticate(authorizationURL, callbackScheme: Self.callbackScheme)
        } catch let error as OIDCLoginError {
            throw error
        } catch is CancellationError {
            throw OIDCLoginError.cancelled
        } catch {
            throw OIDCLoginError.browserFailed
        }
        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)

        let reply: APIResponse<Data>
        do {
            reply = try await client.response(for: Self.callback(state: state, code: code, verifier: pkce.verifier))
        } catch let error as APIError {
            throw Self.callbackError(error)
        }
        return try await ServerValidator.loginResult(from: reply, client: client)
    }

    // MARK: - Endpoints

    /// `GET /auth/openid` for the mobile flow. The server answers with a redirect to the
    /// identity provider and sets its session cookies.
    static func authorize(challenge: String) -> Endpoint<Data> {
        Endpoint(
            .get, "/auth/openid",
            query: [
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: PKCE.method),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
            ],
            requiresAuthentication: false, followsRedirects: false)
    }

    /// `GET /auth/openid/callback`. ``APIClient`` percent-encodes every value, including `+`.
    ///
    /// The server returns the refresh token in the body because `/auth/openid` set its
    /// `auth_method` cookie to `openid-mobile`; `x-return-tokens` is sent as on `/login`.
    static func callback(state: String, code: String, verifier: String) -> Endpoint<Data> {
        Endpoint(
            .get, "/auth/openid/callback",
            query: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "code_verifier", value: verifier),
            ],
            headers: ["x-return-tokens": "true"],
            requiresAuthentication: false, followsRedirects: false)
    }

    // MARK: - Steps

    private func authorizationURL(client: APIClient, server: ValidatedServer, pkce: PKCE) async throws -> URL {
        let reply: APIResponse<Data>
        do {
            reply = try await client.response(for: Self.authorize(challenge: pkce.challenge))
        } catch let error as APIError {
            throw Self.authorizeError(error)
        }
        let http = reply.httpResponse
        guard (300..<400).contains(http.statusCode) else {
            throw OIDCLoginError.authorizationFailed(status: http.statusCode)
        }
        guard
            let location = http.value(forHTTPHeaderField: "Location"),
            let url = URL(string: location, relativeTo: http.url)?.absoluteURL,
            url.host()?.isEmpty == false
        else { throw OIDCLoginError.invalidAuthorizationURL }

        let scheme = url.scheme?.lowercased()
        let allowsHTTP = server.configuration.baseURL.scheme?.lowercased() == "http"
        guard scheme == "https" || (scheme == "http" && allowsHTTP) else {
            throw OIDCLoginError.insecureAuthorizationURL
        }
        return url
    }

    /// Checks the callback and returns its authorization code.
    static func authorizationCode(from url: URL, expectedState: String) throws(OIDCLoginError) -> String {
        guard url.scheme?.lowercased() == callbackScheme, url.host()?.lowercased() == callbackHost else {
            throw .invalidCallback
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) throws(OIDCLoginError) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count <= 1 else { throw .invalidCallback }
            return values.first?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        if let error = try value("error") {
            throw .identityProvider(error: error, description: try value("error_description"))
        }
        guard try value("state") == expectedState else { throw .stateMismatch }
        // The server's mobile redirect forwards only `code` and `state`, and writes a missing code
        // as the string "undefined" (`encodeURIComponent(undefined)`).
        guard let code = try value("code"), code != "undefined" else { throw .missingCode }
        return code
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = items.filter { $0.name == name }
        return values.count == 1 ? values[0].value : nil
    }

    // MARK: - Errors

    private static func authorizeError(_ error: APIError) -> any Error {
        switch error {
        case .http(status: 429, _): ServerValidationError.tooManyAttempts
        case .unauthorized: OIDCLoginError.authorizationFailed(status: 401)
        case .forbidden: OIDCLoginError.authorizationFailed(status: 403)
        case .notFound: OIDCLoginError.authorizationFailed(status: 404)
        case .http(let status, _): OIDCLoginError.authorizationFailed(status: status)
        default: ServerValidator.genericError(error)
        }
    }

    private static func callbackError(_ error: APIError) -> any Error {
        switch error {
        // "No session": the session cookie from `/auth/openid` was lost or expired.
        case .http(status: 400, _): OIDCLoginError.sessionLost
        // The identity provider refused the code or verifier.
        case .unauthorized: OIDCLoginError.rejected
        case .http(status: 429, _): ServerValidationError.tooManyAttempts
        case .http(let status, _) where status >= 500: OIDCLoginError.callbackFailed(status: status)
        default: ServerValidator.genericError(error)
        }
    }
}

/// A reason OpenID sign-in failed, with a message the connect screen can show.
public enum OIDCLoginError: Error, Sendable, Equatable, LocalizedError {
    /// The user closed the browser session. Not an error to show.
    case cancelled
    /// The server's status doesn't list OpenID as a sign-in method.
    case notEnabled
    /// `GET /auth/openid` didn't redirect to the identity provider.
    case authorizationFailed(status: Int)
    /// The redirect had no usable `Location` or no `state`.
    case invalidAuthorizationURL
    /// The identity provider's URL isn't `https` (plain `http` is accepted only for an `http`
    /// server).
    case insecureAuthorizationURL
    /// The browser session failed for a reason other than cancellation.
    case browserFailed
    /// The browser returned to something other than `audiobookshelf://oauth`, or a parameter
    /// was repeated.
    case invalidCallback
    /// The identity provider reported an error (`error` and `error_description`).
    case identityProvider(error: String, description: String?)
    /// The callback's `state` doesn't match the identity provider URL's.
    case stateMismatch
    /// The callback has no authorization code.
    case missingCode
    /// The server no longer has the sign-in session (`400 No session`).
    case sessionLost
    /// The server or identity provider rejected the authorization code (401).
    case rejected
    /// The server failed while finishing the sign-in.
    case callbackFailed(status: Int)

    // TODO: Localise these messages once ABSAPI has string catalogs.
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign-in was cancelled."
        case .notEnabled:
            "This server doesn't have single sign-on (OpenID) enabled."
        case .authorizationFailed(let status):
            "The server couldn't start single sign-on (HTTP \(status)). Check that OpenID is enabled and that "
                + "audiobookshelf://oauth is an allowed mobile redirect URI."
        case .invalidAuthorizationURL:
            "The server's single sign-on response was incomplete. Check the server's OpenID settings."
        case .insecureAuthorizationURL:
            "The identity provider doesn't use a secure (https) connection."
        case .browserFailed:
            "Couldn't open the sign-in page. Try again."
        case .invalidCallback, .stateMismatch:
            "The sign-in response was invalid. Try again."
        case .identityProvider(let error, let description?):
            "The identity provider reported an error: \(description) (\(error))."
        case .identityProvider(let error, nil):
            "The identity provider reported an error: \(error)."
        case .missingCode:
            "The identity provider didn't complete the sign-in. Try again."
        case .sessionLost:
            "The sign-in took too long or was interrupted. Try again."
        case .rejected:
            "The server couldn't verify the sign-in with the identity provider. Try again."
        case .callbackFailed(let status):
            "The server couldn't finish single sign-on (HTTP \(status)). Check the server's OpenID settings."
        }
    }
}
