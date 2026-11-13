import ABSCore
import Foundation
import Observation
import Security
import SwiftData
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel
@testable import ABSData

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

    /// Held requests for `path` that the client cancelled before the gate opened.
    func abandoned(_ path: String) -> [URLRequest] {
        StubURLProtocol.abandonedRequests(host: host).filter { $0.url?.path() == "/abs\(path)" }
    }

    /// Holds the next request for `path` until the gate opens, as `StubURLProtocol.hold` does.
    func hold(
        _ path: String, answeringOnArrival: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
    ) -> StubGate {
        StubURLProtocol.hold(
            host: host, path: "/abs\(path)", answeringOnArrival: answeringOnArrival, sourceLocation: sourceLocation)
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
    let container: ModelContainer
    let store: ServerConnectionStore
    let clock = TickingClock()

    init() throws {
        container = try DataStack(location: .inMemory).container
        store = ServerConnectionStore(modelContainer: container)
    }

    /// Saves progress that hasn't synced for the connection, so removing it keeps it, disconnected.
    func retainRecords(of id: UUID) throws {
        let context = ModelContext(container)
        let progress = LocalMediaProgress(
            key: MediaKey(serverConnectionID: id, libraryItemId: "li_1").rawValue, serverConnectionID: id,
            libraryItemId: "li_1")
        progress.needsServerSync = true
        context.insert(progress)
        try context.save()
    }

    /// - Parameter willReadClock: Runs before each reading of the clock, in the caller's task.
    func makeManager(
        settings: AppSettings? = nil, willReadClock: @escaping @Sendable () -> Void = {}
    ) -> AccountManager {
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
            now: { [clock] in
                willReadClock()
                return clock.now()
            }, settings: settings)
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

/// Waits until `condition` holds, checking it again after each change to an observable property
/// it read. Bounded as ``StubGate`` is.
@MainActor
private func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping @MainActor @Sendable () -> Bool
) async {
    let holds = StubGate(sourceLocation: sourceLocation)
    track(condition, reaching: holds)
    await holds.arrived()
}

