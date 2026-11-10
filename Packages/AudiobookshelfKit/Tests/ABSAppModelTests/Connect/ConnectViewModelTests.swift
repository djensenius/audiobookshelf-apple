import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel

/// Records calls and answers with the configured status or error.
@MainActor
private final class FakeBackend: ConnectBackend {
    var connections: [ServerConnectionDTO] = []
    var status = ServerStatus(app: "audiobookshelf", serverVersion: "2.26.0", isInit: true, authMethods: [.local])
    var validateError: (any Error)?
    var signInError: (any Error)?
    var resumed = false
    var savedHeaders: [UUID: [String: String]] = [:]
    /// When set, validation waits for a value.
    var validationGate: AsyncStream<Void>?
    private(set) var validated: [(address: String, headers: [String: String])] = []
    private(set) var passwordSignIns: [String] = []
    private(set) var openIDSignIns = 0
    private(set) var removed: [UUID] = []

    func validate(address: String, customHeaders: [String: String]) async throws -> ConnectServer {
        validated.append((address, customHeaders))
        if let validationGate { for await _ in validationGate { break } }
        if let validateError { throw validateError }
        guard let server = ServerAddress(address) else { throw ServerValidationError.invalidAddress }
        return ConnectServer(address: server, status: status)
    }

    func signIn(to server: ConnectServer, username: String, password: String) async throws {
        passwordSignIns.append("\(username):\(password)")
        if let signInError { throw signInError }
    }

    func signIn(openIDTo server: ConnectServer, authenticator: any WebAuthenticator) async throws {
        _ = try await authenticator.authenticate(server.address.url, callbackScheme: OIDCLoginService.callbackScheme)
        openIDSignIns += 1
    }

    func resume(_ id: UUID) async throws -> Bool { resumed }
    func customHeaders(for id: UUID) async throws -> [String: String] { savedHeaders[id] ?? [:] }

    func remove(_ id: UUID) async throws {
        removed.append(id)
        connections.removeAll { $0.id == id }
    }
}

private final class FakeLocalNetwork: LocalNetworkAccessChecking {
    let denied: Bool
    let checked = Mutex<[String]>([])

    init(denied: Bool) { self.denied = denied }

    func isDenied(host: String, port: Int) async -> Bool {
        checked.withLock { $0.append("\(host):\(port)") }
        return denied
    }
}

private struct FakeAuthenticator: WebAuthenticator {
    var error: (any Error)?

    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        if let error { throw error }
        return URL(filePath: "/")
    }
}

private func connection(username: String = "david", address: String = "https://abs.example.com") -> ServerConnectionDTO
{
    ServerConnectionDTO(
        id: UUID(), address: address, userId: "usr-1", username: username, authMethod: .local, createdAt: .now)
}

@MainActor @Suite struct ConnectViewModelTests {
    private let backend = FakeBackend()

    private func model(denied: Bool = false) -> (ConnectViewModel, FakeLocalNetwork) {
        let localNetwork = FakeLocalNetwork(denied: denied)
        return (ConnectViewModel(backend: backend, localNetwork: localNetwork), localNetwork)
    }

    /// Validates `address` and returns the model at ``ConnectViewModel/Phase/login``.
    private func loginModel(_ address: String = "https://abs.example.com") async -> ConnectViewModel {
        let (model, _) = model()
        model.address = address
        await model.submitAddress()
        return model
    }

    @Test(arguments: ["", "   ", "ftp://abs.example.com", "https://"])
    func invalidAddressFailsWithoutContactingTheServer(address: String) async {
        let (model, _) = model()
        #expect(model.phase == .address)
        model.address = address
        await model.submitAddress()
        #expect(model.phase == .address)
        #expect(model.failure == .invalidAddress)
        #expect(backend.validated.isEmpty)
    }

    @Test(arguments: [
        (ServerValidationError.notAudiobookshelf, ConnectFailure.notAudiobookshelf),
        (.unsupportedVersion("2.0.0"), .unsupportedVersion("2.0.0")), (.serverNotInitialized, .serverNotInitialized),
        (.untrustedCertificate, .untrustedCertificate),
        (.cannotConnect(.secureConnectionFailed), .secureConnectionFailed),
        (.cannotConnect(.appTransportSecurityRequiresSecureConnection), .insecureConnectionBlocked),
        (.redirectedToOtherHost("evil.example"), .redirectedToOtherHost("evil.example")),
        (.accessDenied(status: 403), .accessDenied(status: 403)), (.timedOut, .cannotConnect),
    ])
    func validationFailureReturnsToTheAddress(error: ServerValidationError, expected: ConnectFailure) async {
        backend.validateError = error
        let model = await loginModel()
        #expect(model.phase == .address)
        #expect(model.failure == expected)
        #expect(model.server == nil)
    }

