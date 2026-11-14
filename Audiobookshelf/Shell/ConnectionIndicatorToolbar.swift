import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The realtime socket (#59), or `nil` without it.
    @Entry var realtimeBridge: RealtimeBridge?
    /// The device's network path, as the realtime socket follows it, or `nil` without the socket.
    @Entry var realtimeNetworkMonitor: NetworkMonitor?
}

/// What the indicator shows for a ``ConnectionIndicatorState``.
enum ConnectionIndicatorPresentation {
    static func status(for state: ConnectionIndicatorState) -> ConnectionStatus {
        switch state {
        case .connecting: .connecting
        case .offline: .offline
        case .serverUnreachable: .serverUnreachable
        case .connected(let cellular, let metered): .connected(cellular: cellular, metered: metered)
        }
    }
}

/// The shell's ``ConnectionIndicator`` (#59), in each tab root's toolbar, as legacy shows it in
/// its top bar: fed by the signed-in account, the network path, the realtime socket and the
/// shell's connection banner. Hidden signed out and without a socket.
struct ConnectionIndicatorToolbar: ToolbarContent {
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(\.realtimeBridge) private var bridge
    @Environment(\.realtimeNetworkMonitor) private var monitor
    @Environment(\.connectionBanner) private var banner

    var body: some ToolbarContent {
        if let state = ConnectionIndicatorState(
            isSignedIn: accounts?.state.user != nil, path: monitor?.path, socket: bridge?.connectionState,
            banner: banner?.model.state)
        {
            ToolbarItem(placement: .primaryAction) {
                ConnectionIndicator(status: ConnectionIndicatorPresentation.status(for: state))
            }
        }
    }
}