@MainActor
private func track(_ condition: @escaping @MainActor @Sendable () -> Bool, reaching gate: StubGate) {
    withObservationTracking {
        if condition() { gate.reach() }
    } onChange: {
        // Called before the change; check again once it's made.
        Task { @MainActor in track(condition, reaching: gate) }
    }
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

@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountManagerTests {
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
        let item = CredentialVault.item(id)
        #expect(harness.keychain.accessibility(of: item) == .afterFirstUnlock)
    }

    @Test func userUpdatesReplaceOnlyTheSignedInUser() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        _ = try await signIn(manager, to: FakeServer())

        manager.applyUserUpdate(User(id: "usr-2", username: "someone"))
        #expect(manager.authorization?.user.username == "david")

        manager.applyUserUpdate(User(id: "usr-1", username: "renamed", type: .user))
        #expect(manager.authorization?.user.username == "renamed" && manager.authorization?.user.type == .user)
        #expect(manager.authorization?.userDefaultLibraryId == "lib1")
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
        // Published as marked used.
        #expect(manager.activeConnection == manager.connections.first)
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

    @Test func aSignInDuringLogoutDropsTheEndSessionURL() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        _ = try await signIn(manager, to: server, oidc: true)
        server.update { $0.logoutRedirect = "https://idp.example/end-session" }
        let held = server.hold("/logout")
        let logout = Task { await manager.logout() }
        await held.arrived()

        _ = try await signIn(manager, to: server, oidc: true)
        held.open()
        #expect(await logout.value == nil && manager.state.user != nil)
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

    /// An end-session URL can carry the OpenID `id_token_hint`: an `https` account never opens it
    /// over `http`.
    @Test func anHTTPSAccountIgnoresAnHTTPEndSessionURL() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        _ = try await signIn(manager, to: server, oidc: true)
        server.update { $0.logoutRedirect = "http://idp.example/end-session?id_token_hint=id.token.sig" }

        #expect(await manager.logout() == nil)
        #expect(manager.state == .signedOut)
        #expect(server.requests("/logout").count == 1)
    }

    @Test(arguments: [
        ("https://abs.example", "https://idp.example/end", true),
        ("https://abs.example", "http://idp.example/end", false),
        ("HTTPS://abs.example", "HTTP://idp.example/end", false),
        ("http://abs.example", "http://idp.example/end", true),
        ("http://abs.example", "https://idp.example/end", true),
        ("http://abs.example", "javascript:alert(1)", false),
    ])
    func endSessionURLsKeepTheServersTransport(server: String, endSession: String, allowed: Bool) throws {
        let server = try #require(URL(string: server))
        let url = try #require(URL(string: endSession))
        #expect(AccountManager.isAllowedEndSessionURL(url, server: server) == allowed)
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

    @Test func removeClearsTheAccountsSavedSettingsAndLogoutKeepsThem() async throws {
        let suiteName = "ABSAppModelTests.Account.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let harness = try Harness()
        let manager = harness.makeManager(settings: settings)
        let first = FakeServer()
        let second = FakeServer()
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: second)
        // The removed account, the same server with another user, and the same user on another
        // server, keyed as `LibraryConnectionKey` keys them.
        let removed = (server: firstID.uuidString, user: first.userId)
        let accounts = [removed, (firstID.uuidString, "usr-other"), (secondID.uuidString, second.userId)]
        for (server, user) in accounts {
            settings.setLastLibraryID("lib-\(user)", serverID: server, userID: user)
            settings.setLibraryViewPreferencesJSON("{}", serverID: server, userID: user, libraryID: "lib")
            settings.setRecentSearchesJSON("[\"Dune\"]", serverID: server, userID: user, libraryID: "lib")
        }
        let saved = AppSettings.snapshot(from: defaults)

        // Signing out keeps them, for signing in again.
        _ = await manager.logout()
        #expect(AppSettings.snapshot(from: defaults) == saved)

        try await manager.remove(firstID)
        let stored = AppSettings(defaults: defaults)
        #expect(stored.lastLibraryID(serverID: removed.server, userID: removed.user) == nil)
        #expect(
            stored.libraryViewPreferencesJSON(serverID: removed.server, userID: removed.user, libraryID: "lib") == nil)
        #expect(stored.recentSearchesJSON(serverID: removed.server, userID: removed.user, libraryID: "lib") == nil)
        for (server, user) in accounts.dropFirst() {
            #expect(stored.lastLibraryID(serverID: server, userID: user) == "lib-\(user)")
            #expect(stored.libraryViewPreferencesJSON(serverID: server, userID: user, libraryID: "lib") == "{}")
            #expect(stored.recentSearchesJSON(serverID: server, userID: user, libraryID: "lib") == "[\"Dune\"]")
        }
    }

    @Test func restoreSweepsTheSettingsOfAccountsThatArentSaved() async throws {
        let suiteName = "ABSAppModelTests.Account.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let harness = try Harness()
        let first = FakeServer()
        let second = FakeServer()
        let third = FakeServer()
        // Removed without clearing its settings, as by a removal the app was terminated in:
        // `first` is deleted, `second` kept disconnected for its unsynced progress.
        let interrupted = harness.makeManager()
        let firstID = try await signIn(interrupted, to: first)
        let secondID = try await signIn(interrupted, to: second)
        let thirdID = try await signIn(interrupted, to: third)
        try harness.retainRecords(of: secondID)
        try await interrupted.remove(firstID)
        try await interrupted.remove(secondID)
        let orphans = [
            (firstID.uuidString, first.userId), (secondID.uuidString, second.userId),
            (thirdID.uuidString, "usr-other"), (UUID().uuidString, third.userId),
        ]
        let saved = (serverID: thirdID.uuidString, userID: third.userId)
        for (server, user) in orphans + [saved] {
            settings.setLastLibraryID("lib", serverID: server, userID: user)
            settings.setLibraryViewPreferencesJSON("{}", serverID: server, userID: user, libraryID: "lib")
            settings.setRecentSearchesJSON("[\"Dune\"]", serverID: server, userID: user, libraryID: "lib")
        }

        let relaunched = harness.makeManager(settings: settings)
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == thirdID)
        let stored = AppSettings(defaults: defaults)
        for (server, user) in orphans {
            #expect(stored.lastLibraryID(serverID: server, userID: user) == nil)
            #expect(stored.libraryViewPreferencesJSON(serverID: server, userID: user, libraryID: "lib") == nil)
            #expect(stored.recentSearchesJSON(serverID: server, userID: user, libraryID: "lib") == nil)
        }
        #expect(stored.lastLibraryID(serverID: saved.serverID, userID: saved.userID) == "lib")
        #expect(
            stored.libraryViewPreferencesJSON(serverID: saved.serverID, userID: saved.userID, libraryID: "lib") == "{}")
        #expect(
            stored.recentSearchesJSON(serverID: saved.serverID, userID: saved.userID, libraryID: "lib") == "[\"Dune\"]")
    }

    @Test func savedConnectionIDsAreReadFromTheStoreBeforeTheConnectionsLoad() async throws {
        let harness = try Harness()
        let (first, second, third) = (FakeServer(), FakeServer(), FakeServer())
        let earlier = harness.makeManager()
        let firstID = try await signIn(earlier, to: first)
        let secondID = try await signIn(earlier, to: second)
        let thirdID = try await signIn(earlier, to: third)
        // Removed, and kept disconnected for its unsynced progress.
        try harness.retainRecords(of: secondID)
        try await earlier.remove(secondID)

        let relaunched = harness.makeManager()
        #expect(relaunched.connections.isEmpty)
        #expect(await relaunched.savedConnectionIDs() == [firstID, thirdID])
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
        // The delete succeeded, so there's no sign-out to save.
        #expect(manager.connections.first?.signedOutAt == nil)
        #expect(try await harness.store.connection(id: id)?.signedOutAt == nil)
    }

    @Test func handoffAccountOfAnExpiredSessionIsNotSignedIn() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let account = try #require(HandoffAccount(serverAddress: server.address, userID: server.userId))
        let signedIn = await manager.connectionID(for: account)
        #expect(signedIn == id)

        server.revokeSession()
        let client = try #require(manager.client)
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        // Kept without a sign-out, so it still matches; only its missing tokens rule it out.
        #expect(manager.connections.first?.signedOutAt == nil)
        let expired = await manager.connectionID(for: account)
        #expect(expired == nil)
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

    @Test func failedSessionDeleteIsNotRestoredAfterARelaunch() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        // Neither the delete nor the server sign-out succeeds, so the session would still work.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.update { $0.isOffline = true }
        await manager.logout()
        #expect(try harness.session(id) != nil)

        server.update { $0.isOffline = false }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.lastError == nil)
        await #expect(throws: AccountError.notSignedIn) { try await relaunched.switch(to: id) }
        #expect(server.requests("/api/authorize").isEmpty && relaunched.connections.map(\.id) == [id])

        // Signed out, not offline, while the Keychain is locked.
        harness.keychain.failReads(with: errSecInteractionNotAllowed)
        let locked = harness.makeManager()
        await locked.restoreSession()
        #expect(locked.state == .signedOut && locked.lastError == nil)
        harness.keychain.failReads(with: nil)

        // The next launch that can write retries the delete.
        harness.keychain.failWrites(with: nil)
        let again = harness.makeManager()
        await again.restoreSession()
        #expect(again.state == .signedOut && server.requests("/api/authorize").isEmpty)
        #expect(try harness.session(id) == nil && harness.customHeaders(id) == ["X-Proxy": "proxy-secret"])

        // Signing in again makes it restorable.
        _ = try await signIn(again, to: server)
        let restored = harness.makeManager()
        await restored.restoreSession()
        #expect(restored.state.user?.connectionID == id)
    }

    @Test func signOutIsPublishedWithTheConnection() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        #expect(manager.connections.first { $0.id == id }?.signedOutAt == nil)

        await manager.logout()
        #expect(manager.connections.first { $0.id == id }?.signedOutAt != nil)
        _ = try await signIn(manager, to: server)
        #expect(manager.connections.first { $0.id == id }?.signedOutAt == nil)
    }

    @Test func signingInAgainPublishesTheConnectionAsSaved() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        await manager.logout()
        _ = try await signIn(manager, to: server)

        let saved = try #require(try await harness.store.connection(id: id))
        #expect(saved.signedOutAt == nil)
        #expect(manager.activeConnection == saved && manager.connections == [saved])
    }

    @Test func removalThatCannotBeSavedStillEndsTheSession() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)

        await harness.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await manager.remove(id) }
        // The session was deleted first, so it's ended now: nothing could end it later.
        #expect(try harness.session(id) == nil && server.loggedOutRefreshTokens == ["refresh-1"])
        #expect(manager.state == .signedOut && manager.connections.map(\.id) == [id])

        try await manager.remove(id)
        #expect(manager.connections.isEmpty && server.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test func signInThatCannotClearItsSignOutFails() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let signedOut = harness.makeManager()
        let id = try await signIn(signedOut, to: server)
        await signedOut.logout()
        let manager = harness.makeManager()
        let validated = try await validate(server)
        let read = harness.keychain.holdNextRead()
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        // Saving the session, so the next save is the one that marks the connection used.
        await read.arrived()

        await harness.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        read.open()
        await #expect(throws: CocoaError.self) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.activeConnection == nil)
        // Kept for switching to later, as a superseded sign-in's session is.
        try await manager.switch(to: id)
        #expect(manager.state.user?.connectionID == id)
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

    @Test func expiryOfAnotherConnectionBumpsTheCredentialsRevision() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        _ = try await signIn(manager, to: first)
        let firstClient = try #require(manager.client)
        _ = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        first.revokeSession()
        let connections = manager.connections
        let before = manager.credentialsRevision

        await #expect(throws: APIError.sessionExpired) { try await firstClient.send(AuthEndpoints.authorize()) }
        // The list didn't change, so only the revision tells a view to read the sessions again.
        #expect(manager.connections == connections)
        #expect(manager.credentialsRevision > before)
    }

    @Test func signInAndLogoutBumpTheCredentialsRevision() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let before = manager.credentialsRevision
        _ = try await signIn(manager, to: FakeServer())
        let signedIn = manager.credentialsRevision
        #expect(signedIn > before)
        _ = await manager.logout()
        #expect(manager.credentialsRevision > signedIn)
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
    /// A reconnect is bound to its connection: while the offline account's server is back but a
    /// cancelled sign-in has marked another connection used, reconnecting signs the offline one in
    /// (control: `restoreSession()` takes the other account).
    @Test(arguments: [true, false])
    func reconnectRestoresTheOfflineConnection(bound: Bool) async throws {
        let harness = try Harness()
        let first = FakeServer()
        let second = FakeServer(userId: "usr-2")
        let firstID = try await signIn(harness.makeManager(), to: first)
        first.update { $0.isOffline = true }
        let readings = Mutex<Int?>(nil)
        // The second reading after arming is the cancelled sign-in's, marking its connection used.
        let relaunched = harness.makeManager {
            let reading = readings.withLock { count -> Int? in
                count = count.map { $0 + 1 }
                return count
            }
            if reading == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        await relaunched.restoreSession()
        let user = try #require(relaunched.state.user)
        #expect(relaunched.state == .offline(user) && user.connectionID == firstID)

        let validated = try await validate(second)
        readings.withLock { $0 = 0 }
        let signingIn = Task { try await relaunched.connect(local: validated, username: "david", password: "pw") }
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        readings.withLock { $0 = nil }
        let secondID = try #require(relaunched.connections.first { $0.id != firstID }?.id)
        #expect(try await harness.store.connectionToRestore()?.id == secondID)
        #expect(relaunched.state == .offline(user))

        // Nothing for a connection that isn't the offline one.
        let authorized = second.requests("/api/authorize").count
        await relaunched.reconnect(secondID)
        #expect(relaunched.state == .offline(user) && second.requests("/api/authorize").count == authorized)

        first.update { $0.isOffline = false }
        if bound {
            await relaunched.reconnect(firstID)
            #expect(relaunched.state == .signedIn(user) && relaunched.activeConnection?.id == firstID)
        } else {
            await relaunched.restoreSession()
            #expect(relaunched.state.user?.connectionID == secondID)
        }

        // Signed in, a reconnect does nothing.
        guard bound else { return }
        let requests = first.requests("/api/authorize").count
        await relaunched.reconnect(firstID)
        #expect(relaunched.state == .signedIn(user) && first.requests("/api/authorize").count == requests)
    }

    /// Offline after a locked Keychain there's no client; once it unlocks, a reconnect reads the
    /// saved session again and signs in with one (control: still locked, it stays offline).
    @Test(arguments: [true, false])
    func reconnectAfterALockedKeychain(unlocked: Bool) async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        harness.keychain.failReads(with: errSecInteractionNotAllowed)
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        let user = try #require(relaunched.state.user)
        #expect(relaunched.state == .offline(user) && relaunched.client == nil)

        if unlocked { harness.keychain.failReads(with: nil) }
        await relaunched.reconnect(id)
        if unlocked {
            #expect(relaunched.state == .signedIn(user) && relaunched.client != nil)
        } else {
            #expect(relaunched.state == .offline(user) && relaunched.client == nil)
            #expect(server.requests("/api/authorize").isEmpty)
        }
    }
}

