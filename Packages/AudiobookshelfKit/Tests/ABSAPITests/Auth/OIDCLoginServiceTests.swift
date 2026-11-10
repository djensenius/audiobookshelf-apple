import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAPI

private let statusOpenID = """
    {"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"language":"en-us",\
    "authMethods":["local","openid"],"authFormData":{"authOpenIDButtonText":"Sign in with SSO"}}
    """

private let sessionCookies = "connect.sid=s%3Asession-1; Path=/; HttpOnly, auth_method=openid-mobile; Path=/; HttpOnly"

/// The identity provider URL the stub server redirects to, carrying the server's `state`.
private func identityProviderURL(state: String, scheme: String = "https") -> String {
    var components = URLComponents(string: "\(scheme)://idp.example/application/o/authorize/")!
    components.queryItems = [
        URLQueryItem(name: "client_id", value: "abs"),
        URLQueryItem(name: "redirect_uri", value: "https://abs.example/auth/openid/mobile-redirect"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: "challenge"),
    ]
    return components.string!.replacingOccurrences(of: "+", with: "%2B")
}

/// `audiobookshelf://oauth?…`, encoded as the server's mobile redirect does.
private func callbackURL(_ items: [String: String]) -> URL {
    var components = URLComponents(string: "audiobookshelf://oauth")!
    components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url!
}

private func stubServer(
    status: String = statusOpenID,
    state: String = "server-state",
    authorize: StubResponse? = nil,
    callback: StubResponse = .json(authResponseJSON())
) -> StubServer {
    StubServer { request in
        switch request.url?.path() {
        case "/abs/status":
            return .json(status)
        case "/abs/auth/openid":
            if let authorize { return authorize }
            let location = identityProviderURL(state: state)
            return StubResponse(
                status: 302, headers: ["Location": location, "Set-Cookie": sessionCookies],
                redirect: URL(string: location))
        case "/abs/auth/openid/callback":
            return callback
        case "/abs/logout":
            return .json("{}")
        default:
            return .text("Not Found", status: 404)
        }
    }
}

/// A browser session that records the URL it opened and answers with a canned callback.
private final class FakeAuthenticator: WebAuthenticator {
    private let respond: @Sendable (URL) throws -> URL
    private let opened = Mutex<[(url: URL, scheme: String)]>([])

    init(respond: @escaping @Sendable (URL) throws -> URL) {
        self.respond = respond
    }

    /// Returns `audiobookshelf://oauth` with the opened URL's `state` and `code`.
    convenience init(code: String = "auth-code") {
        self.init { url in
            let state =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "state" }?.value ?? ""
            return callbackURL(["code": code, "state": state])
        }
    }

    var openedURLs: [(url: URL, scheme: String)] { opened.withLock { $0 } }

    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        opened.withLock { $0.append((url, callbackScheme)) }
        return try respond(url)
    }
}

private final class ClientCounter: Sendable {
    let count = Mutex(0)
}

/// Validates the stub server, then signs in with OpenID through one recorded client whose cookie
/// jar the stub emulates.
private func login(
    _ server: StubServer, address: String? = nil, authenticator: FakeAuthenticator,
    clients: ClientCounter = ClientCounter()
) async throws -> LoginResult {
    let validated = try await ServerValidator(sessionConfiguration: { server.sessionConfiguration() })
        .validate(address: address ?? "https://\(server.host)/abs")
    let service = OIDCLoginService { configuration in
        let client = APIClient(
            configuration: configuration, tokenProvider: SignedOutTokenProvider(),
            sessionConfiguration: server.sessionConfiguration())
        if let jar = client.cookieStorage { server.useCookieStorage(jar) }
        clients.count.withLock { $0 += 1 }
        return client
    }
    return try await service.login(to: validated, using: authenticator)
}

