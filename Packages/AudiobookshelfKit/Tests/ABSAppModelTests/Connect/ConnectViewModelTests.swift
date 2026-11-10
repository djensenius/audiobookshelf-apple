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
    /// Answers a schemeless address over `http`, as the validator does when `https` can't connect.
    var fallsBackToHTTP = false
    /// When set, validation waits for a value.
    var validationGate: AsyncStream<Void>?
    /// When set, resuming waits for a value.
    var resumeGate: AsyncStream<Void>?
    /// When set, both sign-ins wait for a value, or until cancelled.
    var signInGate: AsyncStream<Void>?
    private(set) var signInStarts = 0
    private(set) var resumeCalls = 0
    private(set) var validated: [(address: String, headers: [String: String])] = []
    private(set) var passwordSignIns: [String] = []
    private(set) var openIDSignIns = 0
    private(set) var removed: [UUID] = []

    func validate(address: String, customHeaders: [String: String]) async throws -> ConnectServer {
        validated.append((address, customHeaders))
        if let validationGate { for await _ in validationGate { break } }
        if let validateError { throw validateError }
        guard var server = ServerAddress(address) else { throw ServerValidationError.invalidAddress }
        if fallsBackToHTTP, server.isSchemeInferred, let fallback = ServerAddress("http://" + address) {
            server = fallback
        }
        return ConnectServer(address: server, status: status)
    }

    func signIn(to server: ConnectServer, username: String, password: String) async throws {
        signInStarts += 1
        if let signInGate { for await _ in signInGate { break } }
        passwordSignIns.append("\(username):\(password)")
        if let signInError { throw signInError }
    }

    func signIn(openIDTo server: ConnectServer, authenticator: any WebAuthenticator) async throws {
        signInStarts += 1
        if let signInGate { for await _ in signInGate { break } }
        _ = try await authenticator.authenticate(server.address.url, callbackScheme: OIDCLoginService.callbackScheme)
        openIDSignIns += 1
    }

    func resume(_ id: UUID) async throws -> Bool {
        resumeCalls += 1
        if let resumeGate { for await _ in resumeGate { break } }
        return resumed
    }
    func customHeaders(for id: UUID) async throws -> [String: String] { savedHeaders[id] ?? [:] }

    func remove(_ id: UUID) async throws {
        removed.append(id)
        connections.removeAll { $0.id == id }
    }
}

private final class FakeLocalNetwork: LocalNetworkAccessChecking {
    let denied: Bool
    /// When set, the check waits for a value.
    let gate: AsyncStream<Void>?
    let checked = Mutex<[String]>([])

    init(denied: Bool, gate: AsyncStream<Void>? = nil) {
        self.denied = denied
        self.gate = gate
    }

    func isDenied(host: String, port: Int) async -> Bool {
        checked.withLock { $0.append("\(host):\(port)") }
        if let gate { for await _ in gate { break } }
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

    private func model(denied: Bool = false, gate: AsyncStream<Void>? = nil) -> (ConnectViewModel, FakeLocalNetwork) {
        let localNetwork = FakeLocalNetwork(denied: denied, gate: gate)
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
        (CustomHeader(name: "AUTHORIZATION", value: "x"), .reservedHeader(name: "AUTHORIZATION")),
        (CustomHeader(name: " Cookie ", value: "a=b"), .reservedHeader(name: "Cookie")),
        (CustomHeader(name: "X Token", value: "x"), .invalidCustomHeader),
        (CustomHeader(name: "", value: "x"), .invalidCustomHeader),
        // Line breaks and control characters, in a value and in a name.
        (CustomHeader(name: "X-Token", value: "a\rb"), .invalidCustomHeader),
        (CustomHeader(name: "X-Token", value: "a\nb"), .invalidCustomHeader),
        (CustomHeader(name: "X-Token", value: "a\0b"), .invalidCustomHeader),
        (CustomHeader(name: "X-Token", value: "a\u{2028}b"), .invalidCustomHeader),
        (CustomHeader(name: "X-Token", value: "a\u{7F}b"), .invalidCustomHeader),
        (CustomHeader(name: "X\rToken", value: "x"), .invalidCustomHeader),
        (CustomHeader(name: "X\nToken", value: "x"), .invalidCustomHeader),
        (CustomHeader(name: "X\0Token", value: "x"), .invalidCustomHeader),
        (CustomHeader(name: "X\u{2028}Token", value: "x"), .invalidCustomHeader),
    ])
    func invalidCustomHeaderIsRejectedBeforeConnecting(header: CustomHeader, expected: ConnectFailure) async {
        let (model, _) = model()
        model.address = "abs.example.com"
        model.customHeaders = [header]
        #expect(header.problem == expected)
        await model.submitAddress()
        #expect(model.failure == expected && model.phase == .address && backend.validated.isEmpty)
    }