/// Calls that overlap: the newer call wins, and signing out also ends the session of a call that
/// is still running.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountManagerOverlapTests {
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

    @Test func callMadeWhileASignInAuthenticatesWins() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let firstID = try await signIn(manager, to: FakeServer())
        let secondID = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        let server = FakeServer(userId: "usr-3")
        let validated = try await validate(server)
        let login = server.hold("/login")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await login.arrived()

        try await manager.switch(to: firstID)
        login.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state.user?.connectionID == firstID && manager.connections.map(\.id) == [firstID, secondID])
        // Never saved, so it's ended on the server.
        #expect(server.loggedOutRefreshTokens == ["refresh-1"])
    }

    @Test(arguments: [false, true])
    func removingWhileSigningInToItAgainDiscardsTheSignIn(oidc: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server, oidc: oidc)
        let validated = try await validate(server)
        let authenticated = server.hold(oidc ? "/auth/openid/callback" : "/login")
        let signingIn = Task {
            if oidc {
                try await manager.connect(oidc: validated, authenticator: FakeAuthenticator())
            } else {
                try await manager.connect(local: validated, username: "david", password: "pw")
            }
        }
        await authenticated.arrived()

        try await manager.remove(id)
        authenticated.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.connections.isEmpty && harness.keychain.isEmpty)
        #expect(server.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
    }

    @Test func expiryWhileSigningInAgainStopsTheSignIn() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let oldClient = try #require(manager.client)
        let validated = try await validate(server)
        // Signing in again holds while ending the replaced session.
        let logout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        // The active client uses the new session, which the server rejects.
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await oldClient.send(AuthEndpoints.authorize()) }
        logout.open()
        await #expect(throws: AccountError.server(.sessionExpired)) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        #expect(try harness.session(id) == nil && manager.client == nil)
    }

    @Test func cancelledSignInKeepsItsSessionAndTheActiveConnection() async throws {
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

        signingIn.cancel()
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state.user?.connectionID == secondID)
        #expect(try harness.session(firstID)?.refreshToken == "refresh-2")
        #expect(try await harness.store.connection(id: firstID)?.lastUsedAt == lastUsed)
    }

    @Test func cancellingASignInDoesNotStopTheLogoutOfTheSessionItReplaced() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        _ = try await signIn(manager, to: server)
        let validated = try await validate(server)
        let logout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        signingIn.cancel()
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        // Answered, not dropped with the sign-in's task.
        #expect(server.loggedOutRefreshTokens == ["refresh-1"] && server.abandoned("/logout").isEmpty)
    }

    @Test func signInCancelledAfterMarkingUsedKeepsTheActiveConnection() async throws {
        let harness = try Harness()
        let readings = TickingClock()
        // Readings 1 and 2 are the first sign-in's; 4 marks the second one's connection used,
        // after its first cancellation check.
        let manager = harness.makeManager {
            if readings.now() == Date(timeIntervalSinceReferenceDate: 4) { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let firstID = try await signIn(manager, to: FakeServer())
        let validated = try await validate(FakeServer(userId: "usr-2"))
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }

        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state.user?.connectionID == firstID)
        let secondID = try #require(manager.connections.first { $0.id != firstID }?.id)
        #expect(try harness.session(secondID)?.refreshToken == "refresh-1")
        // Too late to leave it unused: it's the one restored at the next launch.
        #expect(try await harness.store.connectionToRestore()?.id == secondID)
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

    @Test func logoutSavesTheSignOutOfASignInThatIsSaving() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let firstID = try await signIn(manager, to: first)
        _ = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        let validated = try await validate(first)
        let logout = first.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        // Neither deleting the first server's new session nor ending it on the server succeeds.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        first.update { $0.isOffline = true }
        await manager.logout()
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.connections.first { $0.id == firstID }?.signedOutAt != nil)
        #expect(try harness.session(firstID)?.refreshToken == "refresh-2")

        harness.keychain.failWrites(with: nil)
        first.update { $0.isOffline = false }
        let relaunched = harness.makeManager()
        await #expect(throws: AccountError.notSignedIn) { try await relaunched.switch(to: firstID) }
        #expect(try first.requests("/api/authorize").isEmpty && harness.session(firstID) == nil)
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

        let signingOut = Task {
            if removing { _ = try await manager.remove(id) } else { _ = await manager.logout() }
        }
        // Started, so the restore resumes from reading the session after it.
        await waitUntil { manager.state == .signedOut }
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

    @Test func newerSignInSurvivesTheCleanupOfASignInARemovalCancelled() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        // Removing keeps it, disconnected, so signing in again reconnects it.
        try harness.retainRecords(of: id)
        let validated = try await validate(server)
        let replacedLogout = server.hold("/logout")
        let older = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await replacedLogout.arrived()
        let removalLogout = server.hold("/logout")
        let removing = Task { try await manager.remove(id) }
        await removalLogout.arrived()

        // Signs in again while the removal ends the older sign-in's session.
        #expect(try await signIn(manager, to: server) == id)
        replacedLogout.open()
        await #expect(throws: CancellationError.self) { try await older.value }
        removalLogout.open()
        _ = try await removing.value
        #expect(manager.state.user?.connectionID == id && manager.connections.map(\.id) == [id])
        #expect(try harness.session(id)?.refreshToken == "refresh-3")
        #expect(server.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
    }

    @Test func clientsOfOneConnectionShareARefresh() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let first = try #require(manager.client)
        // Restoring makes another client for the connection; the first is still in use.
        await manager.restoreSession()
        let second = try #require(manager.client)
        #expect(first !== second)
        server.expireAccessToken()
        // The server rotates the pair as the refresh arrives, so refreshing it again would fail.
        let refresh = server.hold("/auth/refresh", answeringOnArrival: true)
        let firstRequest = Task { try await first.send(AuthEndpoints.authorize()) }
        await refresh.arrived()

        let joined = StubGate()
        await manager.credentials(for: id).observeRefreshJoins { joined.reach() }
        let secondRequest = Task {
            // Also when it finishes, so a failure doesn't wait for the timeout.
            defer { joined.reach() }
            return try await second.send(AuthEndpoints.authorize())
        }
        await joined.arrived()
        refresh.open()
        _ = try await firstRequest.value
        _ = try await secondRequest.value
        #expect(manager.state.user?.connectionID == id && manager.lastError == nil)
        #expect(try harness.session(id)?.tokens == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(server.requests("/auth/refresh").count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func failedAuthenticationAfterANewerCallIsACancellation(oidc: Bool, signingInElsewhere: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        _ = try await signIn(manager, to: FakeServer())
        let server = FakeServer(userId: "usr-2")
        let validated = try await validate(server)
        let authenticating = server.hold(oidc ? "/auth/openid/callback" : "/login")
        let signingIn = Task {
            if oidc {
                try await manager.connect(oidc: validated, authenticator: FakeAuthenticator())
            } else {
                try await manager.connect(local: validated, username: "david", password: "pw")
            }
        }
        await authenticating.arrived()

        var newerID: UUID?
        if signingInElsewhere {
            newerID = try await signIn(manager, to: FakeServer(userId: "usr-3"))
        } else {
            await manager.logout()
        }
        // The held request then fails.
        server.update { $0.isOffline = true }
        authenticating.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state.user?.connectionID == newerID && manager.lastError == nil)
    }

    @Test func signInFailingAfterALogoutIsACancellation() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        _ = try await signIn(manager, to: FakeServer())
        let validated = try await validate(FakeServer(userId: "usr-2"))
        let read = harness.keychain.holdNextRead()
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        // Saving the session.
        await read.arrived()

        await manager.logout()
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        read.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state == .signedOut && manager.lastError == nil)
    }

    @Test func switchFailingAfterANewerCallIsACancellation() async throws {
        let harness = try Harness()
        let id = try await signIn(harness.makeManager(), to: FakeServer())
        let manager = harness.makeManager()
        let read = harness.keychain.holdNextRead()
        let switching = Task { try await manager.switch(to: id) }
        await read.arrived()

        await #expect(throws: AccountError.connectionNotFound) { try await manager.switch(to: UUID()) }
        harness.keychain.failReads(with: errSecInteractionNotAllowed)
        read.open()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(manager.state == .signedOut && manager.lastError == nil)
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

    @Test func failedSignInDuringReconnectStaysOffline() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let id = try await signIn(harness.makeManager(), to: server)
        server.update { $0.isOffline = true }
        let manager = harness.makeManager()
        await manager.restoreSession()
        let offline = manager.state
        let validated = try await validate(FakeServer(userId: "usr-2"))

        server.update { $0.isOffline = false }
        let authorize = server.hold("/api/authorize")
        let reconnect = Task { await manager.restoreSession() }
        await authorize.arrived()
        // Supersedes the reconnect, then can't save its session.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        await #expect(throws: KeychainError.self) {
            try await manager.connect(local: validated, username: "david", password: "pw")
        }
        #expect(manager.state == offline)
        authorize.open()
        await reconnect.value
        #expect(manager.state == offline && manager.activeConnection?.id == id && manager.client != nil)
    }

    @Test func failedSignInDuringRestoreSignsOut() async throws {
        let harness = try Harness()
        _ = try await signIn(harness.makeManager(), to: FakeServer())
        let manager = harness.makeManager()
        let choosing = StubGate()
        manager.restoreWillChooseConnection = { await choosing.pass() }
        let restore = Task { await manager.restoreSession() }
        await choosing.arrived()
        let validated = try await validate(FakeServer(userId: "usr-2"))

        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        await #expect(throws: KeychainError.self) {
            try await manager.connect(local: validated, username: "david", password: "pw")
        }
        #expect(manager.state == .signedOut && manager.activeConnection == nil)
        choosing.open()
        await restore.value
        #expect(manager.state == .signedOut)
    }

    @Test(arguments: [false, true])
    func signInDuringRetryOfAFailedSessionDeleteKeepsItsSession(switching: Bool) async throws {
        let harness = try Harness()
        let server = FakeServer()
        let signedOut = harness.makeManager()
        let id = try await signIn(signedOut, to: server)
        // Neither the delete nor the server sign-out succeeds, so the session stays saved.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.update { $0.isOffline = true }
        await signedOut.logout()
        harness.keychain.failWrites(with: nil)
        server.update { $0.isOffline = false }

        let manager = harness.makeManager()
        let validated = try await validate(server)
        let reading = StubGate()
        manager.willReadSignedOutSession = { await reading.pass() }
        let retrying = Task {
            if switching { try await manager.switch(to: id) } else { await manager.restoreSession() }
        }
        await reading.arrived()
        let replacedLogout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        // Saved its session, and is ending the one it replaced.
        await replacedLogout.arrived()

        reading.open()
        if switching {
            await #expect(throws: CancellationError.self) { try await retrying.value }
        } else {
            try await retrying.value
        }
        replacedLogout.open()
        try await signingIn.value
        let user = try #require(manager.state.user)
        #expect(manager.state == .signedIn(user) && user.connectionID == id)
        #expect(try harness.session(id)?.refreshToken == "refresh-2")
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        let restored = try #require(relaunched.state.user)
        #expect(relaunched.state == .signedIn(restored) && restored.connectionID == id)
    }

    @Test func switchToASignedOutConnectionKeepsTheSessionOfASignInItSuperseded() async throws {
        let harness = try Harness()
        let server = FakeServer()
        let signedOut = harness.makeManager()
        let id = try await signIn(signedOut, to: server)
        await signedOut.logout()
        let manager = harness.makeManager()
        let validated = try await validate(server)
        let read = harness.keychain.holdNextRead()
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        // Saving the session.
        await read.arrived()
        let reading = StubGate()
        manager.willReadSignedOutSession = { await reading.pass() }
        let switching = Task { try await manager.switch(to: id) }
        // The switch has read the connection, signed out.
        await reading.arrived()

        read.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        reading.open()
        // Signed out when the switch read it, but the session is the sign-in's.
        await #expect(throws: AccountError.notSignedIn) { try await switching.value }
        #expect(try harness.session(id)?.refreshToken == "refresh-2")
        try await manager.switch(to: id)
        #expect(manager.state.user?.connectionID == id)
    }
}