private func query(_ request: URLRequest?) -> [String: String] {
    guard let url = request?.url else { return [:] }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

@Suite struct OIDCLoginServiceTests {
    @Test func fullFlow() async throws {
        let server = stubServer()
        let authenticator = FakeAuthenticator()
        let result = try await login(server, authenticator: authenticator)

        #expect(result.tokens == AuthTokens(accessToken: "access-new", refreshToken: "refresh-new"))
        #expect(result.features.version == ServerVersion(2, 26, 0))
        #expect(result.response.user.username == "david")

        let authorize = try #require(server.requests(path: "/abs/auth/openid").first)
        let authorizeQuery = query(authorize)
        #expect(authorizeQuery["code_challenge_method"] == "S256")
        #expect(authorizeQuery["redirect_uri"] == "audiobookshelf://oauth")
        #expect(authorizeQuery["client_id"] == "Audiobookshelf-App")
        #expect(authorizeQuery["response_type"] == "code")
        #expect(authorizeQuery["state"] == nil)

        let opened = try #require(authenticator.openedURLs.first)
        #expect(opened.url.absoluteString == identityProviderURL(state: "server-state"))
        #expect(opened.scheme == "audiobookshelf")

        let callback = try #require(server.requests(path: "/abs/auth/openid/callback").first)
        let callbackQuery = query(callback)
        #expect(callbackQuery["state"] == "server-state")
        #expect(callbackQuery["code"] == "auth-code")
        let verifier = try #require(callbackQuery["code_verifier"])
        #expect(PKCE.verifierLengths.contains(verifier.count))
        #expect(PKCE.challenge(for: verifier) == authorizeQuery["code_challenge"])
        #expect(callback.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(callback.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func callbackCarriesSessionCookies() async throws {
        let server = stubServer()
        let clients = ClientCounter()
        _ = try await login(server, authenticator: FakeAuthenticator(), clients: clients)

        // One client, so one cookie jar, for both requests.
        #expect(clients.count.withLock { $0 } == 1)

        let authorize = try #require(server.requests(path: "/abs/auth/openid").first)
        #expect(authorize.value(forHTTPHeaderField: "Cookie") == nil)
        let callback = try #require(server.requests(path: "/abs/auth/openid/callback").first)
        let cookies = callback.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(cookies.contains("connect.sid=s%3Asession-1"))
        #expect(cookies.contains("auth_method=openid-mobile"))
    }

    @Test func resultKeepsSignOutCookies() async throws {
        var callback = StubResponse.json(authResponseJSON())
        callback.headers["Set-Cookie"] = "openid_id_token=eyJhbGciOi.payload.sig; Path=/; HttpOnly"
        let result = try await login(stubServer(callback: callback), authenticator: FakeAuthenticator())
        #expect(result.openIDSession?.authMethod == "openid-mobile")
        #expect(result.openIDSession?.idToken == "eyJhbGciOi.payload.sig")

        // Without the ID token the auth method alone still gets an end-session URL. A cookie that
        // `POST /logout` wouldn't receive isn't kept.
        var otherPath = StubResponse.json(authResponseJSON())
        otherPath.headers["Set-Cookie"] = "openid_id_token=other; Path=/elsewhere; HttpOnly"
        let withoutIDToken = try await login(stubServer(callback: otherPath), authenticator: FakeAuthenticator())
        #expect(withoutIDToken.openIDSession == OpenIDSessionCookies(authMethod: "openid-mobile", idToken: nil))
    }

    @Test func percentEncodesStateAndCode() async throws {
        let state = "a+b&c=d/e"
        let code = "x+y&z=w"
        let server = stubServer(state: state)
        _ = try await login(server, authenticator: FakeAuthenticator(code: code))

        let callback = try #require(server.requests(path: "/abs/auth/openid/callback").first)
        let encoded = try #require(callback.url?.query(percentEncoded: true))
        #expect(encoded.contains("state=a%2Bb%26c%3Dd/e&"))
        #expect(encoded.contains("code=x%2By%26z%3Dw&"))
        #expect(!encoded.contains("+"))
        #expect(query(callback)["state"] == state)
        #expect(query(callback)["code"] == code)
    }

    @Test func stateMismatchStops() async throws {
        let server = stubServer()
        let authenticator = FakeAuthenticator { _ in callbackURL(["code": "auth-code", "state": "attacker"]) }
        await #expect(throws: OIDCLoginError.stateMismatch) {
            try await login(server, authenticator: authenticator)
        }
        #expect(server.requests(path: "/abs/auth/openid/callback").isEmpty)
    }

    @Test(arguments: [["state": "server-state"], ["state": "server-state", "code": "undefined"]])
    func missingCode(items: [String: String]) async throws {
        let server = stubServer()
        await #expect(throws: OIDCLoginError.missingCode) {
            try await login(server, authenticator: FakeAuthenticator { _ in callbackURL(items) })
        }
        #expect(server.requests(path: "/abs/auth/openid/callback").isEmpty)
    }

    @Test func identityProviderError() async throws {
        let server = stubServer()
        let callback = callbackURL([
            "error": "access_denied", "error_description": "User is not in the allowed group", "state": "server-state",
        ])
        let error = await #expect(throws: OIDCLoginError.self) {
            try await login(server, authenticator: FakeAuthenticator { _ in callback })
        }
        #expect(error == .identityProvider(error: "access_denied", description: "User is not in the allowed group"))
        #expect(error?.localizedDescription.contains("User is not in the allowed group") == true)
        #expect(server.requests(path: "/abs/auth/openid/callback").isEmpty)
    }

    @Test func identityProviderErrorIsFiltered() throws {
        let description = "<a href=\"https://evil.example\">Call\n+1 555</a> " + String(repeating: "x", count: 300)
        let callback = callbackURL(["error": "denied<script>", "error_description": description, "state": "s"])
        let error = #expect(throws: OIDCLoginError.self) {
            try OIDCLoginService.authorizationCode(from: callback, expectedState: "s")
        }
        guard case .identityProvider(let code, let text?) = error else {
            Issue.record("Expected an identity provider error, got \(String(describing: error))")
            return
        }
        #expect(code == "deniedscript")
        #expect(text.count == 200)
        #expect(text.hasPrefix("a hrefhttps:evil.exampleCall 1 555a x"))
        #expect(!text.contains("<") && !text.contains("/") && !text.contains("\n"))
    }

    @Test(arguments: [
        ("access_denied", "access_denied"), ("invalid.scope-2", "invalid.scope-2"), ("dénied<b>", "dniedb"),
        ("\u{3164}é", "error"), (String(repeating: "a", count: 100), String(repeating: "a", count: 64)),
    ])
    func identityProviderErrorCode(raw: String, shown: String) throws {
        let callback = callbackURL(["error": raw, "state": "s"])
        #expect(throws: OIDCLoginError.identityProvider(error: shown, description: nil)) {
            try OIDCLoginService.authorizationCode(from: callback, expectedState: "s")
        }
    }

    @Test func displayTextCapsCombiningMarks() throws {
        let stacked = "e" + String(repeating: "\u{0301}", count: 50) + "x"
        let text = try #require(OIDCLoginService.displayText(stacked, limit: 200))
        #expect(text.unicodeScalars.count == 4)
        #expect(text == "e\u{0301}\u{0301}x")
        // A mark with no base character is dropped.
        #expect(OIDCLoginService.displayText("\u{0301}\u{0301}", limit: 200) == nil)

        // Within the character limit, but over `limit × 2` scalars.
        let long = String(repeating: "a\u{0301}\u{0300}", count: 150)
        let limited = try #require(OIDCLoginService.displayText(long, limit: 200))
        #expect(limited.unicodeScalars.count <= 400)
        #expect(limited.hasSuffix("…"))
    }

    @Test func displayTextDropsInvisibleCharacters() {
        let hidden = "a\u{3164}b\u{115F}\u{1160}c\u{FFA0}d\u{FE0F}e\u{034F}f\u{FE00}"
        #expect(OIDCLoginService.displayText(hidden, limit: 200) == "abcdef")
        #expect(OIDCLoginService.displayText("\u{3164}\u{3164} \u{FFA0}", limit: 200) == nil)
        // Right-to-left letters stay.
        #expect(OIDCLoginService.displayText("مرحبا שלום", limit: 200) == "مرحبا שלום")
        #expect(OIDCLoginService.displayText("abc", limit: 3) == "abc")
        #expect(OIDCLoginService.displayText("abcd", limit: 3) == "ab…")
    }

    @Test func errorCallbackWithWrongStateIsStateMismatch() async throws {
        let server = stubServer()
        let callback = callbackURL(["error": "access_denied", "error_description": "Call +1 555", "state": "attacker"])
        await #expect(throws: OIDCLoginError.stateMismatch) {
            try await login(server, authenticator: FakeAuthenticator { _ in callback })
        }
        #expect(server.requests(path: "/abs/auth/openid/callback").isEmpty)
    }

    @Test func cancellation() async throws {
        let server = stubServer()
        await #expect(throws: OIDCLoginError.cancelled) {
            try await login(server, authenticator: FakeAuthenticator { _ in throw OIDCLoginError.cancelled })
        }
        await #expect(throws: OIDCLoginError.cancelled) {
            try await login(server, authenticator: FakeAuthenticator { _ in throw CancellationError() })
        }
        await #expect(throws: OIDCLoginError.browserFailed) {
            try await login(server, authenticator: FakeAuthenticator { _ in throw URLError(.unknown) })
        }
        #expect(server.requests(path: "/abs/auth/openid/callback").isEmpty)
    }

    @Test func rejectsHTTPIdentityProviderForHTTPSServer() async throws {
        let location = identityProviderURL(state: "server-state", scheme: "http")
        let server = stubServer(authorize: .redirect(to: location))
        let authenticator = FakeAuthenticator()
        await #expect(throws: OIDCLoginError.insecureAuthorizationURL) {
            try await login(server, authenticator: authenticator)
        }
        #expect(authenticator.openedURLs.isEmpty)
    }

    @Test func allowsHTTPIdentityProviderForHTTPServer() async throws {
        let location = identityProviderURL(state: "server-state", scheme: "http")
        let server = stubServer(authorize: .redirect(to: location))
        let authenticator = FakeAuthenticator()
        _ = try await login(server, address: "http://\(server.host)/abs", authenticator: authenticator)
        #expect(authenticator.openedURLs.first?.url.scheme == "http")
    }

    @Test(arguments: [
        (StubResponse(status: 302), OIDCLoginError.invalidAuthorizationURL),
        (.redirect(to: "https://idp.example/authorize?client_id=abs"), .invalidAuthorizationURL),
        (.json("{}"), .authorizationFailed(status: 200)),
        (.text("Invalid redirect_uri", status: 400), .authorizationFailed(status: 400)),
    ])
    func unusableAuthorizationResponse(response: StubResponse, expected: OIDCLoginError) async throws {
        let server = stubServer(authorize: response)
        let authenticator = FakeAuthenticator()
        await #expect(throws: expected) {
            try await login(server, authenticator: authenticator)
        }
        #expect(authenticator.openedURLs.isEmpty)
    }

    @Test func resolvesRelativeLocationAgainstServer() async throws {
        let server = stubServer(
            authorize: StubResponse(
                status: 302, headers: ["Location": "../idp/authorize?state=server-state", "Set-Cookie": sessionCookies])
        )
        let authenticator = FakeAuthenticator()
        _ = try await login(server, authenticator: authenticator)
        let opened = try #require(authenticator.openedURLs.first)
        #expect(opened.url.absoluteString == "https://\(server.host)/abs/idp/authorize?state=server-state")
        #expect(server.requests(path: "/abs/auth/openid/callback").count == 1)
    }

    @Test func tooManyAttemptsFromAuthorize() async throws {
        let server = stubServer(authorize: .text("Too many requests", status: 429))
        let authenticator = FakeAuthenticator()
        await #expect(throws: ServerValidationError.tooManyAttempts) {
            try await login(server, authenticator: authenticator)
        }
        #expect(authenticator.openedURLs.isEmpty)
    }

    @Test func openIDNotEnabled() async throws {
        let server = stubServer(status: statusOpenID.replacingOccurrences(of: #","openid""#, with: ""))
        await #expect(throws: OIDCLoginError.notEnabled) {
            try await login(server, authenticator: FakeAuthenticator())
        }
        #expect(server.requests(path: "/abs/auth/openid").isEmpty)
    }

    @Test(arguments: [
        (StubResponse.text("No session", status: 400), OIDCLoginError.sessionLost),
        (.text("Unauthorized", status: 401), .rejected),
        (.text("Error in callback", status: 500), .callbackFailed(status: 500)),
        // What 2.26.0–2.37.2 send for every refusal after the session check.
        (.redirect(to: "/login?error=Unauthorized&autoLaunch=0"), .serverRefused(message: "Unauthorized")),
        (
            .redirect(to: "/login?error=User%20not%20found%20%3Cb%3E%2Fx&autoLaunch=0", status: 302),
            .serverRefused(message: "User not found bx")
        ),
        (StubResponse(status: 302, headers: ["Location": "/login?autoLaunch=0"]), .serverRefused(message: nil)),
        (StubResponse(status: 302), .serverRefused(message: nil)),
        // Only the server's own sign-in page may supply the message.
        (
            StubResponse(status: 302, headers: ["Location": "https://evil.example/login?error=Call"]),
            .serverRefused(message: nil)
        ),
        (StubResponse(status: 302, headers: ["Location": "/abs/other?error=Call"]), .serverRefused(message: nil)),
    ])
    func callbackFailures(response: StubResponse, expected: OIDCLoginError) async throws {
        let server = stubServer(callback: response)
        await #expect(throws: expected) {
            try await login(server, authenticator: FakeAuthenticator())
        }
        // Nothing follows the callback: not the redirect, and not a logout.
        #expect(server.requests.last?.url?.path() == "/abs/auth/openid/callback")
        #expect(server.requests(path: "/login").isEmpty)
    }

    @Test(arguments: [
        ("/login?error=Unauthorized", "Unauthorized"), ("/abs/login?error=Unauthorized", "Unauthorized"),
        ("https://abs.example:443/login?error=Unauthorized", "Unauthorized"),
        ("http://abs.example/login?error=Unauthorized", nil),
        ("https://abs.example:8443/login?error=Unauthorized", nil),
        ("https://evil.example/login?error=Unauthorized", nil), ("/login/other?error=Unauthorized", nil),
    ])
    func refusalMessageNeedsServerLoginPage(location: String, message: String?) throws {
        let callback = try #require(URL(string: "https://abs.example/abs/auth/openid/callback?state=s"))
        let response = try #require(
            HTTPURLResponse(
                url: callback, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location]))
        let server = try #require(URL(string: "https://abs.example/abs"))
        #expect(OIDCLoginService.refusal(from: response, server: server) == .serverRefused(message: message))
    }

    @Test func tooManyAttemptsFromCallback() async throws {
        let server = stubServer(callback: .text("Too many requests", status: 429))
        await #expect(throws: ServerValidationError.tooManyAttempts) {
            try await login(server, authenticator: FakeAuthenticator())
        }
    }

    @Test func versionGateAppliesAfterCallback() async throws {
        let server = stubServer(callback: .json(authResponseJSON(version: "2.25.0")))
        await #expect(throws: ServerValidationError.unsupportedVersion("2.25.0")) {
            try await login(server, authenticator: FakeAuthenticator())
        }
        let logout = try #require(server.requests(path: "/abs/logout").first)
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new")
        #expect(logout.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func missingTokensAfterCallback() async throws {
        let server = stubServer(callback: .json(authResponseJSON(tokens: false)))
        await #expect(throws: ServerValidationError.missingTokens) {
            try await login(server, authenticator: FakeAuthenticator())
        }
    }

    @Test(arguments: [
        "https://oauth?code=c&state=s", "audiobookshelf://login?code=c&state=s",
        "audiobookshelf://oauth?code=c&state=s&state=s", "audiobookshelf://oauth/extra?code=c&state=s",
        "audiobookshelf://oauth:8080?code=c&state=s", "audiobookshelf://user@oauth?code=c&state=s",
        "audiobookshelf://user:pass@oauth?code=c&state=s", "audiobookshelf://oauth?code=c&state=s#fragment",
    ])
    func invalidCallbackURL(url: String) throws {
        #expect(throws: OIDCLoginError.invalidCallback) {
            try OIDCLoginService.authorizationCode(from: URL(string: url)!, expectedState: "s")
        }
    }

    @Test(arguments: ["audiobookshelf://oauth?code=c&state=s", "audiobookshelf://oauth/?code=c&state=s"])
    func validCallbackURL(url: String) throws {
        #expect(try OIDCLoginService.authorizationCode(from: URL(string: url)!, expectedState: "s") == "c")
    }

    @Test func errorsNeverIncludeSecrets() throws {
        let callback = callbackURL(["code": "secret-code", "state": "other"])
        let error = #expect(throws: OIDCLoginError.self) {
            try OIDCLoginService.authorizationCode(from: callback, expectedState: "secret-state")
        }
        let text = "\(String(describing: error)) \(error?.localizedDescription ?? "")"
        #expect(!text.contains("secret"))
    }
}
