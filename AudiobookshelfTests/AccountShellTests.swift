import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import ABSUI
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
    /// Each opened end-session URL, with the gate when it was opened.
    var opened: [(url: URL, gate: AuthGate)] = []
    /// The root's links, as `RootView` keeps them.
    var links = SceneLinks()

    /// Hands a confirmed switch's link to ``links``, as `RootView` does.
    func reopener(_ lifecycle: SessionLifecycle) -> LinkReopener {
        LinkReopener(
            beginSwitch: { self.links.beginSwitch(with: $0) },
            finishSwitch: {
                self.links.finishSwitch(succeeded: $0, gate: lifecycle.gate, epoch: lifecycle.linkEpoch)
            })
    }

    /// A link reaching the root now.
    func receive(_ link: DeepLink, _ lifecycle: SessionLifecycle) {
        links.receive(link, gate: lifecycle.gate, epoch: lifecycle.linkEpoch)
    }

    /// The link the root hands the host now.
    func waitingLink(_ lifecycle: SessionLifecycle) -> DeepLink? {
        links.link(atEpoch: lifecycle.linkEpoch)
    }

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

    /// Signs in to `host` with a password, or through OpenID, in the connect flow; with a
    /// `lifecycle`, as the server list's flow does while signed in.
    private func signIn(
        _ accounts: AccountManager, to host: String, openID: Bool = false, lifecycle: SessionLifecycle? = nil
    ) async throws -> SessionIdentity {
        let model = connectModel(accounts, lifecycle: lifecycle)
        model.addServer()
        model.address = "https://\(host)"
        await model.submitAddress()
        if openID {
            await model.signInWithOpenID(
                using: WebAuthenticationSessionAuthenticator { _, _ in
                    URL(string: "audiobookshelf://oauth?code=test-code&state=test-state")!
                })
        } else {
            model.username = "reader"
            await model.signIn()
        }
        try #require(model.phase == .done)
        let saved = try #require(accounts.activeConnection)
        return SessionIdentity(connectionID: saved.id, userID: saved.userId)
    }

    private func connectModel(_ accounts: AccountManager, lifecycle: SessionLifecycle? = nil) -> ConnectViewModel {
        ConnectViewModel(
            accounts: accounts, validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            localNetwork: PreviewLocalNetworkAccess(), lifecycle: lifecycle)
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
        _ environment: AppEnvironment, recorder: Recorder, hostA: String = host()
    ) async throws -> (a: SessionIdentity, b: SessionIdentity, hosts: [String]) {
        let accounts = try #require(environment.accounts)
        environment.lifecycle.register(recorder, stage: .connect)
        await environment.lifecycle.start()
        let hosts = [hostA, Self.host()]
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: environment.lifecycle)
        let b = try await signIn(accounts, to: hosts[1])
        await waitFor(.ready(b, isOffline: false), in: environment.lifecycle)
        return (a, b, hosts)
    }

    /// Shows the router's pending link in `prompt`, as the dialog does, and returns its request.
    private func present(
        _ router: Router, _ confirmation: ServerSwitchConfirmation, in prompt: inout ServerSwitchPrompt
    ) async throws -> ServerSwitchRequest {
        let target = try #require(await confirmation.review(router))
        prompt.present(target.link, for: target.connection)
        return try #require(prompt.shown)
    }

    // MARK: Server ID

    @Test func theShownShellsConnectionIsTheServerID() {
        let identity = SessionIdentity(connectionID: UUID(), userID: "user")
        #expect(SceneContent(.ready(identity, isOffline: false)).serverID == identity.connectionID)
        #expect(SceneContent(.ready(identity, isOffline: true)).serverID == identity.connectionID)
        // The outgoing shell stays up during a switch, still showing its own server's covers.
        #expect(SceneContent(.switching(from: identity)).serverID == identity.connectionID)
        for gate: AuthGate in [.launching, .connect, .signingOut(from: identity)] {
            #expect(SceneContent(gate).serverID == nil, "\(gate)")
        }
    }

    // MARK: Account session adapter

    @Test func adapterReportsRestoringUntilTheServerAnswers() async throws {
        let environment = try makeEnvironment()
        let host = Self.host("hold-")
        // Released here too, so a failed expectation can't leave the restore waiting.
        defer {
            ConnectTestProtocol.release(host)
            cleanUp([host])
        }
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

        let lifecycle = environment.lifecycle
        try await #require(
            AccountActions(lifecycle: lifecycle).signOut { recorder.opened.append(($0, lifecycle.gate)) }
        )
        .value

        #expect(environment.lifecycle.gate == .connect)
        #expect(recorder.events == [.start(identity), .flush, .end(.signOut)])
        #expect(accounts.state == .signedOut)
        // A password session has no end-session page to open.
        #expect(recorder.opened.isEmpty)
    }

    @Test func signingOutOfOpenIDOpensTheEndSessionPageOnceSignedOut() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        await lifecycle.start()
        let host = Self.host("oidc-")
        defer { cleanUp([host]) }
        let identity = try await signIn(try #require(environment.accounts), to: host, openID: true)
        await waitFor(.ready(identity, isOffline: false), in: lifecycle)

        try await #require(
            AccountActions(lifecycle: lifecycle).signOut { recorder.opened.append(($0, lifecycle.gate)) }
        )
        .value

        #expect(recorder.opened.map(\.url) == [ConnectTestProtocol.endSessionURL])
        #expect(recorder.opened.map(\.gate) == [.connect])
    }

    /// While a switch runs, the old shell stays on screen, but nothing in it may start another
    /// account change, from this window or another.
    @Test func accountChangesAreRefusedWhileSwitching() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let held = Self.host("hold-")
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder, hostA: held)
        let added = Self.host()
        defer {
            ConnectTestProtocol.release(held)
            cleanUp(hosts + [added])
        }
        let accounts = try #require(environment.accounts)
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts)
        let router = Router(identity: b)
        let link = DeepLink(.downloads, serverID: a.connectionID.uuidString)
        router.open(link)
        var prompt = ServerSwitchPrompt()
        let request = try await present(router, confirmation, in: &prompt)
        // The add-server sheet, open in another window, has its server checked.
        let sheet = connectModel(accounts, lifecycle: lifecycle)
        sheet.startAddingServer()
        sheet.address = "https://\(added)"
        await sheet.submitAddress()
        sheet.username = "reader"
        // A's authorization is held, so the switch stays in progress.
        let switching = Task { try await lifecycle.switchAccount(to: a.connectionID) }
        await waitFor(.switching(from: b), in: lifecycle)
        let actions = AccountActions(lifecycle: lifecycle)

        #expect(actions.signOut { recorder.opened.append(($0, lifecycle.gate)) } == nil)
        #expect(actions.switchAccount(to: b.connectionID) == nil)
        #expect(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)) == nil)
        #expect(prompt.shown != nil)
        await sheet.signIn()
        #expect(sheet.phase == .login)
        #expect(accounts.connections.count == 2)

        ConnectTestProtocol.release(held)
        try await switching.value
        #expect(lifecycle.gate == .ready(a, isOffline: false))
        #expect(recorder.events.suffix(3) == [.flush, .end(.switch), .start(a)])
        #expect(recorder.opened.isEmpty && !recorder.links.isSwitching)
    }

    @Test func choosingAnotherServerSwitchesThroughTheLifecycle() async throws {
        let environment = try makeEnvironment()
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        #expect(recorder.events.last == .start(b))
        let before = recorder.events.count

        let switched = try await #require(
            AccountActions(lifecycle: environment.lifecycle).switchAccount(to: a.connectionID)
        ).value

        #expect(switched)
        #expect(environment.lifecycle.gate == .ready(a, isOffline: false))
        #expect(Array(recorder.events.dropFirst(before)) == [.flush, .end(.switch), .start(a)])
    }

    /// Two windows can both take the ready gate before either change starts; the changes after
    /// the first, chosen from the account it left, do nothing. Each checks at its turn in the
    /// lifecycle's queue, so running them in order is the same as queueing them together.
    @Test func changesChosenTogetherRunOnlyTheFirst() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        let before = recorder.events.count
        let actions = AccountActions(lifecycle: lifecycle)
        // What every window read from the gate when the user chose.
        let chosenFrom = try #require(lifecycle.gate.identity)

        #expect(await actions.switchAccount(to: a.connectionID, from: chosenFrom))
        await actions.signOut(from: chosenFrom) { recorder.opened.append(($0, lifecycle.gate)) }
        #expect(await !actions.switchAccount(to: b.connectionID, from: chosenFrom))

        #expect(lifecycle.gate == .ready(a, isOffline: false))
        #expect(Array(recorder.events.dropFirst(before)) == [.flush, .end(.switch), .start(a)])
        #expect(environment.accounts?.state.user != nil)
        #expect(recorder.opened.isEmpty)
    }

    /// The server can reject the saved session's server version (or the session) when switching
    /// to it, which signs out without an error.
    @Test func aSwitchThatEndsSignedOutFailsAndTheRootSaysSo() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder, hostA: Self.host("old-"))
        defer { cleanUp(hosts) }
        let accounts = try #require(environment.accounts)
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts)
        let router = Router(identity: b)
        let link = DeepLink(.downloads, serverID: a.connectionID.uuidString)
        router.open(link)
        var prompt = ServerSwitchPrompt()
        let request = try await present(router, confirmation, in: &prompt)
        // Signing in again can't fix this, so the root says so rather than "signed out".
        #expect(accounts.signedOutSwitchMessage == L10n.string("MessageSwitchServerSignedOut"))

        let task = try #require(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)))

        #expect(await !task.value)
        #expect(lifecycle.gate == .connect)
        #expect(recorder.events.suffix(2) == [.flush, .end(.switch)])
        #expect(recorder.waitingLink(lifecycle) == nil && !recorder.links.isSwitching)
        // The old shell is gone; the root shows the message for this count.
        #expect(lifecycle.signedOutSwitches == 1)
        #expect(accounts.signedOutSwitchMessage == ConnectFailure.unsupportedVersion("1.0.0").message)
        #expect(accounts.signedOutSwitchMessage != L10n.string("MessageSwitchServerSignedOut"))
    }

    /// Adding a server from the server list signs in as an account change: the session ends
    /// through the lifecycle, and the account signed in before keeps its session.
    @Test func addingAServerWhileSignedInKeepsTheOtherAccount() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let accounts = try #require(environment.accounts)
        let recorder = Recorder()
        lifecycle.register(recorder, stage: .connect)
        await lifecycle.start()
        let hosts = [Self.host(), Self.host()]
        defer { cleanUp(hosts) }
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: lifecycle)

        let b = try await signIn(accounts, to: hosts[1], lifecycle: lifecycle)

        #expect(lifecycle.gate == .ready(b, isOffline: false))
        #expect(recorder.events == [.start(a), .flush, .end(.switch), .start(b)])
        #expect(accounts.connections.first { $0.id == a.connectionID }?.signedOutAt == nil)
        #expect(try await #require(AccountActions(lifecycle: lifecycle).switchAccount(to: a.connectionID)).value)
        #expect(lifecycle.gate == .ready(a, isOffline: false))
    }

    /// In the add-server sheet, the active server is already signed in and a signed-out one
    /// needs the login step; neither ends the running session.
    @Test func resumingTheActiveOrASignedOutServerInTheSheetKeepsTheSession() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let accounts = try #require(environment.accounts)
        let recorder = Recorder()
        lifecycle.register(recorder, stage: .connect)
        await lifecycle.start()
        let hosts = [Self.host(), Self.host()]
        defer { cleanUp(hosts) }
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: lifecycle)
        await lifecycle.signOut()
        let b = try await signIn(accounts, to: hosts[1])
        await waitFor(.ready(b, isOffline: false), in: lifecycle)
        let before = recorder.events.count
        let active = try #require(accounts.connections.first { $0.id == b.connectionID })
        let signedOut = try #require(accounts.connections.first { $0.id == a.connectionID })

        let resuming = connectModel(accounts, lifecycle: lifecycle)
        await resuming.select(active)
        #expect(resuming.phase == .done)
        let signingIn = connectModel(accounts, lifecycle: lifecycle)
        await signingIn.select(signedOut)
        #expect(signingIn.phase == .login)

        #expect(recorder.events.count == before)
        #expect(lifecycle.gate == .ready(b, isOffline: false))
    }

    /// Pins today's behaviour: the account change starts before the server checks the password,
    /// so a wrong one ends the running session, which starts again. A follow-up signs in first.
    @Test func aWrongPasswordInTheSheetRestartsTheSession() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let accounts = try #require(environment.accounts)
        let recorder = Recorder()
        lifecycle.register(recorder, stage: .connect)
        await lifecycle.start()
        let hosts = [Self.host(), Self.host("bad-")]
        defer { cleanUp(hosts) }
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: lifecycle)
        let before = recorder.events.count

        let model = connectModel(accounts, lifecycle: lifecycle)
        model.startAddingServer()
        model.address = "https://\(hosts[1])"
        await model.submitAddress()
        model.username = "reader"
        await model.signIn()

        #expect(model.phase == .login && model.failure != nil)
        #expect(Array(recorder.events.dropFirst(before)) == [.flush, .end(.switch), .start(a)])
        #expect(lifecycle.gate == .ready(a, isOffline: false))
    }

    @Test func removingAnotherServerInTheSheetKeepsTheSession() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        let accounts = try #require(environment.accounts)
        let before = recorder.events.count

        await connectModel(accounts, lifecycle: lifecycle)
            .remove(try #require(accounts.connections.first { $0.id == a.connectionID }))

        #expect(!accounts.connections.contains { $0.id == a.connectionID })
        #expect(recorder.events.count == before)
        #expect(lifecycle.gate == .ready(b, isOffline: false))
    }

    /// An expiry deletes the session without setting `signedOutAt`; such a server can't be
    /// switched to, so nothing ends the running session to try.
    @Test func aServerWhoseSessionWasDeletedIsntSwitchedTo() async throws {
        let environment = try makeEnvironment()
        let (a, b, hosts) = try await twoServers(environment, recorder: Recorder())
        defer { cleanUp(hosts) }
        // A relaunch after A's session was deleted.
        keychain.deleteItems(of: a.connectionID)
        let accounts = try relaunchedAccounts(environment)
        let lifecycle = SessionLifecycle(source: AccountSessionAdapter(accounts: accounts))
        let recorder = Recorder()
        lifecycle.register(recorder, stage: .connect)
        await lifecycle.start()
        await waitFor(.ready(b, isOffline: false), in: lifecycle)
        #expect(accounts.connections.first { $0.id == a.connectionID }?.signedOutAt == nil)
        #expect(await !accounts.hasSession(a.connectionID))
        #expect(await accounts.hasSession(b.connectionID))

        let switched = try await #require(
            AccountActions(lifecycle: lifecycle, accounts: accounts).switchAccount(to: a.connectionID)
        ).value
        let router = Router(identity: b)
        router.open(DeepLink(.downloads, serverID: a.connectionID.uuidString))
        let target = await ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts).review(router)

        #expect(!switched)
        #expect(target == nil && router.pendingServerSwitch == nil)
        #expect(recorder.events == [.start(b)])
        #expect(lifecycle.gate == .ready(b, isOffline: false))
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
        var prompt = ServerSwitchPrompt()

        router.open(link)
        let request = try await present(router, confirmation, in: &prompt)
        #expect(router.pendingServerSwitch == nil)
        #expect(request.link == link && request.connection.id == a.connectionID)

        prompt.dismiss(request)
        #expect(prompt.shown == nil)
        #expect(lifecycle.gate == .ready(b, isOffline: false))

        // SwiftUI may dismiss the dialog, which cancels, before it runs the confirm action.
        let epochBefore = lifecycle.linkEpoch
        let task = try #require(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)))
        #expect(await task.value)

        #expect(lifecycle.gate == .ready(a, isOffline: false))
        #expect(recorder.events.suffix(3) == [.flush, .end(.switch), .start(a)])
        // Opened after the switch, so it waits for the new account's host, not the old one's.
        #expect(lifecycle.linkEpoch > epochBefore)
        let waiting = try #require(recorder.waitingLink(lifecycle))
        #expect(waiting == link)
        let next = Router(identity: a)
        next.open(waiting)
        #expect(next.pendingServerSwitch == nil)
        #expect(next[path: .library] == [.item(id: "li_1")])
        // Confirmed once only.
        #expect(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)) == nil)
    }

    /// A newer link replaces the one the dialog asked about; the dialog's actions for the old one,
    /// which SwiftUI may still run, do nothing.
    @Test func theDialogsActionsForAReplacedLinkDoNothing() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: environment.accounts)
        let router = Router(identity: b)
        let older = DeepLink(.downloads, serverID: a.connectionID.uuidString)
        let newer = DeepLink(.item(id: "li_2", episodeID: nil), serverID: a.connectionID.uuidString)
        var prompt = ServerSwitchPrompt()
        router.open(older)
        let replaced = try await present(router, confirmation, in: &prompt)
        router.open(newer)
        let request = try await present(router, confirmation, in: &prompt)
        let before = recorder.events.count

        prompt.dismiss(replaced)
        #expect(confirmation.confirm(replaced, prompt: &prompt, reopen: recorder.reopener(lifecycle)) == nil)

        #expect(prompt.shown?.link == newer)
        #expect(recorder.events.count == before && !recorder.links.isSwitching)
        #expect(lifecycle.gate == .ready(b, isOffline: false))
        let task = try #require(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)))
        #expect(await task.value)
        #expect(recorder.waitingLink(lifecycle) == newer)
    }

    /// A link that arrives once the switch is confirmed but before it has changed the gate is
    /// newer than the confirmed one, so it opens after the switch, for the new account.
    @Test func aLinkThatArrivesBeforeTheSwitchStartsOpensAfterIt() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder)
        defer { cleanUp(hosts) }
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: environment.accounts)
        let router = Router(identity: b)
        let newer = DeepLink(.item(id: "li_3", episodeID: nil), serverID: a.connectionID.uuidString)
        router.open(DeepLink(.downloads, serverID: a.connectionID.uuidString))
        var prompt = ServerSwitchPrompt()
        let request = try await present(router, confirmation, in: &prompt)

        let task = try #require(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)))
        #expect(lifecycle.gate == .ready(b, isOffline: false))
        recorder.receive(newer, lifecycle)

        #expect(await task.value)
        #expect(lifecycle.gate == .ready(a, isOffline: false))
        #expect(recorder.waitingLink(lifecycle) == newer)
    }

    @Test func aLinkThatArrivesDuringTheSwitchWinsOverTheConfirmedOne() async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let recorder = Recorder()
        let held = Self.host("hold-")
        let (a, b, hosts) = try await twoServers(environment, recorder: recorder, hostA: held)
        defer {
            ConnectTestProtocol.release(held)
            cleanUp(hosts)
        }
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: environment.accounts)
        let router = Router(identity: b)
        let newer = DeepLink(.item(id: "li_4", episodeID: nil), serverID: nil)
        router.open(DeepLink(.downloads, serverID: a.connectionID.uuidString))
        var prompt = ServerSwitchPrompt()
        let request = try await present(router, confirmation, in: &prompt)

        let task = try #require(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)))
        await waitFor(.switching(from: b), in: lifecycle)
        // A's authorization is held, so a newer link reaches the root while the switch runs.
        recorder.receive(newer, lifecycle)
        ConnectTestProtocol.release(held)

        #expect(await task.value)
        #expect(lifecycle.gate == .ready(a, isOffline: false))
        #expect(recorder.waitingLink(lifecycle) == newer)
    }

    /// A failed switch drops the link it was confirmed for, but not a newer one: that waits as if
    /// it had just arrived, in the account the switch stayed on.
    @Test(arguments: [false, true])
    func aFailedSwitchKeepsOnlyANewerLink(replaced: Bool) {
        let identity = SessionIdentity(connectionID: UUID(), userID: "b")
        let confirmed = DeepLink(.downloads, serverID: UUID().uuidString)
        let newer = DeepLink(.item(id: "li_5", episodeID: nil), serverID: nil)
        var links = SceneLinks()

        links.beginSwitch(with: confirmed)
        if replaced { links.receive(newer, gate: .switching(from: identity), epoch: 1) }
        links.finishSwitch(succeeded: false, gate: .ready(identity, isOffline: false), epoch: 2)

        #expect(!links.isSwitching)
        #expect(links.link(atEpoch: 2) == (replaced ? newer : nil))
    }

    /// Every newer link replaces the one the dialog asks about, wherever the router sends it:
    /// one for this server navigates, one for an unknown or signed-out server is dropped.
    @Test(arguments: ["current", "unknown", "signedOut"])
    func aNewerLinkOfAnyKindReplacesTheDialogsLink(kind: String) async throws {
        let environment = try makeEnvironment()
        let lifecycle = environment.lifecycle
        let accounts = try #require(environment.accounts)
        let recorder = Recorder()
        lifecycle.register(recorder, stage: .connect)
        await lifecycle.start()
        let hosts = [Self.host(), Self.host(), Self.host()]
        defer { cleanUp(hosts) }
        let signedOut = try await signIn(accounts, to: hosts[2])
        await waitFor(.ready(signedOut, isOffline: false), in: lifecycle)
        await lifecycle.signOut()
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: lifecycle)
        let b = try await signIn(accounts, to: hosts[1])
        await waitFor(.ready(b, isOffline: false), in: lifecycle)
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts)
        let router = Router(identity: b)
        var prompt = ServerSwitchPrompt()
        #expect(
            prompt.open(DeepLink(.downloads, serverID: a.connectionID.uuidString)) {
                router.open($0)
                return true
            })
        let request = try await present(router, confirmation, in: &prompt)
        let before = recorder.events.count
        let server =
            switch kind {
            case "current": b.connectionID.uuidString
            case "unknown": UUID().uuidString
            default: signedOut.connectionID.uuidString
            }

        #expect(
            prompt.open(DeepLink(.item(id: "li_6", episodeID: nil), serverID: server)) {
                router.open($0)
                return true
            })
        #expect(await confirmation.review(router) == nil)

        #expect(prompt.shown == nil)
        #expect(confirmation.confirm(request, prompt: &prompt, reopen: recorder.reopener(lifecycle)) == nil)
        #expect(recorder.events.count == before && !recorder.links.isSwitching)
        #expect(lifecycle.gate == .ready(b, isOffline: false))
        #expect(router[path: .library] == (kind == "current" ? [.item(id: "li_6")] : []))
    }

    @Test func aLinkForASignedOutServerIsDropped() async throws {
        let environment = try makeEnvironment()
        let accounts = try #require(environment.accounts)
        let lifecycle = environment.lifecycle
        await lifecycle.start()
        let hosts = [Self.host(), Self.host()]
        defer { cleanUp(hosts) }
        let a = try await signIn(accounts, to: hosts[0])
        await waitFor(.ready(a, isOffline: false), in: lifecycle)
        await lifecycle.signOut()
        let b = try await signIn(accounts, to: hosts[1])
        await waitFor(.ready(b, isOffline: false), in: lifecycle)
        #expect(accounts.connections.first { $0.id == a.connectionID }?.signedOutAt != nil)
        let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts)
        let router = Router(identity: b)
        let link = DeepLink(.downloads, serverID: a.connectionID.uuidString)
        router.open(link)
        #expect(router.pendingServerSwitch == link)

        let target = await confirmation.review(router)

        #expect(target == nil && router.pendingServerSwitch == nil)
        #expect(lifecycle.gate == .ready(b, isOffline: false))
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

        let target = await confirmation.review(router)

        #expect(target == nil && router.pendingServerSwitch == nil)
        #expect(environment.lifecycle.gate == .ready(identity, isOffline: false))
    }
}
