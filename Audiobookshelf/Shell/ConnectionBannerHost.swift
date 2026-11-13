import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The account shell's connection banner, or `nil` signed out.
    @Entry var connectionBanner: ConnectionBannerSession?
}

/// One account shell's connection banner (#76): a ``ConnectionBannerModel`` fed by its own
/// `NetworkMonitor` and pinging the server through the store's client. ``AccountShellValues``
/// builds one per shell, so a sign-out or account switch drops it with the shell. While it runs,
/// its ``ReconnectRestorer``, if any, restores the account's session when the banner comes back
/// online while the account is offline.
@MainActor
final class ConnectionBannerSession {
    /// Why a ping couldn't be sent.
    enum PingError: Error {
        /// The store has no `APIClient` for the account (offline without one).
        case noClient
    }

    let model: ConnectionBannerModel
    let reconnect: ReconnectRestorer?
    private let monitor: NetworkMonitor
    /// Bumped by each ``run()``, so only the latest run stops the monitor: a restarted task's new
    /// run reuses the monitor while the cancelled one is still unwinding. Readable by tests.
    private(set) var runGeneration: UInt64 = 0

    /// Pings `store`'s client while the store serves the account it serves now, and follows
    /// `monitor`'s paths (the device's, unless a test passes its own source).
    /// With `accounts` and `lifecycle`, it also restores the account's session when the banner
    /// comes back online while it's offline (``restoreEpoch(accounts:lifecycle:store:account:)``).
    convenience init(
        store: LibraryStore, monitor: NetworkMonitor = NetworkMonitor(), accounts: AccountManager? = nil,
        lifecycle: SessionLifecycle? = nil
    ) {
        let account = store.connectionKey
        let reconnect = accounts.flatMap { accounts in
            lifecycle.map { lifecycle in
                ReconnectRestorer(
                    epoch: Self.restoreEpoch(accounts: accounts, lifecycle: lifecycle, store: store, account: account),
                    restore: { [weak accounts] in await accounts?.restoreSession() })
            }
        }
        self.init(
            model: ConnectionBannerModel(paths: { monitor.paths() }, ping: Self.ping(store: store, account: account)),
            monitor: monitor, reconnect: reconnect)
    }

    init(model: ConnectionBannerModel, monitor: NetworkMonitor, reconnect: ReconnectRestorer? = nil) {
        self.model = model
        self.monitor = monitor
        self.reconnect = reconnect
    }

    /// Follows the network and checks the server until the calling task is cancelled. A run that
    /// ends after a newer one began leaves the monitor, and the restorer, to that one.
    func run() async {
        runGeneration &+= 1
        let generation = runGeneration
        monitor.start()
        if let reconnect {
            reconnect.observe(model.state)
            model.stateDidChange = { [weak reconnect] in reconnect?.observe($0) }
        }
        await model.run()
        guard generation == runGeneration else { return }
        monitor.stop()
        model.stateDidChange = nil
        reconnect?.cancel()
    }

    /// What a restore after reconnecting is for: the ready session and the link epoch, which
    /// moves at each sign-out or switch, even one that comes back to the same account.
    struct RestoreEpoch: Hashable {
        let session: ReadySession
        let linkEpoch: UInt64
    }

    /// The ``RestoreEpoch`` while `account` is offline and its session is ready on `store`;
    /// `nil` while signed in, restoring, switching, signing out or signed out, or once the store
    /// serves another account.
    static func restoreEpoch(
        accounts: AccountManager, lifecycle: SessionLifecycle, store: LibraryStore, account: LibraryConnectionKey?
    ) -> ReconnectRestorer.Epoch {
        { [weak accounts, weak lifecycle, weak store] in
            guard let accounts, let lifecycle, let store, case .offline(let user) = accounts.state,
                let session = lifecycle.readySession, lifecycle.gate == .ready(session.identity, isOffline: true),
                user.connectionID == session.identity.connectionID, user.userId == session.identity.userID,
                let account, store.connectionKey == account, store.serves(session.identity)
            else { return nil }
            return RestoreEpoch(session: session, linkEpoch: lifecycle.linkEpoch)
        }
    }

    /// `GET /ping` through the store's current client, so a reconnect's new client is used. Once
    /// the store serves another account the ping is cancelled, which the banner ignores.
    static func ping(store: LibraryStore, account: LibraryConnectionKey?) -> ConnectionBannerModel.Ping {
        { [weak store] in
            let client = try await MainActor.run { () throws -> APIClient in
                guard let store, store.connectionKey == account else { throw CancellationError() }
                guard let client = store.client as? APIClient else { throw PingError.noClient }
                return client
            }
            _ = try await client.send(AuthEndpoints.ping())
        }
    }
}

/// What the banner shows for a connection state; `nil` online, which hides it.
enum ConnectionBannerPresentation {
    static func status(for state: ConnectionBannerState) -> ConnectionBannerStatus? {
        switch state {
        case .online: nil
        case .offline: .offline
        case .serverUnreachable(retryAt: nil): .checking
        case .serverUnreachable(let retryAt?): .serverUnreachable(retryAt: retryAt)
        }
    }
}

/// Shows the shell's ``ConnectionBanner`` above its content while the network or the server is
/// unavailable, and runs the banner's checks while the shell is on screen. With Reduce Motion
/// on, the banner appears and goes without sliding or resizing the shell.
struct ConnectionBannerHost: ViewModifier {
    @Environment(\.connectionBanner) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let status = session.flatMap { ConnectionBannerPresentation.status(for: $0.model.state) }
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let session, let status {
                    ConnectionBanner(status: status) { session.model.retry() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .default, value: status)
            .task(id: session.map(ObjectIdentifier.init)) {
                await session?.run()
            }
    }
}
