import ABSCore
import ABSData
import Foundation
import Security
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel

/// An Audiobookshelf server on a unique stub host. It accepts one token pair at a time and
/// rotates it on `POST /auth/refresh`, like the real server.
private final class FakeServer: Sendable {
    struct State {
        var isOffline = false
        var accessToken = "access-1"
        var refreshToken = "refresh-1"
        var refreshes = 0
        var logoutRedirect: String?
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
            switch request.url?.path() {
            case "/abs/status":
                return .json(
                    #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local","openid"]}"#
                )
            case "/abs/login":
                return .json(Self.authJSON(userId: userId, tokens: state))
            case "/abs/auth/openid":
                return StubResponse(
                    status: 302,
                    headers: [
                        "Location": "https://idp.example/authorize?state=idp-state",
                        "Set-Cookie": "auth_method=openid-mobile; Path=/; HttpOnly",
                    ])
            case "/abs/auth/openid/callback":
                return .json(
                    Self.authJSON(userId: userId, tokens: state),
                    headers: ["Set-Cookie": "openid_id_token=id.token.sig; Path=/; HttpOnly"])
            case "/abs/api/authorize":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(state.accessToken)" else {
                    return .json("{}", status: 401)
                }
                return .json(Self.authJSON(userId: userId, tokens: nil))
            case "/abs/auth/refresh":
                guard request.value(forHTTPHeaderField: "x-refresh-token") == state.refreshToken else {
                    return .json("{}", status: 401)
                }
                state.refreshes += 1
                state.accessToken = "access-\(state.refreshes + 1)"
                state.refreshToken = "refresh-\(state.refreshes + 1)"
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

/// Records the generations that `onExpire` reports.
private final class ExpiryRecorder: Sendable {
    private let generations = Mutex<[Int]>([])

    func record(_ generation: Int) {
        generations.withLock { $0.append(generation) }
    }

    var recorded: [Int] { generations.withLock { $0 } }
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
        let openID = OIDCLoginService { configuration in
            let client = APIClient(
                configuration: configuration, tokenProvider: SignedOutTokenProvider(),
                sessionConfiguration: StubURLProtocol.sessionConfiguration())
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

    @Test func failedKeychainWriteKeepsStateAndEndsServerSession() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let validated = try await validate(server)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)

        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) {
            try await manager.connect(local: validated, username: "david", password: "pw")
        }
        #expect(manager.state == .signedOut && manager.client == nil)
        #expect(server.requests("/logout").first?.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
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
        #expect(relaunched.lastError == .cannotConnect(.notConnectedToInternet))
        #expect(relaunched.client != nil && relaunched.authorization == nil)
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
        #expect(relaunched.state == .signedOut && relaunched.lastError == .sessionExpired)
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
        #expect(manager.state == .signedOut && manager.lastError == .sessionExpired)
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
        #expect(relaunched.state == .signedOut && relaunched.lastError == .unsupportedVersion("2.25.0"))
        #expect(try harness.session(id) != nil)
    }
}

@Suite struct ConnectionCredentialsTests {
    private let first = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")
    private let second = AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")

    @Test func refreshedTokensStayInMemoryUntilTheKeychainTakesThem() async throws {
        let keychain = InMemoryKeychain()
        let vault = CredentialVault(keychain: keychain)
        let id = UUID()
        let credentials = ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }
        _ = try await credentials.signIn(StoredSession(tokens: first, openIDSession: nil), customHeaders: [:])

        keychain.failWrites(with: errSecInteractionNotAllowed)
        #expect(await credentials.replaceTokens(expected: first, with: second))
        #expect(await !credentials.replaceTokens(expected: first, with: first))
        #expect(await credentials.tokens() == second)
        #expect(try vault.session(for: id)?.tokens == first)

        keychain.failWrites(with: nil)
        #expect(await credentials.tokens() == second)
        #expect(try vault.session(for: id)?.tokens == second)
    }

    @Test func expiryComparesAndReportsItsGeneration() async throws {
        let recorder = ExpiryRecorder()
        let vault = CredentialVault(keychain: InMemoryKeychain())
        let credentials = ConnectionCredentials(connectionID: UUID(), vault: vault) { _, generation in
            recorder.record(generation)
        }
        let session = StoredSession(tokens: first, openIDSession: nil)
        let signedIn = try await credentials.signIn(session, customHeaders: [:])

        #expect(await !credentials.expireSession(ifCurrent: second))
        #expect(await credentials.expireSession(ifCurrent: first))
        #expect(await credentials.tokens() == nil)
        #expect(recorder.recorded == [signedIn + 1])
        #expect(try await credentials.signIn(session, customHeaders: [:]) > signedIn + 1)
    }

    @Test func corruptItemsReadAsMissing() throws {
        let keychain = InMemoryKeychain()
        let id = UUID()
        let item = CredentialVault.item(CredentialVault.sessionService, id)
        _ = try keychain.add(Data("not json".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try CredentialVault(keychain: keychain).session(for: id) == nil)
        let description = String(describing: StoredSession(tokens: first, openIDSession: nil))
        #expect(!description.contains("access-1") && !description.contains("refresh-1"))
    }
}
