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
/// The server's `auth_method=openid-mobile` and `openid_id_token` cookies live only in that
/// jar, which is discarded after sign-in. `POST /logout` reads the auth method and ID token only
/// from those cookies to build the identity provider's end-session `redirect_url`, so their
/// values are returned in ``LoginResult/openIDSession`` for the account to store and send on
/// sign-out.
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
        if (300..<400).contains(reply.httpResponse.statusCode) {
            throw Self.refusal(from: reply.httpResponse, server: server.configuration.baseURL)
        }
        var result = try await ServerValidator.loginResult(from: reply, client: client)
        // Only the cookies the server would get on `POST /logout`.
        let logoutURL = try? APIClient.url(base: server.configuration.baseURL, path: "/logout", query: [])
        result.openIDSession = OpenIDSessionCookies(
            cookies: logoutURL.flatMap { client.cookieStorage?.cookies(for: $0) } ?? [])
        return result
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
    ///
    /// `state` is checked before anything else (RFC 6749 §4.1.2.1), so a page in the browser
    /// session can't make up an error by navigating to `audiobookshelf://oauth?error=…`.
    static func authorizationCode(from url: URL, expectedState: String) throws(OIDCLoginError) -> String {
        let path = url.path(percentEncoded: true)
        guard url.scheme?.lowercased() == callbackScheme, url.host()?.lowercased() == callbackHost,
            path.isEmpty || path == "/", url.port == nil, url.user() == nil, url.password() == nil,
            url.fragment() == nil
        else { throw .invalidCallback }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) throws(OIDCLoginError) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count <= 1 else { throw .invalidCallback }
            return values.first?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard try value("state") == expectedState else { throw .stateMismatch }
        if let error = try value("error") {
            throw .identityProvider(
                error: errorCode(error) ?? "error",
                description: displayText(try value("error_description"), limit: 200))
        }
        // The server's mobile redirect forwards only `code` and `state`, and writes a missing code
        // as the string "undefined" (`encodeURIComponent(undefined)`).
        guard let code = try value("code"), code != "undefined" else { throw .missingCode }
        return code
    }

    /// The error for a redirect from `/auth/openid/callback`.
    ///
    /// Audiobookshelf 2.26.0–2.37.2 answer every failure after the session check (a code the
    /// identity provider refuses, a user that isn't allowed or doesn't exist) with
    /// `302 /login?error=<message>&autoLaunch=0`: `passportCallback` treats the request as
    /// mobile only if `req.session[…].mobile === true`, but `mobile` holds the redirect URI.
    /// The message is read only from a redirect to the server's own `…/login` page.
    static func refusal(from response: HTTPURLResponse, server: URL) -> OIDCLoginError {
        guard
            let location = response.value(forHTTPHeaderField: "Location")
                .flatMap({ URL(string: $0, relativeTo: response.url)?.absoluteURL }),
            sameOrigin(location, server), location.path(percentEncoded: true).hasSuffix("/login")
        else { return .serverRefused(message: nil) }
        return .serverRefused(message: displayText(queryValue("error", in: location), limit: 200))
    }

    private static func sameOrigin(_ url: URL, _ other: URL) -> Bool {
        func origin(_ url: URL) -> (String?, String?, Int?) {
            let scheme = url.scheme?.lowercased()
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
            return (scheme, url.host()?.lowercased(), port)
        }
        return origin(url) == origin(other)
    }

    /// An OAuth `error` code (RFC 6749 §5.2) for display: ASCII letters, digits, `_`, `.` and
    /// `-` only, at most 64 characters.
    static func errorCode(_ text: String) -> String? {
        let code = String(text.unicodeScalars.filter { $0.isASCII && errorCodeCharacters.contains($0) }.prefix(64))
        return code.isEmpty ? nil : code
    }

    private static let errorCodeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    private static let displayCharacters = CharacterSet.letters.union(.decimalDigits)
        .union(CharacterSet(charactersIn: " .,:;'()-_!?"))
        .subtracting(invisibleCharacters)
    /// Letters and marks that render as nothing: Hangul fillers, the combining grapheme joiner
    /// and variation selectors.
    private static let invisibleCharacters = CharacterSet(charactersIn: "\u{115F}\u{1160}\u{3164}\u{FFA0}\u{034F}")
        .union(CharacterSet(charactersIn: "\u{FE00}"..."\u{FE0F}"))
    /// Combining marks kept after each base character.
    private static let maxMarksPerBase = 2

    /// Text from a URL that may be shown to the user: letters, digits, spaces and basic
    /// punctuation only, without invisible letters, at most two combining marks per base
    /// character, whitespace collapsed, and at most `limit` characters and `limit × 2` scalars.
    static func displayText(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        var marks = 0
        for scalar in text.unicodeScalars {
            let scalar = CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : scalar
            guard displayCharacters.contains(scalar) else { continue }
            if CharacterSet.nonBaseCharacters.contains(scalar) {
                // Drop marks with no base and marks beyond the cap.
                guard let last = scalars.last, last != " ", marks < maxMarksPerBase else { continue }
                marks += 1
            } else {
                marks = 0
            }
            scalars.append(scalar)
        }
        let words = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        guard words.count > limit || words.unicodeScalars.count > limit * 2 else { return words }
        // Leave room for the ellipsis.
        var limited = ""
        var scalarCount = 0
        for character in words {
            scalarCount += character.unicodeScalars.count
            guard limited.count < limit - 1, scalarCount < limit * 2 else { break }
            limited.append(character)
        }
        return limited + "…"
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
    /// The identity provider reported an error (`error` and `error_description`, filtered and
    /// shortened for display) in a callback with the right `state`.
    case identityProvider(error: String, description: String?)
    /// The callback's `state` doesn't match the identity provider URL's.
    case stateMismatch
    /// The callback has no authorization code.
    case missingCode
    /// The server no longer has the sign-in session (`400 No session`).
    case sessionLost
    /// The server or identity provider rejected the authorization code (401).
    case rejected
    /// The server redirected the callback to its sign-in page with this `error`, as 2.26.0–2.37.2
    /// do for every refusal. The message is filtered and shortened for display.
    case serverRefused(message: String?)
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
        case .serverRefused(let message?):
            "The server refused the sign-in (\(message)). Check that your account may use single sign-on, "
                + "or ask the server's administrator."
        case .serverRefused(nil):
            "The server refused the sign-in. Check that your account may use single sign-on, "
                + "or ask the server's administrator."
        case .callbackFailed(let status):
            "The server couldn't finish single sign-on (HTTP \(status)). Check the server's OpenID settings."
        }
    }
}
