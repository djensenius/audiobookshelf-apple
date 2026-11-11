import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import Foundation
import Observation
import Synchronization
import Testing

@testable import Audiobookshelf

/// Never reads the app's Keychain, including when a hosted test constructs AppEnvironment.
final class ConnectTestKeychain: KeychainStoring {
    private let items = Mutex<[KeychainItem: Data]>([:])

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        items.withLock { $0[item] }
    }

    func add(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) -> Bool {
        items.withLock {
            guard $0[item] == nil else { return false }
            $0[item] = data
            return true
        }
    }

    func delete(_ item: KeychainItem) throws(KeychainError) {
        items.withLock { $0[item] = nil }
    }
}

/// Answers for `*.connect-ui.test` hosts. Host prefixes change some answers: `offline-` refuses
/// the authorization of a saved session (`/api/authorize`) like a proxy (403), `hold-` holds it
/// until ``release(_:)``, `old-` answers it with an unsupported server version, `bad-` refuses
/// every password (`/login`, 401), and `oidc-` returns an end-session `redirect_url` from `/logout`.
final class ConnectTestProtocol: URLProtocol {
    static let requests = Mutex<[String: [URLRequest]]>([:])
    private static let held = Mutex<(responses: [String: [HeldResponse]], released: Set<String>)>(([:], []))
    static let endSessionURL = URL(string: "https://idp.example.com/logout?state=test-state")!

    /// A held answer. URLSession expects the client calls on the run loop that started loading,
    /// so ``send()`` schedules them there.
    private struct HeldResponse: @unchecked Sendable {
        let request: ObjectIdentifier
        let runLoop: CFRunLoop
        let answer: () -> Void

        func send() {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, answer)
            CFRunLoopWakeUp(runLoop)
        }
    }

    /// Set once URLSession stops this load; a held answer then sends nothing.
    private let isStopped = Mutex(false)

    /// Answers the held requests to `host`, and from now on its requests at once.
    static func release(_ host: String) {
        let responses = held.withLock { state in
            state.released.insert(host)
            return state.responses.removeValue(forKey: host) ?? []
        }
        for response in responses { response.send() }
    }

    static func forget(_ host: String) {
        requests.withLock { $0[host] = nil }
        held.withLock { state in
            state.responses[host] = nil
            state.released.remove(host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".connect-ui.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        Self.requests.withLock { $0[host, default: []].append(request) }
        let json: String
        var status = 200
        var headers = ["Content-Type": "application/json"]
        switch url.path() {
        case "/api/authorize" where host.hasPrefix("offline-"):
            status = 403
            json = "{}"
        case "/api/authorize" where host.hasPrefix("old-"):
            json = """
                {"user":{"id":"user-1","username":"reader","type":"admin","token":null},
                "serverSettings":{"version":"1.0.0"}}
                """
        case "/login" where host.hasPrefix("bad-"):
            status = 401
            json = "{}"
        case "/logout" where host.hasPrefix("oidc-"):
            json = #"{"redirect_url":"\#(Self.endSessionURL.absoluteString)"}"#
        case "/status":
            json = #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local","openid"]}"#
        case "/auth/openid":
            status = 302
            headers["Location"] = "https://idp.example.com/authorize?state=test-state"
            json = ""
        case "/login", "/api/authorize", "/auth/openid/callback":
            json = """
                {"user":{"id":"user-1","username":"reader","type":"admin","token":null,
                "accessToken":"test-access","refreshToken":"test-refresh"},
                "serverSettings":{"version":"2.26.0"}}
                """
        default:
            json = "{}"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        let answer = { [self] in
            guard !isStopped.withLock({ $0 }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let holds = url.path() == "/api/authorize" && host.hasPrefix("hold-")
        let isHeld = Self.held.withLock { state in
            guard holds, !state.released.contains(host) else { return false }
            let held = HeldResponse(request: ObjectIdentifier(self), runLoop: CFRunLoopGetCurrent(), answer: answer)
            state.responses[host, default: []].append(held)
            return true
        }
        if !isHeld { answer() }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
        guard let host = request.url?.host() else { return }
        let id = ObjectIdentifier(self)
        Self.held.withLock { $0.responses[host]?.removeAll { $0.request == id } }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [ConnectTestProtocol.self]
        return configuration
    }
}

@MainActor @Suite struct ConnectIntegrationTests {
    /// The signed-out root and the sign-in flow share the exact AccountManager the gate observes.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func signInOpensTheShellAndSignOutReturnsToConnect(openID: Bool) async throws {
        let suiteName = "ConnectIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = ConnectTestKeychain()
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: keychain,
            sessionConfiguration: ConnectTestProtocol.configuration)
        let accounts = try #require(environment.accounts)
        await environment.lifecycle.start()
        #expect(environment.lifecycle.gate == .connect)
        let model = ConnectViewModel(
            accounts: accounts, validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            localNetwork: PreviewLocalNetworkAccess())
        let host = "\(UUID().uuidString.lowercased()).connect-ui.test"
        defer { ConnectTestProtocol.requests.withLock { $0[host] = nil } }
        model.address = "https://\(host)"
        await model.submitAddress()
        #expect(model.phase == .login)
        if openID {
            let browserCalls = Mutex(0)
            let browser = WebAuthenticationSessionAuthenticator { url, scheme in
                browserCalls.withLock { $0 += 1 }
                #expect(url.absoluteString == "https://idp.example.com/authorize?state=test-state")
                #expect(scheme == OIDCLoginService.callbackScheme)
                await MainActor.run { #expect(environment.lifecycle.gate == .connect) }
                return URL(string: "audiobookshelf://oauth?code=test-code&state=test-state")!
            }
            await model.signInWithOpenID(using: browser)
            #expect(browserCalls.withLock { $0 } == 1)
            let requests = ConnectTestProtocol.requests.withLock { $0[host] ?? [] }
            #expect(requests.compactMap(\.url?.path) == ["/status", "/auth/openid", "/auth/openid/callback"])
            #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        } else {
            model.username = "reader"
            await model.signIn()
        }
        #expect(model.failure == nil)
        #expect(model.phase == .done)
        let saved = try #require(accounts.activeConnection)
        #expect(saved.authMethod == (openID ? .openid : .local))
        let identity = SessionIdentity(connectionID: saved.id, userID: saved.userId)
        let adapter = AccountSessionAdapter(accounts: accounts)
        #expect(adapter.phase == .active(identity, isOffline: false))
        #expect(adapter.client === accounts.client)
        // Tests the real observation bridge, not an explicit reconcile call.
        for await gate in Observations({ @MainActor in environment.lifecycle.gate }) {
            if gate == .ready(identity, isOffline: false) { break }
        }

        // A relaunch restores the saved session from the same store and injected Keychain.
        let stack = try #require(environment.dataStack)
        let restored = AccountManager(
            store: ServerConnectionStore(modelContainer: stack.container), keychain: keychain,
            validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            sessionConfiguration: ConnectTestProtocol.configuration)
        let lifecycle = SessionLifecycle(source: AccountSessionAdapter(accounts: restored))
        await lifecycle.start()
        #expect(lifecycle.gate == .ready(identity, isOffline: false))

        await environment.lifecycle.signOut()
        #expect(environment.lifecycle.gate == .connect)
        #expect(adapter.phase == .signedOut && adapter.client == nil)
        #expect(ConnectViewModel(accounts: accounts).phase == .servers)
    }
}
