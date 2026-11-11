import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import Foundation
import Observation
import Testing

@testable import Audiobookshelf

/// Records what the lifecycle asks of a session participant, and what the shell reopens.
@MainActor
private final class Recorder: SessionParticipant {
    enum Event: Equatable {
        case start(SessionIdentity)
        case flush
        case end(SessionEndReason)
    }

    var events: [Event] = []
    /// Each reopened link, with the lifecycle's link epoch when it was reopened.
    var reopened: [(link: DeepLink, epoch: UInt64)] = []
    var opened: [URL] = []

    func sessionDidStart(_ context: SessionContext) async { events.append(.start(context.identity)) }
    func sessionWillEnd(_ reason: SessionEndReason) async { events.append(.end(reason)) }
    func flush() async { events.append(.flush) }
}

/// The Account tab, the server list and the deep-link server switch, against the real
/// accounts and lifecycle of an `AppEnvironment` with an in-memory store and Keychain.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountShellTests {
    private let keychain = ConnectTestKeychain()
    private let suiteName = "AccountShellTests.\(UUID().uuidString)"

    private func makeEnvironment() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: keychain,
            sessionConfiguration: ConnectTestProtocol.configuration)
    }

    private func cleanUp(_ hosts: [String]) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        hosts.forEach(ConnectTestProtocol.forget)
    }

    private static func host(_ prefix: String = "") -> String {
        "\(prefix)\(UUID().uuidString.lowercased()).connect-ui.test"
    }

    /// Signs in to `host` with a password, through the connect flow.
    private func signIn(_ accounts: AccountManager, to host: String) async throws -> SessionIdentity {
        let model = ConnectViewModel(
            accounts: accounts, validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            localNetwork: PreviewLocalNetworkAccess())
        model.addServer()
        model.address = "https://\(host)"
        await model.submitAddress()
        model.username = "reader"
        await model.signIn()
        try #require(model.phase == .done)
        let saved = try #require(accounts.activeConnection)
        return SessionIdentity(connectionID: saved.id, userID: saved.userId)
    }

    /// A relaunch: new accounts over the same store and Keychain.
    private func relaunchedAccounts(_ environment: AppEnvironment) throws -> AccountManager {
        let stack = try #require(environment.dataStack)
        return AccountManager(
            store: ServerConnectionStore(modelContainer: stack.container), keychain: keychain,
            validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            sessionConfiguration: ConnectTestProtocol.configuration)
    }

    private func waitFor(_ gate: AuthGate, in lifecycle: SessionLifecycle) async {
        for await current in Observations({ @MainActor in lifecycle.gate }) where current == gate { return }
    }

    /// Signed in to two servers, A then B; the lifecycle is ready for B.
    private func twoServers(
        _ environment: AppEnvironment, recorder: Recorder
    ) async throws -> (a: SessionIdentity, b: SessionIdentity, hosts: [String]) {
        let accounts = try #require(environment.accounts)
        environment.lifecycle.register(recorder, stage: .connect)
        await environment.lifecycle.start()
        let hosts = [Self.host(), Self.host()]
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: environment.lifecycle)
        let b = try await signIn(accounts, to: hosts[1])
        await waitFor(.ready(b, isOffline: false), in: environment.lifecycle)
        return (a, b, hosts)
    }

    // MARK: Account session adapter

    @Test func adapterReportsRestoringUntilTheServerAnswers() async throws {
        let environment = try makeEnvironment()
        let host = Self.host("hold-")
        defer { cleanUp([host]) }
        let identity = try await signIn(try #require(environment.accounts), to: host)
        let restored = try relaunchedAccounts(environment)
        let adapter = AccountSessionAdapter(accounts: restored)
        #expect(adapter.phase == .signedOut)

        let restore = Task { await restored.restoreSession() }
        for await phase in Observations({ @MainActor in adapter.phase }) where phase == .restoring { break }
        // The server hasn't answered `/api/authorize` yet, so it can't have moved on.
        #expect(adapter.phase == .restoring)

        ConnectTestProtocol.release(host)
        await restore.value
        #expect(adapter.phase == .active(identity, isOffline: false))
    }

    @Test func adapterReportsAnUnreachableServerAsOffline() async throws {
        let environment = try makeEnvironment()
        let host = Self.host("offline-")
        defer { cleanUp([host]) }
        let identity = try await signIn(try #require(environment.accounts), to: host)
        let restored = try relaunchedAccounts(environment)
        let adapter = AccountSessionAdapter(accounts: restored)

        await restored.restoreSession()

        #expect(adapter.phase == .active(identity, isOffline: true))
        #expect(adapter.client != nil && adapter.client === restored.client)
    }

    // MARK: Account tab and server list

    @Test func signingOutEndsTheSessionThroughTheLifecycle() async throws {
        let environment = try makeEnvironment()
        let accounts = try #require(environment.accounts)
        let recorder = Recorder()
        environment.lifecycle.register(recorder, stage: .connect)
        await environment.lifecycle.start()
        let host = Self.host()
        defer { cleanUp([host]) }
        let identity = try await signIn(accounts, to: host)
        await waitFor(.ready(identity, isOffline: false), in: environment.lifecycle)
        #expect(recorder.events == [.start(identity)])

        await AccountActions(lifecycle: environment.lifecycle).signOut { recorder.opened.append($0) }.value

        #expect(environment.lifecycle.gate == .connect)
        #expect(recorder.events == [.start(identity), .flush, .end(.signOut)])
        #expect(accounts.state == .signedOut)
        // A password session has no end-session page to open.
        #expect(recorder.opened.isEmpty)
    }

    @Test func choosingAnotherServerSwitchesThroughTheLifecycle() async throws {
        let environment = try makeEnvironment()
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        #expect(recorder.events.last == .start(b))
        let before = recorder.events.count

        let switched = await AccountActions(lifecycle: environment.lifecycle).switchAccount(to: a.connectionID).value

        #expect(switched)
        #expect(environment.lifecycle.gate == .ready(a, isOffline: false))
        #expect(Array(recorder.events.dropFirst(before)) == [.flush, .end(.switch), .start(a)])
    }

    // MARK: Server switch for a link

    @Test func aLinkForAnotherServerSwitchesOnlyOnceConfirmed() async throws {
        let environment = try makeEnvironment()
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        let lifecycle = environment.lifecycle
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: environment.accounts)
        let router = Router(identity: b)
        let link = DeepLink(.item(id: "li_1", episodeID: nil), serverID: a.connectionID.uuidString)

        router.open(link)
        confirmation.dropIfUnknown(router)
        #expect(router.pendingServerSwitch == link)
        #expect(confirmation.connection(for: link)?.id == a.connectionID)

        confirmation.cancel(router)
        #expect(router.pendingServerSwitch == nil)
        #expect(lifecycle.gate == .ready(b, isOffline: false))

        router.open(link)
        let epochBefore = lifecycle.linkEpoch
        let task = confirmation.confirm(link, in: router) { recorder.reopened.append(($0, lifecycle.linkEpoch)) }
        #expect(router.pendingServerSwitch == nil)
        await task?.value

        #expect(lifecycle.gate == .ready(a, isOffline: false))
        #expect(recorder.events.suffix(3) == [.flush, .end(.switch), .start(a)])
        // Reopened after the switch, so it waits for the new account's host, not the old one's.
        #expect(recorder.reopened.map(\.link) == [link])
        #expect(recorder.reopened.map(\.epoch) == [lifecycle.linkEpoch])
        #expect(lifecycle.linkEpoch > epochBefore)
        let pending = try #require(PendingLink(link, arrivingAt: lifecycle.gate, epoch: lifecycle.linkEpoch))
        let next = Router(identity: a)
        next.open(try #require(pending.link(atEpoch: lifecycle.linkEpoch)))
        #expect(next.pendingServerSwitch == nil)
        #expect(next[path: .library] == [.item(id: "li_1")])
    }

    @Test(arguments: [UUID().uuidString, "not-a-connection"])
    func aLinkForAServerThatIsntSavedIsDropped(serverID: String) async throws {
        let environment = try makeEnvironment()
        let accounts = try #require(environment.accounts)
        await environment.lifecycle.start()
        let host = Self.host()
        defer { cleanUp([host]) }
        let identity = try await signIn(accounts, to: host)
        await waitFor(.ready(identity, isOffline: false), in: environment.lifecycle)
        let confirmation = ServerSwitchConfirmation(lifecycle: environment.lifecycle, accounts: accounts)
        let router = Router(identity: identity)
        let link = DeepLink(.downloads, serverID: serverID)
        router.open(link)
        #expect(router.pendingServerSwitch == link)

        confirmation.dropIfUnknown(router)

        #expect(router.pendingServerSwitch == nil)
        #expect(confirmation.confirm(link, in: router) { Issue.record("Reopened \($0)") } == nil)
        #expect(environment.lifecycle.gate == .ready(identity, isOffline: false))
    }
}
