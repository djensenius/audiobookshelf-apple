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
/// builds one per shell, so a sign-out or account switch drops it with the shell.
@MainActor
final class ConnectionBannerSession {
    /// Why a ping couldn't be sent.
    enum PingError: Error {
        /// The store has no `APIClient` for the account (offline without one).
        case noClient
    }

    let model: ConnectionBannerModel
    private let monitor: NetworkMonitor

    /// Pings `store`'s client while the store serves the account it serves now, and follows
    /// `monitor`'s paths (the device's, unless a test passes its own source).
    convenience init(store: LibraryStore, monitor: NetworkMonitor = NetworkMonitor()) {
        self.init(
            model: ConnectionBannerModel(
                paths: { monitor.paths() }, ping: Self.ping(store: store, account: store.connectionKey)),
            monitor: monitor)
    }

    init(model: ConnectionBannerModel, monitor: NetworkMonitor) {
        self.model = model
        self.monitor = monitor
    }

    /// Follows the network and checks the server until the calling task is cancelled.
    func run() async {
        monitor.start()
        await model.run()
        monitor.stop()
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
/// unavailable, and runs the banner's checks while the shell is on screen.
struct ConnectionBannerHost: ViewModifier {
    @Environment(\.connectionBanner) private var session

    func body(content: Content) -> some View {
        let status = session.flatMap { ConnectionBannerPresentation.status(for: $0.model.state) }
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let session, let status {
                    ConnectionBanner(status: status) { session.model.retry() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: status)
            .task(id: session.map(ObjectIdentifier.init)) {
                await session?.run()
            }
    }
}