/// Review findings on expiry, removal and cancellation.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountManagerExpiryAndRemovalTests {
    /// Client `first` refreshes T0 to T1 and retries it, held. Another client of the connection
    /// then starts T1 to T2, its response held, so the server only accepts T2. Returns the held
    /// retry, which the server will reject, and the other client's held refresh.
    private func rotateAwayFromRefreshedPair(
        _ server: FakeServer, first: APIClient, second: APIClient
    ) async throws -> (
        firstRequest: Task<Void, any Error>, secondRequest: Task<Void, any Error>, retry: StubGate,
        secondRefresh: StubGate
    ) {
        server.expireAccessToken()
        let firstRefresh = server.hold("/auth/refresh")
        let firstRequest = Task { _ = try await first.send(AuthEndpoints.authorize()) }
        await firstRefresh.arrived()
        let retry = server.hold("/api/authorize")
        firstRefresh.open()
        await retry.arrived()

        server.expireAccessToken()
        let secondRefresh = server.hold("/auth/refresh", answeringOnArrival: true)
        let secondRequest = Task { _ = try await second.send(AuthEndpoints.authorize()) }
        await secondRefresh.arrived()
        return (firstRequest, secondRequest, retry, secondRefresh)
    }

    @Test func rejectionOfARefreshedPairWaitsForAnotherClientsRefreshOfIt() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let first = try #require(manager.client)
        await manager.restoreSession()
        let second = try #require(manager.client)
        #expect(first !== second)
        let held = try await rotateAwayFromRefreshedPair(server, first: first, second: second)

        let joined = StubGate()
        await manager.credentials(for: id).observeRefreshJoins { joined.reach() }
        held.retry.open()
        // The retry's 401 is for T1, which the other client is refreshing: it waits for that.
        await joined.arrived()
        held.secondRefresh.open()
        try await held.firstRequest.value
        try await held.secondRequest.value
        #expect(manager.state.user?.connectionID == id && manager.lastError == nil)
        #expect(try harness.session(id)?.tokens == AuthTokens(accessToken: "access-3", refreshToken: "refresh-3"))
        #expect(server.requests("/auth/refresh").count == 2)
        #expect(server.loggedOutRefreshTokens.isEmpty)
    }

    @Test func rejectionOfARefreshedPairWithNothingInFlightExpiresOnce() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        server.expireAccessToken()
        let refresh = server.hold("/auth/refresh")
        let request = Task { _ = try await client.send(AuthEndpoints.authorize()) }
        await refresh.arrived()
        let retry = server.hold("/api/authorize")
        refresh.open()
        await retry.arrived()

        // The server rejects the refreshed pair, and nothing is refreshing it.
        server.revokeSession()
        retry.open()
        await #expect(throws: APIError.sessionExpired) { try await request.value }
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        #expect(try harness.session(id) == nil && server.requests("/auth/refresh").count == 1)
    }

    @Test func failedKeychainDeleteKeepsTheActiveConnectionOnRemoval() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let user = try #require(manager.state.user)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)

        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await manager.remove(id) }
        // Nothing changed: the connection, its session and the client are all still there.
        #expect(manager.state == .signedIn(user) && manager.activeConnection?.id == id && manager.client != nil)
        #expect(manager.connections.map(\.id) == [id] && server.loggedOutRefreshTokens.isEmpty)
        #expect(try harness.session(id) != nil)

        harness.keychain.failWrites(with: nil)
        try await manager.remove(id)
        #expect(manager.state == .signedOut && manager.connections.isEmpty)
    }

    @Test func removingTheConnectionASignInIsWaitingOnKeepsTheActiveOne() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let second = FakeServer(userId: "usr-2")
        let firstID = try await signIn(manager, to: first)
        let secondID = try await signIn(manager, to: second)
        let user = try #require(manager.state.user)
        let validated = try await validate(first)
        // Signing in again waits to end the session it replaced.
        let logout = first.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        try await manager.remove(firstID)
        #expect(manager.state == .signedIn(user) && manager.activeConnection?.id == secondID)
        #expect(manager.client != nil)
        logout.open()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(manager.state == .signedIn(user) && manager.connections.map(\.id) == [secondID])
        #expect(try harness.session(secondID) != nil && harness.session(firstID) == nil)
    }

    @Test func removingTheConnectionASwitchIsReadingKeepsTheActiveOne() async throws {
        let harness = try Harness()
        let setUp = harness.makeManager()
        let firstID = try await signIn(setUp, to: FakeServer())
        // Signed out, so a switch to it pauses before reading its session.
        await setUp.logout()
        let secondID = try await signIn(setUp, to: FakeServer(userId: "usr-2"))
        let manager = harness.makeManager()
        await manager.restoreSession()
        let user = try #require(manager.state.user)
        #expect(user.connectionID == secondID)
        let reading = StubGate()
        manager.willReadSignedOutSession = { await reading.pass() }
        let switching = Task { try await manager.switch(to: firstID) }
        await reading.arrived()

        try await manager.remove(firstID)
        #expect(manager.state == .signedIn(user) && manager.activeConnection?.id == secondID)
        reading.open()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(manager.state == .signedIn(user) && manager.client != nil)
    }

    @Test func expiryWithAFailedDeleteIsNotRestoredOfflineAfterARelaunch() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        // The rejected tokens are still on disk.
        #expect(try harness.session(id) != nil)

        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.map(\.id) == [id])
        #expect(relaunched.connections.first?.signedOutAt != nil)

        // Once the delete can succeed, the next launch removes the rejected session.
        harness.keychain.failWrites(with: nil)
        let again = harness.makeManager()
        await again.restoreSession()
        #expect(try again.state == .signedOut && harness.session(id) == nil)
    }

    @Test func expiryDoesNotMarkANewerSignInSignedOut() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
            // The delete keeps the custom headers, so it writes the item without the session.
            data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
        }
        server.revokeSession()
        var signedInAgain = false
        // After the expiry signed out, before it saves that.
        manager.willSaveExpiry = {
            _ = try? await signIn(manager, to: server)
            signedInAgain = true
        }
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        #expect(signedInAgain)
        #expect(try await harness.store.connection(id: id)?.signedOutAt == nil)
        #expect(manager.state.user?.connectionID == id)

        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == id && relaunched.lastError == nil)
    }

    @Test func olderExpiryDoesNotClearANewerExpiredSessionSignOut() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let firstClient = try #require(manager.client)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
            // The delete keeps the custom headers, so it writes the item without the session.
            data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
        }

        let olderExpiry = StubGate()
        let newerExpiry = StubGate()
        var expirySaves = 0
        manager.willSaveExpiry = {
            expirySaves += 1
            if expirySaves == 1 {
                await olderExpiry.pass()
            } else {
                await newerExpiry.pass()
            }
        }

        server.revokeSession()
        let firstRequest = Task { _ = try await firstClient.send(AuthEndpoints.authorize()) }
        await olderExpiry.arrived()

        // A newer sign-in, and its own expiry, happen while the older handler waits to save.
        _ = try await signIn(manager, to: server)
        let secondClient = try #require(manager.client)
        server.revokeSession()
        let secondRequest = Task { _ = try await secondClient.send(AuthEndpoints.authorize()) }
        await newerExpiry.arrived()
        newerExpiry.open()
        await #expect(throws: APIError.sessionExpired) { try await secondRequest.value }
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)

        // The older save happens last. Its cleanup must not clear the newer expiry's sign-out.
        olderExpiry.open()
        await #expect(throws: APIError.sessionExpired) { try await firstRequest.value }
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)

        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.first?.signedOutAt != nil)
    }

    @Test func signInStoppedByAnExpiryKeepsTheSignOutTheExpirySaved() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let oldClient = try #require(manager.client)
        let validated = try await validate(server)
        // Signing in again holds while ending the replaced session.
        let logout = server.hold("/logout")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await logout.arrived()

        // The active client uses the new session, which the server rejects. The Keychain can't
        // delete it, so the expiry saves the sign-out.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
            // The delete keeps the custom headers, so it writes the item without the session.
            data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
        }
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await oldClient.send(AuthEndpoints.authorize()) }
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)
        logout.open()
        await #expect(throws: AccountError.server(.sessionExpired)) { try await signingIn.value }
        // The sign-in mustn't clear it as the sign-out of a session it keeps for switching to.
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)
        #expect(manager.state == .signedOut && manager.connections.first?.signedOutAt != nil)

        // The rejected tokens are still stored, and aren't restored offline.
        #expect(try harness.session(id) != nil)
        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.first?.signedOutAt != nil)
    }

    @Test(arguments: [false, true])
    func failedRemovalDoesNotReviveAnotherConnectionThatEndedMeanwhile(removed: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let other = FakeServer()
        let active = FakeServer(userId: "usr-2")
        let otherID = try await signIn(manager, to: other)
        let activeID = try await signIn(manager, to: active)
        let activeClient = try #require(manager.client)
        var isHeld = false
        let deleting = StubGate()
        manager.willDeleteRemovedSession = {
            // Only the first removal waits.
            guard !isHeld else { return }
            isHeld = true
            await deleting.pass()
        }
        let removingOther = Task { try await manager.remove(otherID) }
        await deleting.arrived()

        if removed {
            try await manager.remove(activeID)
        } else {
            active.revokeSession()
            await #expect(throws: APIError.sessionExpired) { try await activeClient.send(AuthEndpoints.authorize()) }
        }
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await removingOther.value }
        // The active connection was signed out or removed when the delete failed, and stays so.
        #expect(manager.state == .signedOut && manager.activeConnection == nil && manager.client == nil)
        #expect(manager.lastError == (removed ? nil : .server(.sessionExpired)))
        #expect(Set(manager.connections.map(\.id)) == Set(removed ? [otherID] : [otherID, activeID]))
        #expect(try harness.session(otherID) != nil)
    }

    @Test func failedRemovalDoesNotReviveTheConnectionWhoseSessionExpiredMeanwhile() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        let deleting = StubGate()
        manager.willDeleteRemovedSession = { await deleting.pass() }
        let removing = Task { try await manager.remove(id) }
        await deleting.arrived()

        // Removing it signed out already, so the expiry publishes nothing.
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await removing.value }
        // Not signed in again with the session that expired.
        #expect(manager.state == .signedOut && manager.activeConnection == nil && manager.client == nil)
        #expect(try harness.session(id) == nil && manager.connections.map(\.id) == [id])
    }

    @Test(arguments: [false, true])
    func removingTheConnectionASwitchIsReadingEndsTheRestoreItSuperseded(hasActive: Bool) async throws {
        let harness = try Harness()
        let setUp = harness.makeManager()
        let firstID = try await signIn(setUp, to: FakeServer())
        // Signed out, so a switch to it pauses before reading its session.
        await setUp.logout()
        let second = FakeServer(userId: "usr-2")
        let secondID = try await signIn(setUp, to: second)
        // Offline, so a restore keeps the connection without verifying it.
        second.update { $0.isOffline = true }
        let manager = harness.makeManager()
        if hasActive { await manager.restoreSession() }
        let expected = manager.state
        let expectedID = hasActive ? secondID : nil
        #expect(manager.activeConnection?.id == expectedID)
        let choosing = StubGate()
        manager.restoreWillChooseConnection = { await choosing.pass() }
        let restoring = Task { await manager.restoreSession() }
        await choosing.arrived()
        let reading = StubGate()
        manager.willReadSignedOutSession = { await reading.pass() }
        let switching = Task { try await manager.switch(to: firstID) }
        await reading.arrived()
        #expect(manager.state == .restoring)

        // Both calls are superseded, so neither would end the restore.
        try await manager.remove(firstID)
        #expect(manager.state == expected && manager.activeConnection?.id == expectedID)
        reading.open()
        await #expect(throws: CancellationError.self) { try await switching.value }
        choosing.open()
        await restoring.value
        #expect(manager.state == expected && manager.activeConnection?.id == expectedID)
    }

    // MARK: - #227

    /// An expiry while the connection is being removed doesn't save its sign-out, expecting the
    /// delete. When the delete fails, the removal saves it, so the tokens aren't restored offline.
    @Test func failedRemovalSavesTheSignOutOfASessionThatExpiredMeanwhile() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        let deleting = StubGate()
        manager.willDeleteRemovedSession = { await deleting.pass() }
        let removing = Task { try await manager.remove(id) }
        await deleting.arrived()

        // The Keychain can delete neither the expired session nor, then, the connection's items.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        #expect(try await harness.store.connection(id: id)?.signedOutAt == nil)
        deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await removing.value }
        #expect(try harness.session(id) != nil)
        #expect(manager.connections.map(\.id) == [id] && manager.connections.first?.signedOutAt != nil)

        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.map(\.id) == [id])
    }

    /// The store needn't run its jobs in call order, so an expiry's sign-out can be saved before a
    /// sign-in's mark as used, which clears a sign-out. The sign-in saves it again.
    @Test func signInMarkingUsedKeepsTheSignOutOfAnExpiryMeanwhile() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let oldClient = try #require(manager.client)
        let validated = try await validate(server)
        manager.willMarkUsed = {
            manager.willMarkUsed = nil
            // The active client uses the new session, which the server rejects; the Keychain can't
            // delete it, so the expiry saves the sign-out.
            harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
                // The delete keeps the custom headers, so it writes the item without the session.
                data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
            }
            server.revokeSession()
            _ = try? await oldClient.send(AuthEndpoints.authorize())
        }

        await #expect(throws: AccountError.server(.sessionExpired)) {
            try await manager.connect(local: validated, username: "david", password: "pw")
        }
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)
        #expect(try harness.session(id) != nil)

        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.first?.signedOutAt != nil)
    }

    /// As for a sign-in: a switch's mark as used doesn't lose the sign-out of an expiry meanwhile.
    @Test func switchMarkingUsedKeepsTheSignOutOfAnExpiryMeanwhile() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let first = FakeServer()
        let firstID = try await signIn(manager, to: first)
        _ = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        manager.willMarkUsed = {
            manager.willMarkUsed = nil
            guard let client = manager.client else { return }
            harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
                // The delete keeps the custom headers, so it writes the item without the session.
                data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
            }
            first.revokeSession()
            _ = try? await client.send(AuthEndpoints.authorize())
        }

        try await manager.switch(to: firstID)
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        #expect(try await harness.store.connection(id: firstID)?.signedOutAt != nil)
        #expect(try harness.session(firstID) != nil)
    }

    /// Two removals of one connection overlap: the first failing doesn't stop the second's
    /// connection counting as being removed, so no download client is made for it meanwhile.
    @Test func aFailedRemovalDoesNotEndAnOverlappingRemovalOfTheConnection() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let otherID = try await signIn(manager, to: FakeServer())
        _ = try await signIn(manager, to: FakeServer(userId: "usr-2"))
        #expect(await manager.downloadClient(for: otherID) != nil)
        let firstGate = StubGate()
        let secondGate = StubGate()
        var arrivals = 0
        manager.willDeleteRemovedSession = {
            arrivals += 1
            await (arrivals == 1 ? firstGate : secondGate).pass()
        }
        let firstRemoval = Task { try await manager.remove(otherID) }
        await firstGate.arrived()
        let secondRemoval = Task { try await manager.remove(otherID) }
        await secondGate.arrived()

        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        firstGate.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await firstRemoval.value }
        harness.keychain.failWrites(with: nil)
        #expect(await manager.downloadClient(for: otherID) == nil)

        secondGate.open()
        try await secondRemoval.value
        #expect(manager.connections.count == 1 && manager.connections.first?.id != otherID)
        #expect(try harness.session(otherID) == nil)
    }

    /// A failed removal of the active connection doesn't put it back over a newer call, here a
    /// logout that found nothing to sign out of, which leaves the state as the removal did.
    @Test func failedRemovalDoesNotReviveTheActiveConnectionAfterANewerCall() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let id = try await signIn(manager, to: FakeServer())
        let deleting = StubGate()
        manager.willDeleteRemovedSession = { await deleting.pass() }
        let removing = Task { try await manager.remove(id) }
        await deleting.arrived()

        #expect(await manager.logout() == nil)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await removing.value }
        #expect(manager.state == .signedOut && manager.activeConnection == nil && manager.client == nil)
    }

    /// Nor over another connection that a sign-in started earlier made active meanwhile, which
    /// doesn't begin a newer call.
    @Test func failedRemovalDoesNotReviveTheActiveConnectionOverAnotherThatSignedIn() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let firstID = try await signIn(manager, to: FakeServer())
        let second = FakeServer(userId: "usr-2")
        let validated = try await validate(second)
        let login = second.hold("/login")
        let signingIn = Task { try await manager.connect(local: validated, username: "david", password: "pw") }
        await login.arrived()
        let deleting = StubGate()
        manager.willDeleteRemovedSession = { await deleting.pass() }
        let removing = Task { try await manager.remove(firstID) }
        await deleting.arrived()

        login.open()
        try await signingIn.value
        let user = try #require(manager.state.user)
        #expect(user.connectionID != firstID)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await removing.value }
        #expect(manager.state == .signedIn(user) && manager.activeConnection?.id == user.connectionID)
        #expect(try harness.session(firstID) != nil)
    }

    /// A failed removal saves the sign-out of an expiry meanwhile; a sign-in that saves a newer
    /// session and marks the connection used while that save is pending keeps its session usable,
    /// even after a relaunch. Unless it's logged out meanwhile and its delete fails: that keeps
    /// the sign-out, so the tokens aren't restored offline.
    @Test(arguments: [false, true])
    func failedRemovalsExpirySaveDoesNotMarkANewerSignInSignedOut(logsOut: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        let deleting = StubGate()
        manager.willDeleteRemovedSession = { await deleting.pass() }
        let removing = Task { try await manager.remove(id) }
        await deleting.arrived()
        manager.willDeleteRemovedSession = nil

        // The Keychain can delete neither the expired session nor the connection's items.
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        var signedInAgain = false
        // After the removal failed, before it saves the expiry's sign-out.
        manager.willSaveSignOutOfExpiry = {
            manager.willSaveSignOutOfExpiry = nil
            harness.keychain.failWrites(with: nil)
            _ = try? await signIn(manager, to: server)
            signedInAgain = true
            guard logsOut else { return }
            harness.keychain.failWrites(with: errSecInteractionNotAllowed)
            await manager.logout()
        }
        deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await removing.value }

        #expect(signedInAgain)
        let relaunched = harness.makeManager()
        if logsOut {
            #expect(try harness.session(id) != nil)
            #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)
            server.update { $0.isOffline = true }
            await relaunched.restoreSession()
            #expect(relaunched.state == .signedOut)
            return
        }
        #expect(try await harness.store.connection(id: id)?.signedOutAt == nil)
        #expect(manager.state.user?.connectionID == id)
        await relaunched.restoreSession()
        #expect(relaunched.state.user?.connectionID == id && relaunched.lastError == nil)
    }

    // MARK: - #497

    /// Starts removing the connection, holds it before the delete, then expires its session while
    /// the Keychain can delete neither that session nor, then, the connection's items. Returns the
    /// removal and its held delete.
    private func removeWhileTheSessionExpires(
        _ manager: AccountManager, harness: Harness, server: FakeServer, id: UUID
    ) async throws -> (removing: Task<URL?, any Error>, deleting: StubGate) {
        let client = try #require(manager.client)
        let deleting = StubGate()
        manager.willDeleteRemovedSession = { await deleting.pass() }
        let removing = Task { try await manager.remove(id) }
        await deleting.arrived()
        manager.willDeleteRemovedSession = nil
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        return (removing, deleting)
    }

    /// Signs in again, then expires that session too, where the Keychain can't delete it.
    private func signInAndExpireAgain(_ manager: AccountManager, harness: Harness, server: FakeServer) async {
        harness.keychain.failWrites(with: nil)
        _ = try? await signIn(manager, to: server)
        await expireAgain(manager, harness: harness, server: server)
    }

    private func expireAgain(_ manager: AccountManager, harness: Harness, server: FakeServer) async {
        guard let client = manager.client else { return }
        harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
            // The delete keeps the custom headers, so it writes the item without the session.
            data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
        }
        server.revokeSession()
        _ = try? await client.send(AuthEndpoints.authorize())
    }

    /// A failed removal saves the sign-out of an expiry meanwhile. A newer session that expires,
    /// with a failed delete, while the removal clears that sign-out for it, or once the removal has
    /// saved it and is reloading the connections, saves its own: the removal stopped counting when
    /// its delete failed. So the newer tokens aren't restored offline after a relaunch.
    @Test(arguments: [false, true])
    func expiryDuringAFailedRemovalsRecoverySavesItsSignOut(duringClear: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let held = try await removeWhileTheSessionExpires(manager, harness: harness, server: server, id: id)
        var expiredAgain = false
        if duringClear {
            // Signed in again before the removal saves the sign-out, so the removal then clears it.
            manager.willSaveSignOutOfExpiry = {
                manager.willSaveSignOutOfExpiry = nil
                harness.keychain.failWrites(with: nil)
                _ = try? await signIn(manager, to: server)
            }
            manager.willClearSignOutOfExpiry = {
                manager.willClearSignOutOfExpiry = nil
                await self.expireAgain(manager, harness: harness, server: server)
                expiredAgain = true
            }
        } else {
            manager.willReloadAfterFailedRemoval = {
                manager.willReloadAfterFailedRemoval = nil
                await self.signInAndExpireAgain(manager, harness: harness, server: server)
                expiredAgain = true
            }
        }
        held.deleting.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await held.removing.value }

        #expect(expiredAgain)
        #expect(manager.state == .signedOut && manager.lastError == .server(.sessionExpired))
        #expect(try harness.session(id) != nil)
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)
        #expect(manager.connections.map(\.id) == [id] && manager.connections.first?.signedOutAt != nil)
        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.map(\.id) == [id])
    }

    /// Unless another removal of the connection is still running: the expiry then leaves its
    /// sign-out to that removal, which deletes the connection.
    @Test func expiryDuringAFailedRemovalsRecoveryDefersToAnOverlappingRemoval() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        let firstGate = StubGate()
        let secondGate = StubGate()
        var arrivals = 0
        manager.willDeleteRemovedSession = {
            arrivals += 1
            await (arrivals == 1 ? firstGate : secondGate).pass()
        }
        let firstRemoval = Task { try await manager.remove(id) }
        await firstGate.arrived()
        let secondRemoval = Task { try await manager.remove(id) }
        await secondGate.arrived()
        harness.keychain.failWrites(with: errSecInteractionNotAllowed)
        server.revokeSession()
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }
        var expiredAgain = false
        manager.willReloadAfterFailedRemoval = {
            manager.willReloadAfterFailedRemoval = nil
            await self.signInAndExpireAgain(manager, harness: harness, server: server)
            expiredAgain = true
        }
        firstGate.open()
        await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try await firstRemoval.value }

        #expect(expiredAgain)
        // The first removal's sign-out was cleared by the sign-in, and the expiry saved none.
        #expect(try await harness.store.connection(id: id)?.signedOutAt == nil)
        harness.keychain.failWrites(with: nil)
        secondGate.open()
        try await secondRemoval.value
        #expect(manager.state == .signedOut && manager.connections.isEmpty)
        #expect(try harness.session(id) == nil)
    }

    /// A logout of a newer session while an expiry saves its sign-out, where the logout's delete
    /// fails: the expiry's save replaced the logout's sign-out, so it keeps it, and the tokens
    /// aren't restored offline after a relaunch.
    @Test func expiryKeepsItsSignOutOverALogoutWhileItSaved() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let client = try #require(manager.client)
        harness.keychain.failWrites(with: errSecInteractionNotAllowed) { data in
            // The delete keeps the custom headers, so it writes the item without the session.
            data.map { !String(decoding: $0, as: UTF8.self).contains("accessToken") } ?? true
        }
        server.revokeSession()
        var loggedOut = false
        // After the expiry signed out, before it saves that.
        manager.willSaveExpiry = {
            manager.willSaveExpiry = nil
            _ = try? await signIn(manager, to: server)
            await manager.logout()
            loggedOut = true
        }
        await #expect(throws: APIError.sessionExpired) { try await client.send(AuthEndpoints.authorize()) }

        #expect(loggedOut)
        #expect(manager.state == .signedOut)
        #expect(try harness.session(id) != nil)
        #expect(try await harness.store.connection(id: id)?.signedOutAt != nil)
        server.update { $0.isOffline = true }
        let relaunched = harness.makeManager()
        await relaunched.restoreSession()
        #expect(relaunched.state == .signedOut && relaunched.connections.first?.signedOutAt != nil)
    }
}

