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

private final class ConnectTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".connect-ui.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let json: String
        switch url.path() {
        case "/status":
            json = #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local"]}"#
        case "/login", "/api/authorize":
            json = """
                {"user":{"id":"user-1","username":"reader","type":"admin","token":null,
                "accessToken":"test-access","refreshToken":"test-refresh"},
                "serverSettings":{"version":"2.26.0"}}
                """
        default:
            json = "{}"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [ConnectTestProtocol.self]
        return configuration
    }
}

@MainActor @Suite struct ConnectIntegrationTests {
    /// The signed-out root and the sign-in flow share the exact AccountManager the gate observes.
    @Test(.timeLimit(.minutes(1)))
    func signInOpensTheShellAndSignOutReturnsToConnect() async throws {
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
        model.address = "https://\(UUID().uuidString.lowercased()).connect-ui.test"
        await model.submitAddress()
        #expect(model.phase == .login)
        model.username = "reader"
        await model.signIn()
        #expect(model.phase == .done)
        let saved = try #require(accounts.activeConnection)
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
