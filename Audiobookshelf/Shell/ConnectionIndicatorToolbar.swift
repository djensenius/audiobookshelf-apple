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

    /// The indicator's toolbar priority (#691). In compact width, connecting, offline and an unreachable server
    /// outrank the Library screen's filter and sort (`.high`, `LibraryToolbar`), so the crowded compact Library
    /// root keeps the problem in its bar and moves the sort into its overflow menu instead (and the filter too
    /// while the download queue indicator, which also outranks them, is there). Connected, over Wi-Fi or
    /// cellular, metered or not, is the usual state: it keeps the default priority, so the filter and sort stay
    /// and the Library root's overflow menu has the indicator, as before. Regular width (an iPad, a Mac) keeps
    /// the default too, so its layouts don't change.
    ///
    /// Rejected (#691): the leading edge took room from the trailing items, so the sort went into the overflow
    /// menu even while connected; hiding a plain connection drops legacy's top-bar indicator from every tab
    /// root without freeing room on the Library root, where it was already in the overflow menu; and sharing
    /// one item with the download queue indicator needs a custom combined control in place of two system ones.
    static func visibilityPriority(for state: ConnectionIndicatorState, isCompact: Bool)
        -> ToolbarItemVisibilityPriority
    {
        guard isCompact else { return .automatic }
        return switch state {
        case .connecting, .offline, .serverUnreachable: ToolbarItemVisibilityPriority(higherThan: .high)
        case .connected: .automatic
        }
    }
}

/// The shell's ``ConnectionIndicator`` (#59), in each tab root's toolbar, as legacy shows it in
/// its top bar: fed by the signed-in account, the network path, the realtime socket and the
/// shell's connection banner. Hidden signed out and without a socket. In compact width a problem
/// outranks the Library root's filter and sort, so it stays in the bar
/// (``ConnectionIndicatorPresentation/visibilityPriority(for:isCompact:)``, #691).
struct ConnectionIndicatorToolbar: ToolbarContent {
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(\.realtimeBridge) private var bridge
    @Environment(\.realtimeNetworkMonitor) private var monitor
    @Environment(\.connectionBanner) private var banner
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some ToolbarContent {
        if let state {
            ToolbarItem(placement: .primaryAction) {
                ConnectionIndicator(status: ConnectionIndicatorPresentation.status(for: state))
                    // For UI tests.
                    .accessibilityIdentifier("connection.indicator")
            }
            .visibilityPriority(
                ConnectionIndicatorPresentation.visibilityPriority(
                    for: state, isCompact: horizontalSizeClass == .compact))
        }
    }

    private var state: ConnectionIndicatorState? {
        let isSignedIn = accounts?.state.user != nil
        #if DEBUG
            // A fixture launch has no socket; UI tests force the state instead (#691).
            if let forced = FixtureServer.connectionState(arguments: ProcessInfo.processInfo.arguments) {
                return isSignedIn ? forced : nil
            }
        #endif
        return ConnectionIndicatorState(
            isSignedIn: isSignedIn, path: monitor?.path, socket: bridge?.connectionState, banner: banner?.model.state)
    }
}
