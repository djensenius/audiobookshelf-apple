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
            case "/status", "/abs/status":
                return .json(
                    #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local"]}"#)
            case "/login", "/abs/login":
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

private final class LocalNetworkDenied: LocalNetworkAccessChecking {
    let checked = Mutex<[String]>([])

    func isDenied(host: String, port: Int) async -> Bool {
        checked.withLock { $0.append("\(host):\(port)") }
        return true
    }
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
    @Test(arguments: [false, true])
    func normalizesAddressAndKeepsReverseProxySubpath(inferScheme: Bool) async throws {
        let fixture = try Fixture()
        let host = fixture.server.host
        let accounts = fixture.makeAccounts()
        let model = fixture.model(accounts)
        let scheme = inferScheme ? "" : "HTTPS://"
        model.address = " \n\(scheme)\(host.uppercased()):443/abs///?ignored=yes#fragment \n"
        await model.submitAddress()
        let normalized = "https://\(host)/abs"
        #expect(model.phase == .login && model.failure == nil)
        #expect(model.server?.address.description == normalized)

        model.username = "david"
        await model.signIn()
        #expect(model.phase == .done && model.failure == nil)
        #expect(accounts.activeConnection?.address == normalized)
        #expect(
            fixture.server.requests.compactMap { $0.url?.absoluteString } == [
                "\(normalized)/status", "\(normalized)/login",
            ])
    }

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

    /// The path can deny a named server too (split DNS). Custom headers must not turn a
    /// permission failure into an offer to retry them unencrypted.
    @Test(arguments: [nil, 13_378] as [Int?])
    func deniedLocalNetworkWithCustomHeadersKeepsHTTPSForRetry(port: Int?) async throws {
        let fixture = try Fixture()
        fixture.server.update { $0.httpsFails = true }
        let localNetwork = LocalNetworkDenied()
        let model = ConnectViewModel(
            accounts: fixture.makeAccounts(), validator: fixture.validator, localNetwork: localNetwork)
        let address = fixture.server.host + (port.map { ":\($0)" } ?? "")
        model.address = address
        model.customHeaders = [CustomHeader(name: "X-Proxy", value: "secret")]
        await model.submitAddress()
        #expect(model.phase == .address && model.failure == .localNetworkDenied)
        #expect(model.address == address)
        #expect(localNetwork.checked.withLock { $0 } == ["\(fixture.server.host):\(port ?? 443)"])
        #expect(fixture.server.requestLines == ["https /status"])

        await model.connectWithoutEncryption()
        #expect(model.phase == .address && model.failure == .localNetworkDenied)
        #expect(fixture.server.requestLines == ["https /status"])

        fixture.server.update { $0.httpsFails = false }
        await model.retry()
        #expect(model.phase == .login && model.failure == nil)
        #expect(model.server?.address.url.scheme == "https")
        #expect(fixture.server.requestLines == ["https /status", "https /status"])
        #expect(fixture.server.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Proxy") == "secret" })
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

    /// A later account call, here a restore, supersedes a sign-in that's still authenticating.
    @Test(.timeLimit(.minutes(1)))
    func supersededSignInReturnsToLoginSilently() async throws {
        let fixture = try Fixture()
        let accounts = fixture.makeAccounts()
        let model = fixture.model(accounts)
        model.address = "https://\(fixture.server.host)"
        await model.submitAddress()
        model.username = "david"
        let login = StubURLProtocol.hold(host: fixture.server.host, path: "/login")
        let signingIn = Task { await model.signIn() }
        await login.arrived()

        await accounts.restoreSession()
        login.open()
        await signingIn.value
        #expect(model.phase == .login && model.failure == nil)
        #expect(accounts.activeConnection == nil && accounts.connections.isEmpty)
    }

    /// After a relaunch, a logged-out server is listed as such and asks to log in again with its
    /// custom headers, even if deleting its session failed and the Keychain still holds it.
    @Test(arguments: [false, true])
    func loggedOutServerAsksToLogInAgain(deleteFails: Bool) async throws {
        let fixture = try Fixture()
        let accounts = fixture.makeAccounts()
        let signIn = fixture.model(accounts)
        signIn.address = "https://\(fixture.server.host)"
        signIn.customHeaders = [CustomHeader(name: "X-Proxy", value: "secret")]
        await signIn.submitAddress()
        signIn.username = "david"
        await signIn.signIn()
        let saved = try #require(accounts.activeConnection)
        if deleteFails { fixture.keychain.failWrites(with: errSecInteractionNotAllowed) }
        _ = await accounts.logout()
        let vault = CredentialVault(keychain: fixture.keychain)
        #expect(try (vault.session(for: saved.id) != nil) == deleteFails)

        let relaunched = fixture.makeAccounts()
        await relaunched.restoreSession()
        #expect(relaunched.activeConnection == nil)
        let model = fixture.model(relaunched)
        let listed = try #require(model.savedServers.first)
        #expect(listed.id == saved.id && listed.signedOutAt != nil)
        await model.select(listed)
        #expect(model.phase == .login && model.failure == nil && relaunched.activeConnection == nil)
        #expect(model.username == "david")
        #expect(model.customHeaders.map { "\($0.name)=\($0.value)" } == ["X-Proxy=secret"])
        #expect(try await relaunched.customHeaders(for: saved.id) == ["X-Proxy": "secret"])
        #expect(try (vault.session(for: saved.id) != nil) == deleteFails)
    }
}
