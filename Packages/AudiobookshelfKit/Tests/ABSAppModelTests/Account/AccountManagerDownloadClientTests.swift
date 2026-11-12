import ABSCore
import Foundation
import Security
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel
@testable import ABSData

/// A server on a unique stub host that issues a new token pair on each sign-in and refresh.
private final class TokenServer: Sendable {
    let host = "\(UUID().uuidString.lowercased()).download-client.test"
    let userId: String
    private let issued = Mutex(0)
    /// Answers `/auth/refresh` with 401, ending the session.
    private let rejectsRefresh = Mutex(false)

    init(userId: String) {
        self.userId = userId
        StubURLProtocol.register(host: host) { [self] request in respond(to: request) }
    }

    var address: String { "https://\(host)/abs" }

    func rejectRefreshes() { rejectsRefresh.withLock { $0 = true } }

    var refreshes: Int { StubURLProtocol.requests(host: host).filter { $0.url?.path() == "/abs/auth/refresh" }.count }

    private func respond(to request: URLRequest) -> StubResponse {
        issued.withLock { issued in
            switch request.url?.path() {
            case "/abs/status":
                return .json(
                    #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local"]}"#)
            case "/abs/auth/refresh" where rejectsRefresh.withLock({ $0 }):
                return .json("{}", status: 401)
            case "/abs/login", "/abs/auth/refresh":
                issued += 1
                return .json(authJSON(tokens: issued))
            case "/abs/api/authorize":
                return .json(authJSON(tokens: nil))
            case "/abs/logout":
                return .json(#"{"redirect_url":null}"#)
            default:
                return .json("{}", status: 404)
            }
        }
    }

    private func authJSON(tokens: Int?) -> String {
        let pair = tokens.map {
            #","accessToken":"\#(userId)-access-\#($0)","refreshToken":"\#(userId)-refresh-\#($0)""#
        }
        return #"{"user":{"id":"\#(userId)","username":"david","type":"admin","token":null\#(pair ?? "")},"#
            + #""userDefaultLibraryId":"lib1","serverSettings":{"version":"2.26.0"}}"#
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountManagerDownloadClientTests {
    let keychain = InMemoryKeychain()
    let store: ServerConnectionStore
    let manager: AccountManager

    init() throws {
        store = ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container)
        manager = AccountManager(
            store: store, keychain: keychain,
            validator: ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() }),
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
    }

    private func signIn(to server: TokenServer, customHeaders: [String: String] = [:]) async throws -> UUID {
        let validated = try await ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
            .validate(address: server.address, customHeaders: customHeaders)
        try await manager.connect(local: validated, username: "david", password: "pw")
        return try #require(manager.activeConnection?.id)
    }

    @Test func activeConnectionGetsTheActiveClient() async throws {
        let id = try await signIn(to: TokenServer(userId: "usr-a"))

        let client = try #require(await manager.downloadClient(for: id))
        #expect(client === manager.client)
    }

    @Test func savedConnectionThatIsNotActiveGetsOneClientOverItsCredentials() async throws {
        let serverA = TokenServer(userId: "usr-a")
        let idA = try await signIn(to: serverA)
        let idB = try await signIn(to: TokenServer(userId: "usr-b"))
        #expect(manager.activeConnection?.id == idB)

        let client = try #require(await manager.downloadClient(for: idA))
        #expect(client !== manager.client)
        #expect(await client.configuration.baseURL.host() == serverA.host)
        #expect(await client.currentAccessToken() == "usr-a-access-1")
        #expect(await manager.downloadClient(for: idA) === client)

        // A refresh goes through the connection's credentials: it's saved for the connection.
        #expect(try await client.accessToken(replacing: "usr-a-access-1") == "usr-a-access-2")
        #expect(serverA.refreshes == 1)
        #expect(try CredentialVault(keychain: keychain).session(for: idA)?.tokens.accessToken == "usr-a-access-2")
    }

    @Test func unknownConnectionGetsNothing() async throws {
        _ = try await signIn(to: TokenServer(userId: "usr-a"))

        #expect(await manager.downloadClient(for: UUID()) == nil)
    }

    @Test func signedOutConnectionGetsNothing() async throws {
        let idA = try await signIn(to: TokenServer(userId: "usr-a"))
        let idB = try await signIn(to: TokenServer(userId: "usr-b"))
        #expect(await manager.downloadClient(for: idA) != nil)

        try await manager.switch(to: idA)
        await manager.logout()

        #expect(await manager.downloadClient(for: idA) == nil)
        #expect(await manager.downloadClient(for: idB) != nil)
    }

    /// An expiry whose delete failed saves the sign-out without a logout; a kept client isn't used.
    @Test func connectionSignedOutInTheStoreGetsNothingEvenWithAKeptClient() async throws {
        let idA = try await signIn(to: TokenServer(userId: "usr-a"))
        _ = try await signIn(to: TokenServer(userId: "usr-b"))
        #expect(await manager.downloadClient(for: idA) != nil)

        #expect(try await store.setSignedOut(id: idA, at: .now))

        #expect(await manager.downloadClient(for: idA) == nil)
    }

    /// An expiry deletes the tokens without saving a sign-out; the kept client isn't used.
    @Test func expiredConnectionGetsNothingEvenWithAKeptClient() async throws {
        let serverA = TokenServer(userId: "usr-a")
        let idA = try await signIn(to: serverA)
        let idB = try await signIn(to: TokenServer(userId: "usr-b"))
        let kept = try #require(await manager.downloadClient(for: idA))

        serverA.rejectRefreshes()
        await #expect(throws: APIError.sessionExpired) { try await kept.accessToken(replacing: "usr-a-access-1") }

        #expect(try await store.connection(id: idA)?.signedOutAt == nil)
        #expect(await manager.downloadClient(for: idA) == nil)
        #expect(await manager.downloadClient(for: idB) === manager.client)
    }

    /// A sign-out while the lookup reads the Keychain: the session it read is being deleted.
    @Test func lookupThatOverlapsASignOutGetsNothing() async throws {
        let idA = try await signIn(to: TokenServer(userId: "usr-a"))
        // A relaunch, so the lookup reads the session from the Keychain.
        let relaunched = AccountManager(
            store: store, keychain: keychain,
            validator: ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() }),
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
        let read = keychain.holdNextRead()
        let lookup = Task { await relaunched.downloadClient(for: idA) }
        await read.arrived()

        // Restoring A, so the logout signs A out; both wait for the held read.
        let restore = Task { await relaunched.restoreSession() }
        while relaunched.state != .restoring { await Task.yield() }
        let logout = Task { await relaunched.logout() }
        while try await store.connection(id: idA)?.signedOutAt == nil { await Task.yield() }
        read.open()

        #expect(await lookup.value == nil)
        _ = await logout.value
        await restore.value
        #expect(relaunched.state == .signedOut)
        #expect(await relaunched.downloadClient(for: idA) == nil)
    }

    @Test func removedConnectionGetsNothing() async throws {
        let idA = try await signIn(to: TokenServer(userId: "usr-a"))
        let idB = try await signIn(to: TokenServer(userId: "usr-b"))
        #expect(await manager.downloadClient(for: idA) != nil)

        try await manager.remove(idA)
        #expect(await manager.downloadClient(for: idA) == nil)

        try await manager.remove(idB)
        #expect(await manager.downloadClient(for: idB) == nil)
    }

    @Test func signingInAgainGivesTheNewClient() async throws {
        let server = TokenServer(userId: "usr-a")
        let id = try await signIn(to: server)
        let first = try #require(await manager.downloadClient(for: id))

        await manager.logout()
        #expect(await manager.downloadClient(for: id) == nil)
        _ = try await signIn(to: server)

        let second = try #require(await manager.downloadClient(for: id))
        #expect(second !== first && second === manager.client)
    }

    /// A client kept from before a new sign-in to the connection (which may change its custom
    /// headers) isn't used once the connection is no longer active.
    @Test func signingInAgainReplacesAKeptClientWithTheNewHeaders() async throws {
        let serverA = TokenServer(userId: "usr-a")
        let idA = try await signIn(to: serverA)
        let serverB = TokenServer(userId: "usr-b")
        _ = try await signIn(to: serverB)
        let kept = try #require(await manager.downloadClient(for: idA))
        #expect(await kept.configuration.customHeaders.isEmpty)

        // Signed into again with new headers, then switched away without a lookup while active.
        #expect(try await signIn(to: serverA, customHeaders: ["X-Proxy": "1"]) == idA)
        _ = try await signIn(to: serverB)

        let client = try #require(await manager.downloadClient(for: idA))
        #expect(client !== kept)
        #expect(await client.configuration.customHeaders == ["X-Proxy": "1"])
        #expect(await manager.downloadClient(for: idA) === client)
    }

    // MARK: - Removal

    /// The downloads are stopped once the session is deleted, but while the connection is
    /// still saved, for an inactive connection as for the active one.
    @Test(arguments: [false, true])
    func removalReportsTheDeletedCredentialsBeforeRemovingTheConnection(active: Bool) async throws {
        let idA = try await signIn(to: TokenServer(userId: "usr-a"))
        if !active { _ = try await signIn(to: TokenServer(userId: "usr-b")) }
        let reported = Mutex<[(id: UUID, sessionDeleted: Bool, connectionSaved: Bool)]>([])
        let keychain = keychain
        let store = store
        manager.credentialsRemoved = { id in
            let deleted = (try? CredentialVault(keychain: keychain).session(for: id)) == nil
            let saved = (try? await store.connection(id: id)) != nil
            reported.withLock { $0.append((id, deleted, saved)) }
        }

        try await manager.remove(idA)

        let calls = reported.withLock { $0 }
        #expect(calls.count == 1)
        #expect(calls.first?.id == idA)
        #expect(calls.first?.sessionDeleted == true)
        #expect(calls.first?.connectionSaved == true)
    }

    /// A removal whose Keychain delete fails keeps the session, so the downloads keep their
    /// progress: nothing is reported.
    @Test func failedRemovalReportsNothing() async throws {
        let idA = try await signIn(to: TokenServer(userId: "usr-a"))
        _ = try await signIn(to: TokenServer(userId: "usr-b"))
        let reported = Mutex(0)
        manager.credentialsRemoved = { _ in reported.withLock { $0 += 1 } }
        keychain.failWrites(with: errSecInteractionNotAllowed) { $0 == nil }

        await #expect(throws: KeychainError.self) { try await manager.remove(idA) }

        #expect(reported.withLock { $0 } == 0)
        #expect(try await store.connection(id: idA) != nil)
    }
}
