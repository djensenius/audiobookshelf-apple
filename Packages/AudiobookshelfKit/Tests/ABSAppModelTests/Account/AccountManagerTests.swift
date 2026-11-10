import ABSCore
import ABSData
import Foundation
import Security
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel

/// An Audiobookshelf server on a unique stub host. It accepts only the latest token pair, issues
/// a new one on each sign-in, and rotates it on `POST /auth/refresh`, like the real server.
private final class FakeServer: Sendable {
    struct State {
        var isOffline = false
        var accessToken = ""
        var refreshToken = ""
        var issued = 0
        /// Answers `/api/authorize` with this status, as a proxy might.
        var authorizeStatus: Int?
        var logoutRedirect: String?
        /// A proxy in front of the server: it puts `lb=1` in this jar on `/status` and refuses
        /// anything else until the jar holds it. The stub transport doesn't use the client's jar,
        /// so tests check that the client uses this one.
        var proxyJar: HTTPCookieStorage?

        mutating func issueTokens() {
            issued += 1
            accessToken = "access-\(issued)"
            refreshToken = "refresh-\(issued)"
        }
    }

    let host = "\(UUID().uuidString.lowercased()).stub.test"
    let userId: String
    private let state = Mutex(State())

    init(userId: String = "usr-1") {
        self.userId = userId
        StubURLProtocol.register(host: host) { [self] request in respond(to: request) }
    }

    var address: String { "https://\(host)/abs" }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func requests(_ path: String) -> [URLRequest] {
        StubURLProtocol.requests(host: host).filter { $0.url?.path() == "/abs\(path)" }
    }

    /// The `x-refresh-token` of each `POST /logout`.
    var loggedOutRefreshTokens: [String?] {
        requests("/logout").map { $0.value(forHTTPHeaderField: "x-refresh-token") }
    }

    /// Holds the next request for `path` until the gate opens.
    func hold(_ path: String) -> StubGate {
        StubURLProtocol.hold(host: host, path: "/abs\(path)")
    }

    /// The server forgets the access token, so the next request refreshes.
    func expireAccessToken() {
        update { $0.accessToken = "access-expired" }
    }

    /// The server rejects both tokens, so the refresh fails.
    func revokeSession() {
        update {
            $0.accessToken = "revoked"
            $0.refreshToken = "revoked"
        }
    }

    private func respond(to request: URLRequest) -> StubResponse {
        state.withLock { state in
            guard !state.isOffline else { return .failure(.notConnectedToInternet) }
            if let jar = state.proxyJar, let url = request.url,
                jar.cookies(for: url)?.contains(where: { $0.name == "lb" }) != true
            {
                guard url.path() == "/abs/status" else { return .json("{}", status: 403) }
                jar.setCookies(
                    HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "lb=1; Path=/"], for: url), for: url,
                    mainDocumentURL: nil)
            }
            switch request.url?.path() {
            case "/abs/status":
                return .json(
                    #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local","openid"]}"#
                )
            case "/abs/login":
                state.issueTokens()
                return .json(Self.authJSON(userId: userId, tokens: state))
            case "/abs/auth/openid":
                return StubResponse(
                    status: 302,
                    headers: [
                        "Location": "https://idp.example/authorize?state=idp-state",
                        "Set-Cookie": "auth_method=openid-mobile; Path=/; HttpOnly",
                    ])
            case "/abs/auth/openid/callback":
                state.issueTokens()
                return .json(
                    Self.authJSON(userId: userId, tokens: state),
                    headers: ["Set-Cookie": "openid_id_token=id.token.sig; Path=/; HttpOnly"])
            case "/abs/api/authorize":
                if let status = state.authorizeStatus { return .json("{}", status: status) }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(state.accessToken)" else {
                    return .json("{}", status: 401)
                }
                return .json(Self.authJSON(userId: userId, tokens: nil))
            case "/abs/auth/refresh":
                guard request.value(forHTTPHeaderField: "x-refresh-token") == state.refreshToken else {
                    return .json("{}", status: 401)
                }
                state.issueTokens()
                return .json(Self.authJSON(userId: userId, tokens: state))
            case "/abs/logout":
                return .json(#"{"redirect_url":\#(state.logoutRedirect.map { "\"\($0)\"" } ?? "null")}"#)
            default:
                return .json("{}", status: 404)
            }
        }
    }

    static func authJSON(userId: String, tokens state: State?, version: String = "2.26.0") -> String {
        let tokens = state.map { #","accessToken":"\#($0.accessToken)","refreshToken":"\#($0.refreshToken)""# } ?? ""
        return #"{"user":{"id":"\#(userId)","username":"david","type":"admin","token":null\#(tokens)},"#
            + #""userDefaultLibraryId":"lib1","serverSettings":{"version":"\#(version)"}}"#
    }
}

