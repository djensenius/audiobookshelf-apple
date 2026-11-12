import SwiftUI

/// What the server connection indicator shows. The caller derives it from network and
/// socket state, so this view doesn't depend on the networking modules.
public enum ConnectionStatus: Hashable, Sendable {
    /// Connecting to the server.
    case connecting
    /// The device has no network connection.
    case offline
    /// The network is up but the server's socket isn't connected.
    case serverUnreachable
    /// Connected to the server.
    case connected(cellular: Bool, metered: Bool)

    /// The SF Symbol for this status.
    public var systemImage: String {
        switch self {
        case .connecting: "arrow.clockwise.icloud"
        case .offline: "wifi.slash"
        case .serverUnreachable: "icloud.slash"
        case .connected(cellular: true, _): "antenna.radiowaves.left.and.right"
        case .connected(cellular: false, _): "checkmark.icloud"
        }
    }

    /// The String Catalog key of the status message (the legacy alert text).
    var messageKey: String {
        switch self {
        case .connecting: "MessageAttemptingServerConnection"
        case .offline: "MessageNoNetworkConnection"
        case .serverUnreachable: "MessageSocketNotConnected"
        case .connected(cellular: true, metered: true): "MessageSocketConnectedOverMeteredCellular"
        case .connected(cellular: true, metered: false): "MessageSocketConnectedOverUnmeteredCellular"
        case .connected(cellular: false, metered: true): "MessageSocketConnectedOverMeteredWifi"
        case .connected(cellular: false, metered: false): "MessageSocketConnectedOverUnmeteredWifi"
        }
    }

    /// The localized status message.
    public var message: String { L10n.string(messageKey) }

    /// Whether the icon pulses: while connecting, unless Reduce Motion is on.
    func pulses(reduceMotion: Bool) -> Bool {
        self == .connecting && !reduceMotion
    }

    /// The icon's tint, following legacy's colours.
    public var tint: AnyShapeStyle {
        switch self {
        case .connecting: AnyShapeStyle(ABSColor.mutedForeground)
        case .offline: AnyShapeStyle(ABSColor.error)
        case .serverUnreachable: AnyShapeStyle(ABSColor.warning)
        case .connected(_, metered: true): AnyShapeStyle(ABSColor.progress)
        case .connected(cellular: true, metered: false): AnyShapeStyle(ABSColor.mutedForeground)
        case .connected(cellular: false, metered: false): AnyShapeStyle(ABSColor.success)
        }
    }
}

/// A small icon showing the server connection status. Tapping it shows the status message
/// in an alert, like legacy; the message is also its accessibility value and Mac tooltip.
public struct ConnectionIndicator: View {
    private let status: ConnectionStatus
    @State private var isShowingMessage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: ConnectionStatus) {
        self.status = status
    }

    public var body: some View {
        Button {
            isShowingMessage = true
        } label: {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.tint)
                .symbolEffect(.pulse, isActive: status.pulses(reduceMotion: reduceMotion))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: L10n.string("HeaderConnectionStatus")))
        .accessibilityValue(Text(verbatim: status.message))
        .help(Text(verbatim: status.message))
        .alert(Text(verbatim: L10n.string("HeaderConnectionStatus")), isPresented: $isShowingMessage) {
        } message: {
            Text(verbatim: status.message)
        }
    }
}