    @Test func openIDOnlyServerHidesThePassword() async {
        backend.status.authMethods = [.openID]
        backend.status.authFormData = AuthFormData(authOpenIDButtonText: "Sign in with Authentik")
        let model = await loginModel()
        model.username = "david"
        #expect(model.phase == .login)
        #expect(!model.showsPasswordLogin && model.showsOpenIDLogin && !model.canSignIn)
        #expect(model.openIDButtonTitle == "Sign in with Authentik")
        await model.signIn()
        #expect(backend.passwordSignIns.isEmpty && model.phase == .login)
    }

    @Test func passwordAndOpenIDServerUsesTheDefaultButtonTitle() async {
        backend.status.authMethods = [.local, .openID]
        backend.status.authFormData = AuthFormData(authLoginCustomMessage: "<b>Hi</b>", authOpenIDButtonText: " ")
        let model = await loginModel()
        #expect(model.showsPasswordLogin && model.showsOpenIDLogin)
        #expect(model.openIDButtonTitle == nil)
        #expect(model.loginMessageHTML == "<b>Hi</b>")
    }

    @Test func passwordSignInSucceeds() async {
        let model = await loginModel()
        #expect(!model.canSignIn)
        model.username = "david"
        model.password = "secret"
        await model.signIn()
        #expect(backend.passwordSignIns == ["david:secret"])
        #expect(model.phase == .done && model.failure == nil && model.password.isEmpty)
    }

    @Test func passwordSignInFailureStaysOnLogin() async {
        backend.signInError = AccountError.server(.invalidCredentials)
        let model = await loginModel()
        model.username = "david"
        await model.signIn()
        #expect(model.phase == .login)
        #expect(model.failure == .invalidCredentials)
    }

    @Test func openIDSignInSucceeds() async {
        backend.status.authMethods = [.openID]
        let model = await loginModel()
        await model.signInWithOpenID(using: FakeAuthenticator())
        #expect(backend.openIDSignIns == 1 && model.phase == .done)
    }

    @Test(arguments: [OIDCLoginError.cancelled, CancellationError()] as [any Error])
    func cancelledOpenIDSignInReturnsToLoginWithoutAFailure(error: any Error) async {
        backend.status.authMethods = [.openID]
        let model = await loginModel()
        await model.signInWithOpenID(using: FakeAuthenticator(error: error))
        #expect(backend.openIDSignIns == 0)
        #expect(model.phase == .login && model.failure == nil)
    }

    @Test func customHeadersArePassedThrough() async {
        let (model, _) = model()
        model.address = "abs.example.com"
        model.customHeaders = [
            CustomHeader(name: " CF-Access-Client-Id ", value: " id "), CustomHeader(),
            CustomHeader(name: "X-Token", value: "old"), CustomHeader(name: "x-token", value: "new"),
        ]
        await model.submitAddress()
        #expect(backend.validated.map(\.headers) == [["CF-Access-Client-Id": "id", "x-token": "new"]])
        #expect(model.phase == .login)
    }

    @Test(arguments: [
        (CustomHeader(name: "authorization", value: "Bearer x"), ConnectFailure.reservedHeader(name: "authorization")),
        (CustomHeader(name: "X Token", value: "x"), .invalidCustomHeader),
        (CustomHeader(name: "", value: "x"), .invalidCustomHeader),
    ])
    func invalidCustomHeaderIsRejectedBeforeConnecting(header: CustomHeader, expected: ConnectFailure) async {
        let (model, _) = model()
        model.address = "abs.example.com"
        model.customHeaders = [header]
        #expect(header.problem == expected)
        await model.submitAddress()
        #expect(model.failure == expected && model.phase == .address && backend.validated.isEmpty)
    }

    @Test(arguments: [
        ("http://abs.example.com", true), ("http://203.0.113.5:13378/abs", true), ("https://abs.example.com", false),
        ("abs.example.com", false), ("http://192.168.1.20:13378", false), ("http://10.0.0.2", false),
        ("http://nas.local", false), ("http://nas:13378", false), ("http://localhost:3333", false),
    ])
    func plainHTTPWarningDependsOnTheHost(address: String, warns: Bool) async {
        let (model, _) = model()
        model.address = address
        #expect(model.showsPlainHTTPWarning == warns)
        await model.submitAddress()
        #expect(model.phase == .login)
        #expect(model.showsPlainHTTPWarning == warns)
    }

