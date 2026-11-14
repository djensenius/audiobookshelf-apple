import ABSCore

/// What the shell's connection indicator shows (#59), after legacy `ConnectionIndicator.vue`.
/// The app maps it to ABSUI's `ConnectionStatus`.
public enum ConnectionIndicatorState: Sendable, Hashable {
    /// Opening the socket, or the session is still starting it.
    case connecting
    /// The device has no network connection.
    case offline
    /// The network is up but the socket lost the server, its token was rejected, or the server
    /// doesn't answer pings.
    case serverUnreachable
    /// The socket is connected. `metered` is an expensive or Low Data Mode path.
    case connected(cellular: Bool, metered: Bool)

    /// The indicator's state, or `nil` to hide it: signed out, or without a realtime socket.
    ///
    /// No network wins, then any sign the server is unreachable, then connecting, then connected.
    /// The connection banner's failed pings outrank a connecting socket: the socket stays
    /// connecting while it retries a server that's down, and mustn't pulse beside the banner's
    /// outage strip. They also outrank a connected socket, so the two never disagree.
    ///
    /// - Parameters:
    ///   - isSignedIn: whether an account is signed in, online or offline.
    ///   - path: the device's network path, or `nil` before one is known (assumed online).
    ///   - socket: the realtime bridge's state, or `nil` without a bridge.
    ///   - banner: the account shell's connection banner state, or `nil` without one.
    public init?(
        isSignedIn: Bool, path: NetworkPath?, socket: RealtimeConnectionState?, banner: ConnectionBannerState?
    ) {
        guard isSignedIn, let socket else { return nil }
        if path?.isOnline == false {
            self = .offline
            return
        }
        switch (socket, banner) {
        case (_, .offline?):
            self = .offline
        case (.disconnected, _), (.authFailed, _), (_, .serverUnreachable?):
            self = .serverUnreachable
        case (.idle, _), (.connecting, _):
            self = .connecting
        case (.connected, _):
            self = .connected(
                cellular: path?.interface == .cellular,
                metered: path.map { $0.isExpensive || $0.isConstrained } ?? false)
        }
    }
}