/// Returns the callback for the state in the identity provider URL.
private struct FakeAuthenticator: WebAuthenticator {
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }
        guard let callback = URL(string: "audiobookshelf://oauth?code=auth-code&state=\(state?.value ?? "")") else {
            throw URLError(.badURL)
        }
        return callback
    }
}

/// A clock that advances a second per reading, so `lastUsedAt` orders deterministically.
private final class TickingClock: Sendable {
    private let seconds = Mutex(0.0)

    func now() -> Date {
        Date(
            timeIntervalSinceReferenceDate: seconds.withLock {
                $0 += 1; return $0
            })
    }
}

/// One store and Keychain, shared by every manager made from it, as across relaunches.
@MainActor
private struct Harness {
    let keychain = InMemoryKeychain()
    let store: ServerConnectionStore
    let clock = TickingClock()

    init() throws {
        store = ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    func makeManager() -> AccountManager {
        let openID = OIDCLoginService { configuration, cookieStorage in
            let client = APIClient(
                configuration: configuration, tokenProvider: SignedOutTokenProvider(),
                sessionConfiguration: StubURLProtocol.sessionConfiguration(), cookieStorage: cookieStorage)
            if let jar = client.cookieStorage, let host = configuration.baseURL.host() {
                StubURLProtocol.useCookieStorage(jar, host: host)
            }
            return client
        }
        return AccountManager(
            store: store, keychain: keychain,
            validator: ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() }),
            openID: openID, sessionConfiguration: { StubURLProtocol.sessionConfiguration() },
            now: { [clock] in clock.now() })
    }

    func session(_ id: UUID?) throws -> StoredSession? {
        try CredentialVault(keychain: keychain).session(for: try #require(id))
    }

    func customHeaders(_ id: UUID?) throws -> [String: String] {
        try CredentialVault(keychain: keychain).customHeaders(for: try #require(id))
    }
}

private func validate(_ server: FakeServer) async throws -> ValidatedServer {
    try await ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
        .validate(address: server.address, customHeaders: ["X-Proxy": "proxy-secret"])
}

@MainActor
private func signIn(_ manager: AccountManager, to server: FakeServer, oidc: Bool = false) async throws -> UUID {
    let validated = try await validate(server)
    if oidc {
        try await manager.connect(oidc: validated, authenticator: FakeAuthenticator())
    } else {
        try await manager.connect(local: validated, username: "david", password: "pw")
    }
    return try #require(manager.activeConnection?.id)
}

@MainActor @Suite struct AccountManagerTests {
    @Test func firstLocalLogin() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)

        let user = try #require(manager.state.user)
        #expect(manager.state == .signedIn(user))
        #expect(user.username == "david" && user.userId == "usr-1" && user.authMethod == .local)
        #expect(user.serverAddress == server.address && user.serverVersion == "2.26.0")
        #expect(manager.connections.map(\.id) == [id])
        #expect(manager.client != nil && manager.features?.version == ServerVersion(2, 26, 0))
        #expect(manager.authorization?.userDefaultLibraryId == "lib1" && manager.authorization?.tokens == nil)

        let session = try #require(try harness.session(id))
        #expect(session.tokens == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(session.openIDSession == nil)
        #expect(try harness.customHeaders(id) == ["X-Proxy": "proxy-secret"])
        let item = CredentialVault.item(CredentialVault.sessionService, id)
        #expect(harness.keychain.accessibility(of: item) == .afterFirstUnlock)
    }

    @Test func firstOpenIDLoginKeepsSignOutCookies() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let id = try await signIn(manager, to: FakeServer(), oidc: true)

        #expect(manager.state.user?.authMethod == .openid)
        let session = try #require(try harness.session(id))
        #expect(session.openIDSession == OpenIDSessionCookies(authMethod: "openid-mobile", idToken: "id.token.sig"))
    }

    /// A cookie a proxy set during validation keeps being sent: the signed-in client uses the
    /// validation's jar (checked by identity, as in `loginSendsTheValidationCookies`).
    @Test(arguments: [false, true])
    func signedInClientKeepsTheValidationCookieJar(oidc: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let jar = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        server.update { $0.proxyJar = jar }
        let validated = try await ServerValidator(
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() }, cookieStorage: { jar }
        ).validate(address: server.address)

        if oidc {
            try await manager.connect(oidc: validated, authenticator: FakeAuthenticator())
        } else {
            try await manager.connect(local: validated, username: "david", password: "pw")
        }
        let client = try #require(manager.client)
        #expect(client.cookieStorage === jar)
        #expect(client.cookieStorage?.cookies(for: validated.configuration.baseURL)?.map(\.name) == ["lb"])
    }

    @Test func failedSignInIsNotRestoredAndEndsServerSession() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let firstID = try await signIn(manager, to: FakeServer())
        let server = FakeServer(userId: "usr-2")
        let validated = try await validate(server)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)

        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) {
            try await manager.connect(local: validated, username: "david", password: "pw")
        }
        #expect(manager.state.user?.connectionID == firstID && manager.activeConnection?.id == firstID)
        #expect(server.loggedOutRefreshTokens == ["refresh-1"])

        // The connection was saved, but isn't the one to restore.
        harness.keychain.failWrites(with: nil)
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == firstID)
    }

    @Test func restoreSignsInWithSavedTokens() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == id)
        #expect(relaunched.state == .signedIn(try #require(relaunched.state.user)))
        #expect(relaunched.connections.map(\.id) == [id] && relaunched.authorization != nil)
        let authorize = try #require(server.requests("/api/authorize").last)
        #expect(authorize.value(forHTTPHeaderField: "X-Proxy") == "proxy-secret")
    }

    @Test func restoreOfflineKeepsCachedUserAndRetries() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        server.update { $0.isOffline = true }

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        let user = try #require(relaunched.state.user)
        #expect(relaunched.state == .offline(user))
        #expect(user.connectionID == id && user.username == "david")
        #expect(relaunched.lastError == .server(.cannotConnect(.notConnectedToInternet)))
        #expect(relaunched.client != nil && relaunched.authorization == nil)
        // The features of the version saved with the connection.
        #expect(relaunched.features?.version == ServerVersion(2, 26, 0))
        #expect(try harness.session(id) != nil)

        server.update { $0.isOffline = false }
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedIn(user) && relaunched.lastError == nil)
    }

    @Test func restoreWithoutSessionIsSignedOut() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        await manager.restoreSession()
        #expect(manager.state == .signedOut && manager.lastError == nil)

        _ = try await signIn(manager, to: FakeServer())
        await manager.logout()
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.count == 1)
    }

    @Test func switchesBetweenServers() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let second = FakeServer(userId: "usr-2")
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: second)
        #expect(manager.state.user?.connectionID == secondID)
        #expect(manager.connections.map(\.id) == [secondID, firstID])

        try await manager.switch(to: firstID)
        #expect(manager.state.user?.connectionID == firstID && manager.activeConnection?.id == firstID)
        #expect(manager.connections.map(\.id) == [firstID, secondID])
        #expect(first.requests("/api/authorize").count == 1)

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == firstID)

        await #expect(throws: AccountError.connectionNotFound) { try await manager.switch(to: UUID()) }
        await manager.logout()
        try await manager.switch(to: secondID)
        await #expect(throws: AccountError.notSignedIn) { try await manager.switch(to: firstID) }
        #expect(manager.state.user?.connectionID == secondID)
    }

    @Test func logoutReplaysOpenIDCookiesAndReturnsEndSessionURL() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server, oidc: true)
        server.update { $0.logoutRedirect = "https://idp.example/end-session?id_token_hint=id.token.sig" }

        let url = await manager.logout()
        #expect(url?.absoluteString == "https://idp.example/end-session?id_token_hint=id.token.sig")
        #expect(manager.state == .signedOut && manager.client == nil && manager.lastError == nil)
        let logout = try #require(server.requests("/logout").first)
        #expect(logout.value(forHTTPHeaderField: "Cookie") == "auth_method=openid-mobile; openid_id_token=id.token.sig")
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(logout.value(forHTTPHeaderField: "X-Proxy") == "proxy-secret")
        #expect(logout.value(forHTTPHeaderField: "Authorization") == nil)

        #expect(try harness.session(id) == nil)
        #expect(try harness.customHeaders(id) == ["X-Proxy": "proxy-secret"])
        #expect(manager.connections.map(\.id) == [id])
    }

    @Test func passwordLogoutSendsNoCookiesAndIgnoresNonWebRedirects() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        _ = try await signIn(manager, to: server)
        server.update { $0.logoutRedirect = "javascript:alert(1)" }

        #expect(await manager.logout() == nil)
        #expect(manager.state == .signedOut)
        #expect(try #require(server.requests("/logout").first).value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func removeDeletesCredentialsAndConnection() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let second = FakeServer(userId: "usr-2")
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: second)

        try await manager.remove(firstID)
        #expect(manager.connections.map(\.id) == [secondID])
        #expect(manager.state.user?.connectionID == secondID)
        #expect(try harness.session(firstID) == nil && harness.customHeaders(firstID).isEmpty)
        let logout = try #require(first.requests("/logout").first)
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(logout.value(forHTTPHeaderField: "X-Proxy") == "proxy-secret")

        try await manager.remove(secondID)
        #expect(manager.state == .signedOut && manager.connections.isEmpty && manager.client == nil)
        #expect(harness.keychain.isEmpty)
        await #expect(throws: AccountError.connectionNotFound) { try await manager.remove(secondID) }
    }

    @Test func refreshedTokensArePersisted() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server, oidc: true)
        server.expireAccessToken()

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == id && relaunched.lastError == nil)
        #expect(server.requests("/auth/refresh").count == 1)
        let session = try #require(try harness.session(id))
        #expect(session.tokens == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(session.openIDSession?.idToken == "id.token.sig")
    }

    @Test func expiredSessionOnRestoreSignsOutKeepingConnection() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        server.revokeSession()

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.lastError == .server(.sessionExpired))
        #expect(relaunched.connections.map(\.id) == [id])
        #expect(try harness.session(id) == nil)
        #expect(try harness.customHeaders(id) == ["X-Proxy": "proxy-secret"])
    }

    @Test func sessionExpiringDuringARequestSignsOut() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        server.revokeSession()

        let client = try #require(manager.client)
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        // Already signed out when the error arrives.
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        #expect(manager.connections.map(\.id) == [id] && manager.client == nil)
        #expect(try harness.session(id) == nil)
    }

    @Test func unsupportedServerOnRestoreSignsOutKeepingTokens() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        // The server was downgraded.
        StubURLProtocol.register(host: server.host) { request in
            request.url?.path() == "/abs/api/authorize"
                ? .json(FakeServer.authJSON(userId: "usr-1", tokens: nil, version: "2.25.0"))
                : .json("{}", status: 404)
        }

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.lastError == .server(.unsupportedVersion("2.25.0")))
        #expect(try harness.session(id) != nil)
    }

    @Test func proxyRefusingRestoreIsOffline() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        server.update { $0.authorizeStatus = 403 }

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        let user = try #require(relaunched.state.user)
        #expect(relaunched.state == .offline(user) && relaunched.lastError == .server(.accessDenied(status: 403)))
        #expect(relaunched.features?.version == ServerVersion(2, 26, 0))
        #expect(try harness.session(id) != nil)
    }

    @Test func lockedKeychainOnRestoreIsOffline() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        harness.keychain.failReads(with: errSecInteractionNotAllowed)

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        let user = try #require(relaunched.state.user)
        #expect(relaunched.state == .offline(user) && user.connectionID == id && relaunched.client == nil)
        #expect(relaunched.lastError == .keychain(KeychainError(status: errSecInteractionNotAllowed)))
        #expect(server.requests("/api/authorize").isEmpty)

        harness.keychain.failReads(with: nil)
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedIn(user) && relaunched.lastError == nil)

        // Any other read failure signs out, with the reason.
        harness.keychain.failReads(with: errSecDecode)
        let other = harness.makeManager()
        await other.restoreSession()
        #expect(other.state == .signedOut && other.lastError == .keychain(KeychainError(status: errSecDecode)))
    }

    @Test func failedSessionDeleteIsRetried() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let id = try await signIn(manager, to: FakeServer())
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)

        await manager.logout()
        #expect(try harness.session(id) != nil && manager.state == .signedOut)

        harness.keychain.failWrites(with: nil)
        await manager.restoreSession()
        #expect(manager.state == .signedOut && manager.lastError == nil)
        #expect(try harness.session(id) == nil)
    }

    @Test func removingActiveOpenIDConnectionReplaysCookies() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server, oidc: true)
        server.update { $0.logoutRedirect = "https://idp.example/end-session" }

        let url = try await manager.remove(id)
        #expect(url?.absoluteString == "https://idp.example/end-session")
        let logout = try #require(server.requests("/logout").first)
        #expect(logout.value(forHTTPHeaderField: "Cookie") == "auth_method=openid-mobile; openid_id_token=id.token.sig")
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(manager.state == .signedOut && manager.lastError == nil && manager.connections.isEmpty)
        #expect(harness.keychain.isEmpty)
    }

    @Test func expiryOfAnotherConnectionKeepsTheActiveOne() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let firstID = try await signIn(manager, to: first)
        let firstClient = try #require(manager.client)
        let secondID = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        first.revokeSession()

        await #expect(throws: APIError.sessionExpired) { try await firstClient.send(AuthEndpoints.authorize()) }
        #expect(manager.state.user?.connectionID == secondID && manager.lastError == nil)
        #expect(try harness.session(firstID) == nil && harness.session(secondID) != nil)
    }

    @Test func refreshFromBeforeSigningInAgainIsDropped() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let oldClient = try #require(manager.client)
        server.expireAccessToken()
        let refresh = server.hold("/auth/refresh")
        let request = Task { try await oldClient.send(AuthEndpoints.authorize()) }
        await refresh.arrived()

        // Signing in again ends the replaced session on the server.
        _ = try await signIn(manager, to: server)
        #expect(server.loggedOutRefreshTokens == ["refresh-1"])
        refresh.open()
        // The rejected refresh token was no longer current, so the request retried with the new one.
        _ = try await request.value
        #expect(manager.state.user?.connectionID == id && manager.lastError == nil)
        #expect(try harness.session(id)?.tokens == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))

        // A later expiry of the new session still signs out.
        server.revokeSession()
        let client = try #require(manager.client)
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
    }
}

