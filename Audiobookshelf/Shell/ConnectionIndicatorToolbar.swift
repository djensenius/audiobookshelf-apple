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

    /// The indicator's toolbar priority (#691). In compact width, a problem (connecting, offline or an unreachable
    /// server) that has lasted (`problemPersisted`, ``ConnectionProblemDebounce``) outranks the Library screen's
    /// filter and sort (`.high`, `LibraryToolbar`). So in a horizontal bar the crowded compact Library root keeps
    /// the problem in view and moves the sort into its overflow menu instead (and the filter too while the
    /// download queue indicator, which also outranks them, is there). A brief problem, such as every session
    /// start, reconnect, token refresh and network change goes through, keeps the default, so the bar doesn't
    /// reflow for it; a connection drops back at once. Connected, over Wi-Fi or cellular, metered or not, is the
    /// usual state: it keeps the default priority, so the filter and sort stay and the Library root's overflow
    /// menu has the indicator, as before. Regular width keeps the default too, so its layouts don't change; a
    /// compact iPad window (Slide Over, a narrow Split View or Stage Manager window) behaves as an iPhone.
    ///
    /// Rejected (#691): the leading edge took room from the trailing items, so the sort went into the overflow
    /// menu even while connected; hiding a plain connection drops legacy's top-bar indicator from every tab
    /// root without freeing room on the Library root, where it was already in the overflow menu; and sharing
    /// one item with the download queue indicator needs a custom combined control in place of two system ones.
    static func visibilityPriority(for state: ConnectionIndicatorState, problemPersisted: Bool, isCompact: Bool)
        -> ToolbarItemVisibilityPriority
    {
        isCompact && state.isProblem && problemPersisted ? ToolbarItemVisibilityPriority(higherThan: .high) : .automatic
    }
}

extension EnvironmentValues {
    /// What the tab roots' connection indicator shows, from ``ConnectionIndicatorHost``, or `nil` to hide it.
    @Entry var connectionIndicator: ConnectionIndicatorHost.Indicator?
}

/// Works out what the shell's connection indicator shows, from the signed-in account, the network path, the
/// realtime socket and the shell's connection banner, and whether its problem has lasted
/// (``ConnectionProblemDebounce``, #691), for the tab roots' ``ConnectionIndicatorToolbar``. It's on the shell, not
/// the toolbar item, so it keeps timing while the item is in an overflow menu, out of the hierarchy.
struct ConnectionIndicatorHost: ViewModifier {
    /// The indicator's state, and whether its problem has lasted.
    struct Indicator: Equatable {
        let state: ConnectionIndicatorState
        let problemPersisted: Bool
    }

    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(\.realtimeBridge) private var bridge
    @Environment(\.realtimeNetworkMonitor) private var monitor
    @Environment(\.connectionBanner) private var banner
    @State private var debounce = ConnectionProblemDebounce()

    #if DEBUG
        /// A fixture launch has no socket; UI tests force the state instead (#691).
        private static let fixtureState = FixtureServer.connectionState(arguments: ProcessInfo.processInfo.arguments)
    #endif

    func body(content: Content) -> some View {
        let state = state
        content
            .onChange(of: state, initial: true) { _, state in debounce.update(state) }
            .environment(
                \.connectionIndicator, state.map { Indicator(state: $0, problemPersisted: debounce.hasPersisted) })
    }

    private var state: ConnectionIndicatorState? {
        let isSignedIn = accounts?.state.user != nil
        #if DEBUG
            if let forced = Self.fixtureState { return isSignedIn ? forced : nil }
        #endif
        return ConnectionIndicatorState(
            isSignedIn: isSignedIn, path: monitor?.path, socket: bridge?.connectionState, banner: banner?.model.state)
    }
}

/// The shell's ``ConnectionIndicator`` (#59), in each tab root's toolbar, as legacy shows it in
/// its top bar, showing ``ConnectionIndicatorHost``'s state. Hidden signed out and without a socket. In compact
/// width a lasting problem outranks the Library root's filter and sort, so it stays in the bar
/// (``ConnectionIndicatorPresentation/visibilityPriority(for:problemPersisted:isCompact:)``, #691).
struct ConnectionIndicatorToolbar: ToolbarContent {
    @Environment(\.connectionIndicator) private var indicator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some ToolbarContent {
        if let indicator {
            ToolbarItem(placement: .primaryAction) {
                ConnectionIndicator(status: ConnectionIndicatorPresentation.status(for: indicator.state))
                    // For UI tests.
                    .accessibilityIdentifier("connection.indicator")
            }
            .visibilityPriority(
                ConnectionIndicatorPresentation.visibilityPriority(
                    for: indicator.state, problemPersisted: indicator.problemPersisted,
                    isCompact: horizontalSizeClass == .compact))
        }
    }
}