    @Test func tabInAValueIsAllowed() async {
        let (model, _) = model()
        model.address = "abs.example.com"
        model.customHeaders = [CustomHeader(name: "X-Token", value: "a\tb")]
        await model.submitAddress()
        #expect(backend.validated.map(\.headers) == [["X-Token": "a\tb"]])
    }

    /// The editor and ABSAPI's validator reject the same names.
    @Test(arguments: [
        "authorization", "cookie", "x-refresh-token", "connection", "host", "proxy-authorization",
        "proxy-authenticate", "www-authenticate", "transfer-encoding", "content-length", "te", "upgrade",
        "keep-alive",
    ])
    func reservedNamesMatchTheValidator(name: String) {
        #expect(APIClientConfiguration.reservedHeaderNames.contains(name))
        let header = CustomHeader(name: name.uppercased(), value: "x")
        #expect(header.problem == .reservedHeader(name: name.uppercased()))
        #expect(throws: CustomHeaderError.reserved(name: name.uppercased())) {
            try APIClientConfiguration.validate(customHeaders: [name.uppercased(): "x"])
        }
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

    /// A schemeless address isn't warned about until the server is found to answer only `http`.
    @Test(arguments: [
        ("abs.example.com", true), ("203.0.113.5:13378", true), ("nas.local", false), ("192.168.1.20", false),
    ])
    func plainHTTPWarningAfterFallingBackToHTTP(address: String, warns: Bool) async {
        backend.fallsBackToHTTP = true
        let (model, _) = model()
        model.address = address
        #expect(!model.showsPlainHTTPWarning)
        await model.submitAddress()
        #expect(model.server?.address.url.scheme == "http")
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

    /// Only loopback is skipped: names may resolve to a local address, and the path's reason
    /// decides for any other address.
    @Test(arguments: [
        ("https://abs.example.com", true), ("http://nas.lan", true), ("http://nas.local", true),
        ("http://192.168.1.20", true), ("http://localhost:3333", false), ("http://127.0.0.1", false),
        ("http://8.8.8.8", true), ("http://134744072", true),
    ])
    func unreachableServerWithLocalNetworkAllowedCannotConnect(address: String, checks: Bool) async {
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (model, localNetwork) = model(denied: false)
        model.address = address
        await model.submitAddress()
        #expect(model.failure == .cannotConnect)
        #expect(localNetwork.checked.withLock { $0.count } == (checks ? 1 : 0))
    }

    /// Split DNS: a public-looking name that resolves to a LAN address.
    @Test func deniedLocalNetworkIsFoundForANamedServer() async {
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (model, localNetwork) = model(denied: true)
        model.address = "abs.example.com"
        await model.submitAddress()
        #expect(model.failure == .localNetworkDenied)
        #expect(localNetwork.checked.withLock { $0 } == ["abs.example.com:443"])
    }

    @Test(.timeLimit(.minutes(1)))
    func goingBackDuringTheLocalNetworkCheckDropsItsResult() async {
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (model, localNetwork) = model(denied: true, gate: gate)
        model.address = "http://192.168.1.20:13378"
        let task = Task { await model.submitAddress() }
        while localNetwork.checked.withLock({ $0.isEmpty }) { await Task.yield() }
        #expect(model.phase == .validating)
        model.goBack()
        open.yield()
        await task.value
        #expect(model.phase == .address && model.failure == nil)
    }

    @Test func retryRepeatsASavedServerCheck() async {
        let saved = connection(address: "http://192.168.1.20:13378")
        backend.connections = [saved]
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (model, _) = model(denied: true)
        await model.select(saved)
        #expect(model.phase == .servers && model.failure == .localNetworkDenied)

        backend.validateError = nil
        backend.resumed = true
        await model.retry()
        #expect(model.phase == .done && backend.validated.count == 2)
    }

    @Test func retryDoesNothingAfterLeavingTheFailedStep() async {
        let saved = connection()
        backend.connections = [saved]
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (model, _) = model()
        await model.retry()
        #expect(backend.validated.isEmpty)
        await model.select(saved)
        model.addServer()
        await model.retry()
        #expect(model.phase == .address && backend.validated.count == 1)
    }

    /// The check starts before the first call suspends, so a second one in the same turn
    /// finds the flow busy.
    @Test func secondSubmitOrRetryInTheSameTurnIsIgnored() async {
        backend.validateError = ServerValidationError.cannotConnect(.cannotConnectToHost)
        let (model, _) = model(denied: true)
        model.address = "http://192.168.1.20:13378"
        let first = Task { await model.submitAddress() }
        let second = Task { await model.submitAddress() }
        await first.value
        await second.value
        #expect(backend.validated.count == 1 && model.failure == .localNetworkDenied)

        backend.validateError = nil
        let retry = Task { await model.retry() }
        let again = Task { await model.retry() }
        await retry.value
        await again.value
        #expect(backend.validated.count == 2 && model.phase == .login)
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

    @Test(.timeLimit(.minutes(1)))
    func goingBackDropsAValidationInProgress() async {
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

    @Test(.timeLimit(.minutes(1)))
    func savedServerCanBeLeftUntilItsSessionIsResumed() async {
        let saved = connection()
        backend.connections = [saved]
        let (validation, openValidation) = AsyncStream<Void>.makeStream()
        backend.validationGate = validation
        let (model, _) = model()
        let task = Task { await model.select(saved) }
        while backend.validated.isEmpty { await Task.yield() }
        #expect(model.phase == .signingIn(.savedSession) && model.canGoBack)
        model.goBack()
        #expect(model.phase == .servers && model.savedConnection == nil)
        openValidation.yield()
        await task.value
        #expect(model.phase == .servers && model.failure == nil && backend.resumeCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func resumingASavedSessionCantBeLeftButCancellingDropsIt() async {
        let saved = connection()
        backend.connections = [saved]
        backend.resumed = true
        let (resume, openResume) = AsyncStream<Void>.makeStream()
        backend.resumeGate = resume
        let (model, _) = model()
        let task = Task { await model.select(saved) }
        while backend.resumeCalls == 0 { await Task.yield() }
        #expect(model.isResumingSession && !model.canGoBack)
        model.goBack()
        #expect(model.phase == .signingIn(.savedSession))
        model.cancel()
        #expect(model.phase == .servers && !model.isResumingSession)
        openResume.yield()
        await task.value
        #expect(model.phase == .servers)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingValidationReturnsToTheAddress() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        backend.validationGate = gate
        let (model, _) = model()
        model.address = "abs.example.com"
        let task = Task { await model.submitAddress() }
        while backend.validated.isEmpty { await Task.yield() }
        model.cancel()
        #expect(model.phase == .address)
        open.yield()
        await task.value
        #expect(model.phase == .address && model.server == nil && model.failure == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellingASignInReturnsToLogin(openID: Bool) async {
        backend.status.authMethods = [.local, .openID]
        let model = await loginModel()
        model.username = "david"
        let (gate, open) = AsyncStream<Void>.makeStream()
        backend.signInGate = gate
        let task = Task {
            if openID {
                await model.signInWithOpenID(using: FakeAuthenticator())
            } else {
                await model.signIn()
            }
        }
        while backend.signInStarts == 0 { await Task.yield() }
        #expect(model.phase == .signingIn(openID ? .openID : .password))
        model.cancel()
        #expect(model.phase == .login && !model.isBusy)
        open.yield()
        await task.value
        #expect(model.phase == .login && model.failure == nil && model.server != nil)
    }
}