/// Calls that overlap: the newer call wins, and signing out also ends the session of a call that
/// is still running.
@MainActor @Suite struct AccountManagerOverlapTests {
    @Test func logoutDuringRefreshEndsTheSession() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        server.expireAccessToken()
        let refresh = server.hold("/auth/refresh")
        let manager = harness.makeManager()
        let restore = Task { await manager.restoreSession() }
        await refresh.arrived()

        await manager.logout()
        refresh.open()
        await restore.value
        #expect(manager.state == .signedOut && manager.lastError == nil && manager.client == nil)
        // The refreshed pair arrived after the sign-out and wasn't stored.
        #expect(try harness.session(id) == nil && server.requests("/auth/refresh").count == 1)
        #expect(server.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test(arguments: [false, true])
    func signingOutDuringRestoreWins(removing: Bool) async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        // Without a session, the held authorize would fail as an expiry.
        server.revokeSession()
        let authorize = server.hold("/api/authorize")
        let manager = harness.makeManager()
        let restore = Task { await manager.restoreSession() }
        await authorize.arrived()

        if removing { try await manager.remove(id) } else { await manager.logout() }
        authorize.open()
        await restore.value
        #expect(manager.state == .signedOut && manager.lastError == nil)
        #expect(try harness.session(id) == nil && server.loggedOutRefreshTokens == ["refresh-1"])
        #expect(manager.connections.map(\.id) == (removing ? [] : [id]))
    }

    @Test func laterSwitchSupersedesSwitch() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        let lastUsed = try await harness.store.connection(id: firstID)?.lastUsedAt
        let authorize = first.hold("/api/authorize")
        let switching = Task { try await manager.switch(to: firstID) }
        await authorize.arrived()
        #expect(manager.state == .restoring)

        try await manager.switch(to: secondID)
        authorize.open()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(manager.state.user?.connectionID == secondID && manager.activeConnection?.id == secondID)
        #expect(try await harness.store.connection(id: firstID)?.lastUsedAt == lastUsed)
    }

    @Test func removingTheConnectionBeingSwitchedToCancelsTheSwitch() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        let authorize = first.hold("/api/authorize")
        let switching = Task { try await manager.switch(to: firstID) }
        await authorize.arrived()
        #expect(manager.activeConnection?.id == firstID)

        try await manager.remove(firstID)
        authorize.open()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(manager.state == .signedOut && manager.lastError == nil && manager.activeConnection == nil)
        #expect(try harness.session(secondID) != nil && manager.connections.map(\.id) == [secondID])
        #expect(try harness.session(firstID) == nil && first.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test func signInSupersededBySwitchKeepsItsSession() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        let lastUsed = try await harness.store.connection(id: firstID)?.lastUsedAt
        let validated = try await validate(first)
        // Signing in again to the first server holds while ending the replaced session.
        let logout = first.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        try await manager.switch(to: secondID)
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state.user?.connectionID == secondID)
        #expect(try harness.session(firstID)?.refreshToken == "refresh-2")
        #expect(try await harness.store.connection(id: firstID)?.lastUsedAt == lastUsed)

        try await manager.switch(to: firstID)
        #expect(manager.state.user?.connectionID == firstID)
    }

    @Test func logoutSignsOutOfASignInThatIsSaving() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let second = FakeServer(userId: "usr-2")
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: second)
        let validated = try await validate(first)
        let logout = first.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        // Signs out of the active second server, then of the first once its sign-in resumes.
        await manager.logout()
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.activeConnection == nil)
        #expect(try harness.session(firstID) == nil && harness.session(secondID) == nil)
        #expect(first.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
        #expect(second.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test func logoutSignsOutOfASignInWithNothingActive() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        let manager = harness.makeManager()
        let validated = try await validate(server)
        let logout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        await manager.logout()
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(try harness.session(id) == nil && manager.state == .signedOut)
        let requests = server.requests("/logout")
        #expect(server.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
        #expect(requests.last?.value(forHTTPHeaderField: "X-Proxy") == "proxy-secret")
    }

    @Test func logoutDuringLoginRequestDiscardsTheSignIn() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let activeID = try await signIn(manager, to: FakeServer())
        let server = FakeServer(userId: "usr-2")
        let validated = try await validate(server)
        let login = server.hold("/login")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await login.arrived()

        await manager.logout()
        login.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.connections.map(\.id) == [activeID])
        #expect(server.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test(arguments: [false, true])
    func signingOutWhileRestoreReadsTheKeychainWins(removing: Bool) async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        let manager = harness.makeManager()
        let read = harness.keychain.holdNextRead()
        let restore = Task { await manager.restoreSession() }
        await read.arrived()

        // Starts before the restore resumes from reading the session.
        let signingOut = Task {
            if removing { _ = try await manager.remove(id) } else { _ = await manager.logout() }
        }
        read.open()
        try await signingOut.value
        await restore.value
        #expect(manager.state == .signedOut && manager.lastError == nil && manager.activeConnection == nil)
        #expect(try harness.session(id) == nil && server.loggedOutRefreshTokens == ["refresh-1"])
        // The restore stopped before authorizing.
        #expect(server.requests("/api/authorize").isEmpty)
        #expect(manager.connections.map(\.id) == (removing ? [] : [id]))
    }

    @Test func logoutBeforeRestoreChoosesEndsItsSession() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        let manager = harness.makeManager()
        let choosing = StubGate()
        manager.restoreWillChooseConnection = { await choosing.pass() }
        let restore = Task { await manager.restoreSession() }
        await choosing.arrived()

        await manager.logout()
        choosing.open()
        await restore.value
        #expect(manager.state == .signedOut && manager.activeConnection == nil)
        #expect(try harness.session(id) == nil && server.loggedOutRefreshTokens == ["refresh-1"])
        #expect(server.requests("/api/authorize").isEmpty && manager.connections.map(\.id) == [id])
    }

    @Test func removingDuringSignInToItEndsBothSessions() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let validated = try await validate(server)
        // Signing in again holds while ending the replaced session.
        let logout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        try await manager.remove(id)
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.connections.isEmpty && harness.keychain.isEmpty)
        #expect(server.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
    }

    @Test func signInToAConnectionDeletedMeanwhileIsDiscarded() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        let manager = harness.makeManager()
        let validated = try await validate(server)
        let logout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        // Deleted after the sign-in saved its session, as by a removal that checked the connection
        // before the sign-in saved it.
        _ = try await harness.store.remove(id: id)
        logout.open()
        await #expect(throws: AccountError.connectionNotFound) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.activeConnection == nil && manager.connections.isEmpty)
        #expect(harness.keychain.isEmpty && server.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
    }

    @Test func removingTheActiveConnectionLetsASignInToAnotherFinish() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let second = FakeServer(userId: "usr-2")
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: second)
        let validated = try await validate(first)
        let logout = first.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        try await manager.remove(secondID)
        #expect(manager.state == .signedOut)
        logout.open()
        try await signingIn.value
        #expect(manager.state.user?.connectionID == firstID && manager.connections.map(\.id) == [firstID])
        #expect(first.loggedOutRefreshTokens == ["refresh-1"] && second.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test func failedSwitchDuringReconnectStaysOffline() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        server.update { $0.isOffline = true }
        let manager = harness.makeManager()
        await manager.restoreSession()
        let offline = manager.state
        #expect(offline == .offline(try #require(offline.user)))

        server.update { $0.isOffline = false }
        let authorize = server.hold("/api/authorize")
        let reconnect = Task { await manager.restoreSession() }
        await authorize.arrived()
        await #expect(throws: AccountError.connectionNotFound) { try await manager.switch(to: UUID()) }
        authorize.open()
        await reconnect.value
        #expect(manager.state == offline && manager.activeConnection?.id == id && manager.client != nil)
    }
}
