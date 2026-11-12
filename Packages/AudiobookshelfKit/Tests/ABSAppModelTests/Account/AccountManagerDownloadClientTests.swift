import ABSCore
import Foundation
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

    private func signIn(to server: TokenServer) async throws -> UUID {
        let validated = try await ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
            .validate(address: server.address, customHeaders: [:])
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
}
