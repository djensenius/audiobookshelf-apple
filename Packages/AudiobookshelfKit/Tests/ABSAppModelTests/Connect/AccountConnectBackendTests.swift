import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel

/// An Audiobookshelf server on a unique stub host that accepts any sign-in.
private final class StubServer: Sendable {
    struct State {
        /// Fails every `https` request to connect, so a schemeless address falls back to `http`.
        var httpsFails = false
        /// Fails `/api/authorize` to connect, as when the server is offline.
        var authorizeFails = false
        /// Answers `/api/authorize` with this status. `/auth/refresh` always answers 401.
        var authorizeStatus: Int?
        var authorizeVersion = "2.26.0"
    }

    let host = "\(UUID().uuidString.lowercased()).stub.test"
    private let state = Mutex(State())

    init() {
        StubURLProtocol.register(host: host) { [self] request in respond(to: request) }
    }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var requests: [URLRequest] { StubURLProtocol.requests(host: host) }

    /// Each request as `scheme path`.
    var requestLines: [String] { requests.map { "\($0.url?.scheme ?? "") \($0.url?.path() ?? "")" } }

    private func respond(to request: URLRequest) -> StubResponse {
        state.withLock { state in
            if state.httpsFails, request.url?.scheme == "https" { return .failure(.cannotConnectToHost) }
            switch request.url?.path() {
            case "/status":
                return .json(
                    #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local"]}"#)
            case "/login":
                return .json(Self.authJSON(tokens: true, version: "2.26.0"))
            case "/api/authorize":
                if state.authorizeFails { return .failure(.cannotConnectToHost) }
                if let status = state.authorizeStatus { return .json("{}", status: status) }
                return .json(Self.authJSON(tokens: false, version: state.authorizeVersion))
            case "/auth/refresh":
                return .json("{}", status: 401)
            default:
                return .json("{}", status: 404)
            }
        }
    }

    private static func authJSON(tokens: Bool, version: String) -> String {
        let tokens = tokens ? #","accessToken":"access","refreshToken":"refresh""# : ""
        return #"{"user":{"id":"usr-1","username":"david","type":"admin","token":null\#(tokens)},"#
            + #""userDefaultLibraryId":"lib1","serverSettings":{"version":"\#(version)"}}"#
    }
}

private struct LocalNetworkAllowed: LocalNetworkAccessChecking {
    func isDenied(host: String, port: Int) async -> Bool { false }
}

/// One store and Keychain, shared by every manager made from it, as across relaunches.
@MainActor
private struct Fixture {
    let server = StubServer()
    let keychain = InMemoryKeychain()
    let store: ServerConnectionStore
    let validator = ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() })

    init() throws {
        store = ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    func makeAccounts() -> AccountManager {
        AccountManager(
            store: store, keychain: keychain, validator: validator,
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
    }

    func model(_ accounts: AccountManager) -> ConnectViewModel {
        ConnectViewModel(accounts: accounts, validator: validator, localNetwork: LocalNetworkAllowed())
    }

    /// Signs in through the flow and returns the saved connection.
    func signIn(_ accounts: AccountManager) async throws -> ServerConnectionDTO {
        let model = model(accounts)
        model.address = "https://\(server.host)"
        await model.submitAddress()
        model.username = "david"
        await model.signIn()
        #expect(model.phase == .done)
        return try #require(accounts.activeConnection)
    }
}

/// The app's backend against a stub server: the custom headers reach `/status` and `/login`, are
/// saved with the connection, and a saved session is resumed.
@MainActor @Suite struct AccountConnectBackendTests {
    @Test func signsInWithCustomHeadersAndResumes() async throws {
        let fixture = try Fixture()
        let host = fixture.server.host
        let accounts = fixture.makeAccounts()
        let model = fixture.model(accounts)
        model.address = "https://\(host)"
        model.customHeaders = [CustomHeader(name: "X-Proxy", value: "secret")]
        await model.submitAddress()
        model.username = "david"
        model.password = "pw"
        await model.signIn()
        #expect(model.phase == .done)

        #expect(fixture.server.requestLines == ["https /status", "https /login"])
        #expect(fixture.server.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Proxy") == "secret" })
        let saved = try #require(accounts.activeConnection)
        #expect(try await accounts.customHeaders(for: saved.id) == ["X-Proxy": "secret"])

        let next = fixture.model(accounts)
        #expect(next.phase == .servers && next.savedServers.map(\.id) == [saved.id])
        await next.select(saved)
        #expect(next.phase == .done)
    }

    /// With custom headers, `http` is used only after the user confirms it.
    @Test func connectsWithoutEncryptionAfterConfirming() async throws {
        let fixture = try Fixture()
        let host = fixture.server.host
        fixture.server.update { $0.httpsFails = true }
        let accounts = fixture.makeAccounts()
        let model = fixture.model(accounts)
        model.address = host
        model.customHeaders = [CustomHeader(name: "X-Proxy", value: "secret")]
        await model.submitAddress()
        let fallback = try #require(ServerAddress("http://\(host)"))
        #expect(model.phase == .address && model.failure == .httpsUnavailable(fallback))
        #expect(fixture.server.requestLines == ["https /status"])

        await model.connectWithoutEncryption()
        #expect(model.phase == .login && model.address == fallback.description)
        #expect(model.showsPlainHTTPWarning)
        model.username = "david"
        await model.signIn()
        #expect(model.phase == .done)
        #expect(fixture.server.requestLines == ["https /status", "http /status", "http /login"])
        #expect(fixture.server.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Proxy") == "secret" })
        #expect(accounts.activeConnection?.address == fallback.description)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledSignInLeavesNoActiveAccount() async throws {
        let fixture = try Fixture()
        let accounts = fixture.makeAccounts()
        let model = fixture.model(accounts)
        model.address = "https://\(fixture.server.host)"
        await model.submitAddress()
        model.username = "david"
        let login = StubURLProtocol.hold(host: fixture.server.host, path: "/login")
        let signingIn = Task { await model.signIn() }
        await login.arrived()

        model.cancel()
        #expect(model.phase == .login)
        login.open()
        await signingIn.value
        #expect(model.phase == .login && model.failure == nil)
        #expect(accounts.activeConnection == nil)
    }

    @Test func resumeOfAnExpiredSessionAsksToSignIn() async throws {
        let fixture = try Fixture()
        let saved = try await fixture.signIn(fixture.makeAccounts())
        fixture.server.update { $0.authorizeStatus = 401 }
        let backend = AccountConnectBackend(accounts: fixture.makeAccounts(), validator: fixture.validator)
        #expect(try await backend.resume(saved.id) == false)
    }

    /// The session is kept and reconnects later.
    @Test func resumeOfAnOfflineServerCountsAsResumed() async throws {
        let fixture = try Fixture()
        let saved = try await fixture.signIn(fixture.makeAccounts())
        fixture.server.update { $0.authorizeFails = true }
        let accounts = fixture.makeAccounts()
        let backend = AccountConnectBackend(accounts: accounts, validator: fixture.validator)
        #expect(try await backend.resume(saved.id))
        #expect(accounts.state == .offline(AccountUser(saved)))
    }

    @Test func resumeOfAnUnsupportedServerThrows() async throws {
        let fixture = try Fixture()
        let saved = try await fixture.signIn(fixture.makeAccounts())
        fixture.server.update { $0.authorizeVersion = "2.0.0" }
        let backend = AccountConnectBackend(accounts: fixture.makeAccounts(), validator: fixture.validator)
        await #expect(throws: AccountError.server(.unsupportedVersion("2.0.0"))) {
            try await backend.resume(saved.id)
        }
    }

    @Test func resumeAfterSigningOutAsksToSignIn() async throws {
        let fixture = try Fixture()
        let accounts = fixture.makeAccounts()
        let saved = try await fixture.signIn(accounts)
        _ = await accounts.logout()
        let backend = AccountConnectBackend(accounts: accounts, validator: fixture.validator)
        #expect(try await backend.resume(saved.id) == false)
    }
}