/// A browser sign-in the user cancelled.
private struct CancelledAuthenticator: WebAuthenticator {
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        throw CancellationError()
    }
}

/// ``AccountManager/authenticate(local:username:password:)`` and its OpenID twin change nothing;
/// ``AccountManager/activate(_:)`` saves and activates, as `connect` does.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountManagerAuthenticateTests {
    @Test(arguments: [false, true])
    func authenticatingSavesNothingUntilActivated(oidc: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let validated = try await validate(server)

        let signIn =
            oidc
            ? try await manager.authenticate(oidc: validated, authenticator: FakeAuthenticator())
            : try await manager.authenticate(local: validated, username: "david", password: "pw")
        #expect(manager.state == .signedOut && manager.activeConnection == nil && manager.client == nil)
        #expect(manager.connections.isEmpty && harness.keychain.isEmpty)
        #expect(manager.credentialsRevision == 0)
        #expect(try await harness.store.connectionToRestore() == nil)

        try await manager.activate(signIn)
        let id = try #require(manager.activeConnection?.id)
        #expect(manager.state.user?.authMethod == (oidc ? .openid : .local))
        #expect(try harness.session(id)?.tokens == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(try harness.customHeaders(id) == ["X-Proxy": "proxy-secret"])
        #expect(server.loggedOutRefreshTokens.isEmpty)
    }

    /// Activating another account keeps the active one's saved session, as `connect` does.
    @Test func activatingKeepsTheOtherAccountsSession() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let firstID = try await signIn(manager, to: FakeServer())
        let validated = try await validate(FakeServer(userId: "usr-2"))

        let signIn = try await manager.authenticate(local: validated, username: "david", password: "pw")
        #expect(manager.activeConnection?.id == firstID && manager.connections.map(\.id) == [firstID])

        try await manager.activate(signIn)
        let secondID = try #require(manager.activeConnection?.id)
        #expect(secondID != firstID && manager.connections.map(\.id) == [secondID, firstID])
        #expect(try harness.session(firstID) != nil)
        #expect(try harness.session(secondID) != nil)
    }

    /// A rejected password or a cancelled browser leaves the active account, its saved session,
    /// and the connections as they were.
    @Test(arguments: [false, true])
    func failedAuthenticationChangesNothing(oidc: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let firstID = try await signIn(manager, to: FakeServer())
        let state = manager.state
        let session = try harness.session(firstID)
        let revision = manager.credentialsRevision
        let server = FakeServer(userId: "usr-2")
        let validated = try await validate(server)

        if oidc {
            await #expect(throws: OIDCLoginError.cancelled) {
                try await manager.authenticate(oidc: validated, authenticator: CancelledAuthenticator())
            }
        } else {
            server.update { $0.isOffline = true }
            await #expect(throws: (any Error).self) {
                try await manager.authenticate(local: validated, username: "david", password: "wrong")
            }
        }
        #expect(manager.state == state && manager.activeConnection?.id == firstID && manager.lastError == nil)
        #expect(manager.connections.map(\.id) == [firstID])
        #expect(try harness.session(firstID) == session && manager.credentialsRevision == revision)
        #expect(server.requests("/logout").isEmpty)
    }

    /// Authenticating doesn't supersede a restore that's running.
    @Test func authenticatingLeavesARunningRestore() async throws {
        let harness = try Harness()
        let first = FakeServer()
        let firstID = try await signIn(harness.makeManager(), to: first)
        let manager = harness.makeManager()
        let authorize = first.hold("/api/authorize")
        let restore = Task { await manager.restoreSession() }
        await authorize.arrived()

        _ = try await manager.authenticate(
            local: try await validate(FakeServer(userId: "usr-2")), username: "david", password: "pw")
        #expect(manager.state == .restoring)
        authorize.open()
        await restore.value
        #expect(manager.state.user?.connectionID == firstID && manager.lastError == nil)
    }

    @Test func discardingEndsTheServerSessionOnly() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()

        let signIn = try await manager.authenticate(
            local: try await validate(server), username: "david", password: "pw")
        await manager.discard(signIn)
        #expect(server.loggedOutRefreshTokens == ["refresh-1"])
        #expect(manager.state == .signedOut && manager.connections.isEmpty && harness.keychain.isEmpty)
    }

    /// A logout or removal since the sign-in was checked isn't undone by activating it.
    @Test(arguments: [false, true])
    func activatingAfterALogoutOrRemovalIsCancelled(removing: Bool) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let server = FakeServer()
        let id = try await signIn(manager, to: server)
        let signIn = try await manager.authenticate(
            local: try await validate(server), username: "david", password: "pw")

        if removing { try await manager.remove(id) } else { await manager.logout() }
        await #expect(throws: CancellationError.self) { try await manager.activate(signIn) }
        #expect(manager.state == .signedOut && manager.activeConnection == nil)
        #expect(manager.connections.map(\.id) == (removing ? [] : [id]))
        #expect(try harness.session(id) == nil)
        #expect(server.loggedOutRefreshTokens == ["refresh-1", "refresh-2"])
    }
}