    @Test func deniedLocalNetworkOffersRecoveryAndRetries() async {
        backend.validateError = ServerValidationError.cannotConnect(.notConnectedToInternet)
        let (model, localNetwork) = model(denied: true)
        model.address = "http://192.168.1.20:13378"
        await model.submitAddress()
        #expect(model.phase == .address && model.failure == .localNetworkDenied)
        #expect(localNetwork.checked.withLock { $0 } == ["192.168.1.20:13378"])

        backend.validateError = nil
        await model.retry()
        #expect(model.phase == .login && model.failure == nil)
    }

    @Test(arguments: [("https://abs.example.com", false), ("http://localhost:3333", false), ("http://nas.local", true)])
    func unreachableServerWithLocalNetworkAllowedCannotConnect(address: String, checks: Bool) async {
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (model, localNetwork) = model(denied: false)
        model.address = address
        await model.submitAddress()
        #expect(model.failure == .cannotConnect)
        #expect(localNetwork.checked.withLock { $0.count } == (checks ? 1 : 0))
    }

    @Test func savedServerWithSessionIsResumed() async {
        let saved = connection()
        backend.connections = [saved]
        backend.savedHeaders[saved.id] = ["X-Proxy": "secret"]
        backend.resumed = true
        let (model, _) = model()
        #expect(model.phase == .servers)
        await model.select(saved)
        #expect(backend.validated.map(\.headers) == [["X-Proxy": "secret"]])
        #expect(model.phase == .done)
    }

    @Test func savedServerWithoutSessionAsksToSignIn() async {
        let saved = connection(username: "root")
        backend.connections = [saved]
        backend.savedHeaders[saved.id] = ["X-Proxy": "secret"]
        let (model, _) = model()
        await model.select(saved)
        #expect(model.phase == .login)
        #expect(model.username == "root" && model.address == saved.address && model.savedConnection == saved)
        #expect(model.customHeaders.map { "\($0.name)=\($0.value)" } == ["X-Proxy=secret"])
        model.goBack()
        #expect(model.phase == .servers)
    }

    @Test func unreachableSavedServerStaysOnTheList() async {
        let saved = connection()
        backend.connections = [saved]
        backend.validateError = ServerValidationError.notAudiobookshelf
        let (model, _) = model()
        await model.select(saved)
        #expect(model.phase == .servers && model.failure == .notAudiobookshelf)
    }

    @Test func removingTheLastServerShowsTheAddress() async {
        let saved = connection()
        backend.connections = [saved]
        let (model, _) = model()
        await model.remove(saved)
        #expect(backend.removed == [saved.id])
        #expect(model.phase == .address && !model.canGoBack)
    }

    @Test func goingBackDropsAValidationInProgress() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        backend.validationGate = gate
        let (model, _) = model()
        model.address = "abs.example.com"
        let task = Task { await model.submitAddress() }
        while backend.validated.isEmpty { await Task.yield() }
        #expect(model.phase == .validating && model.isBusy)
        model.goBack()
        open.yield()
        await task.value
        #expect(model.phase == .address && model.server == nil)
    }
}

/// The app's backend against a stub server: the custom headers reach `/status` and `/login`, are
/// saved with the connection, and a saved session is resumed.
@MainActor @Suite struct AccountConnectBackendTests {
    @Test func signsInWithCustomHeadersAndResumes() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path() {
            case "/status":
                .json(#"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local"]}"#)
            case "/login":
                .json(
                    #"{"user":{"id":"usr-1","username":"david","type":"admin","token":null,"#
                        + #""accessToken":"access","refreshToken":"refresh"},"#
                        + #""userDefaultLibraryId":"lib1","serverSettings":{"version":"2.26.0"}}"#)
            default:
                .json("{}", status: 404)
            }
        }
        let validator = ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
        let accounts = AccountManager(
            store: ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container),
            keychain: InMemoryKeychain(), validator: validator,
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
        let model = ConnectViewModel(
            accounts: accounts, validator: validator, localNetwork: FakeLocalNetwork(denied: false))
        model.address = "https://\(host)"
        model.customHeaders = [CustomHeader(name: "X-Proxy", value: "secret")]
        await model.submitAddress()
        model.username = "david"
        model.password = "pw"
        await model.signIn()
        #expect(model.phase == .done)

        let paths = StubURLProtocol.requests(host: host).map { $0.url?.path() ?? "" }
        #expect(paths == ["/status", "/login"])
        #expect(StubURLProtocol.requests(host: host).allSatisfy { $0.value(forHTTPHeaderField: "X-Proxy") == "secret" })
        let saved = try #require(accounts.activeConnection)
        #expect(try await accounts.customHeaders(for: saved.id) == ["X-Proxy": "secret"])

        let next = ConnectViewModel(
            accounts: accounts, validator: validator, localNetwork: FakeLocalNetwork(denied: false))
        #expect(next.phase == .servers && next.savedServers.map(\.id) == [saved.id])
        await next.select(saved)
        #expect(next.phase == .done)
    }
}
