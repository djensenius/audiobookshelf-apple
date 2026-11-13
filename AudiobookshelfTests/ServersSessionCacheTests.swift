import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import Foundation
import Testing

@testable import Audiobookshelf

/// The servers list's session cache (``ServersView/sessions(of:)``, keyed on ``ServersView/SessionsKey``).
@MainActor @Suite struct ServersSessionCacheTests {
    private let keychain = ConnectTestKeychain()
    private let suiteName = "ServersSessionCacheTests.\(UUID().uuidString)"
    private let downloads = TestDownloads()

    private func signIn(_ accounts: AccountManager, to host: String) async throws -> UUID {
        let model = ConnectViewModel(
            accounts: accounts, validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            localNetwork: PreviewLocalNetworkAccess())
        model.addServer()
        model.address = "https://\(host)"
        await model.submitAddress()
        model.username = "reader"
        await model.signIn()
        try #require(model.phase == .done)
        return try #require(accounts.activeConnection).id
    }

    /// An inactive account's expiry leaves the connections as they were, yet its row reads again.
    @Test(.timeLimit(.minutes(1)))
    func anInactiveAccountsExpiryMarksItsRowLoggedOut() async throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let hosts = (0..<2).map { _ in "\(UUID().uuidString.lowercased()).connect-ui.test" }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            downloads.cleanUp()
            hosts.forEach(ConnectTestProtocol.forget)
        }
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: keychain,
            sessionConfiguration: ConnectTestProtocol.configuration, downloadsRoot: downloads.root,
            makeDownloadSession: downloads.makeSession)
        let accounts = try #require(environment.accounts)
        let a = try await signIn(accounts, to: hosts[0])
        let aClient = try #require(accounts.client)
        let b = try await signIn(accounts, to: hosts[1])
        let key = ServersView.SessionsKey(accounts)
        #expect(await ServersView.sessions(of: accounts) == [a: true, b: true])

        // A request A's client still had out expires A's session while B stays active.
        ConnectTestProtocol.revoke(hosts[0])
        await #expect(throws: APIError.sessionExpired) { try await aClient.send(AuthEndpoints.authorize()) }

        #expect(accounts.activeConnection?.id == b)
        #expect(accounts.connections == key.connections)
        #expect(ServersView.SessionsKey(accounts) != key)
        #expect(await ServersView.sessions(of: accounts) == [a: false, b: true])
    }
}
