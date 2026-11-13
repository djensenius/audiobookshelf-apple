import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// A client that serves no libraries, and isn't an `APIClient`.
private struct NoLibraries: LibraryService {
    struct Failure: Error {}
    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
        throw Failure()
    }
}

/// `/ping` is unauthenticated; the client still asks.
private struct NoTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

/// Reports one path and stays open.
private struct OnePath: NetworkPathSource {
    let path: NetworkPath
    func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { $0.yield(path) }
    }
}

private let account = LibraryConnectionKey(connectionID: UUID(), userID: "user-1")

/// How many times a ``ReconnectRestorer`` restored, or a ping recovered.
@MainActor
private final class Restores {
    var count = 0
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectionBannerHostTests {
    private let keychain = ConnectTestKeychain()
    private let downloads = TestDownloads()
    /// A store serving `account` through `client`, with settings in a throwaway defaults suite.
    private func withStore(client: any LibraryService, _ body: (LibraryStore) async throws -> Void) async throws {
        let suiteName = "ConnectionBannerHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        store.attach(client: client, connectionKey: account)
        try await body(store)
    }

    private func fixtureClient() throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: FixtureServer.address))),
            tokenProvider: NoTokens(), sessionConfiguration: FixtureServer.sessionConfiguration())
    }

    /// Runs `session` until its banner shows a status that satisfies `expected`, and returns whether it did.
    private func runs(
        _ session: ConnectionBannerSession, until expected: (ConnectionBannerStatus?) -> Bool
    ) async throws -> Bool {
        let task = Task { await session.run() }
        defer { task.cancel() }
        for _ in 0..<500 {
            if expected(ConnectionBannerPresentation.status(for: session.model.state)) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func statesMapToBannerStatuses() {
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(ConnectionBannerPresentation.status(for: .online) == nil)
        #expect(ConnectionBannerPresentation.status(for: .offline(.noNetwork)) == .offline)
        #expect(ConnectionBannerPresentation.status(for: .serverUnreachable(retryAt: nil)) == .checking)
        #expect(
            ConnectionBannerPresentation.status(for: .serverUnreachable(retryAt: date))
                == .serverUnreachable(retryAt: date))
    }

    /// The ping goes through the store's `APIClient`: the fixture server answers, so it stays hidden.
    @Test func pingsThroughTheStoresClient() async throws {
        try await withStore(client: try fixtureClient()) { store in
            try await ConnectionBannerSession.ping(store: store, account: account)()
        }
    }

    /// Without an `APIClient` the ping fails; once the store serves another account it's cancelled,
    /// which the banner ignores.
    @Test func pingFailsWithoutAClientAndCancelsForAnotherAccount() async throws {
        try await withStore(client: NoLibraries()) { store in
            await #expect(throws: ConnectionBannerSession.PingError.self) {
                try await ConnectionBannerSession.ping(store: store, account: account)()
            }
            let other = LibraryConnectionKey(connectionID: UUID(), userID: "user-2")
            await #expect(throws: CancellationError.self) {
                try await ConnectionBannerSession.ping(store: store, account: other)()
            }
        }
    }

    /// Without a client, as offline after a locked Keychain, the ping first recovers the account:
    /// once that gives the store a client, the ping goes through it (control: a recovery that
    /// gives none still fails, so the banner keeps retrying).
    @Test(arguments: [true, false])
    func pingRecoversAMissingClient(recovers: Bool) async throws {
        let client = try fixtureClient()
        try await withStore(client: NoLibraries()) { store in
            let recoveries = Restores()
            let ping = ConnectionBannerSession.ping(store: store, account: account) {
                recoveries.count += 1
                if recovers { store.attach(client: client, connectionKey: account) }
            }
            if recovers {
                try await ping()
            } else {
                await #expect(throws: ConnectionBannerSession.PingError.self) { try await ping() }
            }
            #expect(recoveries.count == 1)

            // With a client, the ping doesn't recover.
            if recovers {
                try await ping()
                #expect(recoveries.count == 1)
            }
        }
    }

    /// The shell's session follows its monitor and pings the store: no network shows offline; a
    /// network without a usable client shows the server as unreachable, with Retry.
    @Test func sessionFollowsTheNetworkAndThePing() async throws {
        try await withStore(client: NoLibraries()) { store in
            let offline = ConnectionBannerSession(
                store: store,
                monitor: NetworkMonitor(source: OnePath(path: NetworkPath(isOnline: false, interface: nil))))
            let showedOffline = try await runs(offline) { $0 == .offline }
            #expect(showedOffline)

            let online = ConnectionBannerSession(
                store: store,
                monitor: NetworkMonitor(source: OnePath(path: NetworkPath(isOnline: true, interface: .wifi))))
            let showedUnreachable = try await runs(online) { $0?.offersRetry == true }
            #expect(showedUnreachable)
        }
    }

    /// A restarted shell task's new run reuses the monitor while the cancelled run unwinds: the
    /// old run's end leaves it running, and only the latest run's end stops it.
    @Test func anOutgoingRunLeavesTheMonitorToTheNewOne() async throws {
        try await withStore(client: NoLibraries()) { store in
            let monitor = NetworkMonitor(source: OnePath(path: NetworkPath(isOnline: true, interface: .wifi)))
            let session = ConnectionBannerSession(store: store, monitor: monitor)
            let outgoing = Task { await session.run() }
            while session.runGeneration < 1 { await Task.yield() }
            let incoming = Task { await session.run() }
            while session.runGeneration < 2 { await Task.yield() }
            #expect(monitor.isRunning)

            outgoing.cancel()
            await outgoing.value
            #expect(monitor.isRunning)

            incoming.cancel()
            await incoming.value
            #expect(!monitor.isRunning)
        }
    }

    /// Polls `condition` until it holds, and returns whether it did.
    private func until(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// While it runs, the session hands its banner's states to its restorer: coming back online
    /// restores the account once when the restorer may (control: never when it may not), and the
    /// run's end stops following the banner.
    @Test(arguments: [true, false])
    func runningSessionRestoresWhenTheBannerComesBackOnline(mayRestore: Bool) async throws {
        let (paths, send) = AsyncStream<NetworkPath>.makeStream()
        let restores = Restores()
        let model = ConnectionBannerModel(paths: { paths }, ping: {})
        let session = ConnectionBannerSession(
            model: model, monitor: NetworkMonitor(source: OnePath(path: .wifi)),
            reconnect: ReconnectRestorer(
                debounce: .zero, epoch: { mayRestore ? AnyHashable(account) : nil },
                restore: { _ in restores.count += 1 }))
        let run = Task { await session.run() }
        #expect(try await until { model.stateDidChange != nil })

        send.yield(.offline)
        #expect(try await until { model.state == .offline(.noNetwork) })
        send.yield(.wifi)
        #expect(try await until { model.state == .online })
        if mayRestore {
            #expect(try await until { restores.count == 1 })
        } else {
            #expect(restores.count == 0)
        }

        run.cancel()
        await run.value
        #expect(model.stateDidChange == nil)
    }

    /// A restore is only for the offline account whose ready session the store serves: none while
    /// it's signed in (control: one once a relaunch finds its server unreachable), none once the
    /// store serves another account, and none after sign-out.
    @Test func restoreEpochFollowsTheOfflineSession() async throws {
        let suiteName = "ConnectionBannerHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let online = "\(UUID().uuidString.lowercased()).connect-ui.test"
        let host = "offline-\(UUID().uuidString.lowercased()).connect-ui.test"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            downloads.cleanUp()
            [online, host].forEach(ConnectTestProtocol.forget)
        }
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: keychain,
            sessionConfiguration: ConnectTestProtocol.configuration, downloadsRoot: downloads.root,
            makeDownloadSession: downloads.makeSession)
        let accounts = try #require(environment.accounts)
        let validator = ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration)
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        /// Signs in to `host` in the connect flow and points the store at it.
        func signIn(to host: String) async throws -> LibraryConnectionKey {
            let connect = ConnectViewModel(
                accounts: accounts, validator: validator, localNetwork: PreviewLocalNetworkAccess(), lifecycle: nil)
            connect.addServer()
            connect.address = "https://\(host)"
            await connect.submitAddress()
            connect.username = "reader"
            await connect.signIn()
            try #require(connect.phase == .done)
            let saved = try #require(accounts.activeConnection)
            let key = LibraryConnectionKey(connectionID: saved.id, userID: saved.userId)
            store.attach(client: try #require(accounts.client), connectionKey: key)
            return key
        }

        let signedInKey = try await signIn(to: online)
        let signedIn = SessionLifecycle(source: AccountSessionAdapter(accounts: accounts))
        await signedIn.start()
        #expect(signedIn.readySession != nil)
        #expect(
            ConnectionBannerSession.restoreEpoch(
                accounts: accounts, lifecycle: signedIn, store: store, account: signedInKey)() == nil)

        let key = try await signIn(to: host)
        let stack = try #require(environment.dataStack)
        let relaunched = AccountManager(
            store: ServerConnectionStore(modelContainer: stack.container), keychain: keychain,
            validator: validator, sessionConfiguration: ConnectTestProtocol.configuration)
        let lifecycle = SessionLifecycle(source: AccountSessionAdapter(accounts: relaunched))
        await relaunched.restoreSession()
        await lifecycle.start()
        let epoch = ConnectionBannerSession.restoreEpoch(
            accounts: relaunched, lifecycle: lifecycle, store: store, account: key)
        let current = try #require(epoch())

        store.attach(client: NoLibraries(), connectionKey: LibraryConnectionKey(connectionID: UUID(), userID: "user-2"))
        #expect(epoch() == nil)
        store.attach(client: try #require(relaunched.client), connectionKey: key)
        #expect(epoch() == current)

        _ = await relaunched.logout()
        #expect(epoch() == nil)
    }

    /// The signed-in shell gives its screens its banner session; signed out there is none.
    @Test func shellInjectsItsBannerSession() async throws {
        try await withStore(client: NoLibraries()) { store in
            let seen = SeenSession()
            render(AccountShell(store: store) { BannerProbe(seen: seen) })
            #expect(seen.session != nil)

            let signedOut = SeenSession()
            render(AccountShell(store: nil) { BannerProbe(seen: signedOut) })
            #expect(signedOut.session == nil)
        }
    }
}

/// What ``BannerProbe`` read from its environment.
@MainActor
private final class SeenSession {
    var session: ConnectionBannerSession?
}

/// Stands in for a screen in the shell and records the banner session it reads.
private struct BannerProbe: View {
    let seen: SeenSession
    @Environment(\.connectionBanner) private var session

    var body: some View {
        let _ = record()
        Color.clear
    }

    private func record() { seen.session = session }
}

/// Renders `view` once, so its body reads the environment.
@MainActor
private func render(_ view: some View) {
    #if canImport(AppKit)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
    #else
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.view.layoutIfNeeded()
    #endif
}
