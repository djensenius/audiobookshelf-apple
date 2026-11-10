import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension ConnectFailure {
    /// The localized message for the connect screen.
    var message: String {
        let minimum = ServerFeatures.minimumSupported.description
        return switch self {
        case .invalidAddress: L10n.string("MessageConnectInvalidAddress")
        case .invalidCustomHeader: L10n.string("MessageCustomHeaderInvalid")
        case .reservedHeader(let name): L10n.string("MessageCustomHeaderReserved", name)
        case .cannotConnect: L10n.string("MessageConnectCannotConnect")
        case .localNetworkDenied: L10n.string(Self.localNetworkDeniedKey)
        case .untrustedCertificate: L10n.string("MessageConnectUntrustedCertificate")
        case .secureConnectionFailed: L10n.string("MessageConnectSecureConnectionFailed")
        case .insecureConnectionBlocked: L10n.string("MessageConnectInsecureConnectionBlocked")
        case .httpsUnavailable(let address): L10n.string("MessageConnectHTTPSUnavailable", address.description)
        case .notAudiobookshelf: L10n.string("MessageConnectNotAudiobookshelf")
        case .serverNotInitialized: L10n.string("MessageConnectNotInitialized")
        case .unsupportedVersion(let version?) where ServerVersion(version) != nil:
            L10n.string("MessageConnectUnsupportedVersion", version, minimum)
        case .unsupportedVersion: L10n.string("MessageConnectUnknownVersion", minimum)
        case .accessDenied(let status): L10n.string("MessageConnectAccessDenied", String(status))
        case .statusFailed(let status): L10n.string("MessageConnectStatusFailed", String(status))
        case .redirectedToOtherHost(let host): L10n.string("MessageConnectRedirectedToOtherHost", host)
        case .insecureRedirect: L10n.string("MessageConnectInsecureRedirect")
        case .loginRedirected: L10n.string("MessageConnectLoginRedirected")
        case .invalidCredentials: L10n.string("MessageConnectInvalidCredentials")
        case .tooManyAttempts: L10n.string("MessageConnectTooManyAttempts")
        case .sessionExpired: L10n.string("MessageFailedToRefreshToken")
        case .keychainUnavailable: L10n.string("MessageConnectKeychainUnavailable")
        case .unexpected: L10n.string("MessageConnectUnexpected")
        case .message(let message): message.isEmpty ? L10n.string("MessageConnectUnexpected") : message
        }
    }

    #if os(macOS)
        private static let localNetworkDeniedKey = "MessageConnectLocalNetworkDeniedMac"
    #else
        private static let localNetworkDeniedKey = "MessageConnectLocalNetworkDenied"
    #endif

    /// Where the user turns local network access back on.
    static var localNetworkSettingsURL: URL? {
        #if os(macOS)
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #else
            URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

/// The last failure, with its recovery: connecting over `http` after the `https` attempt
/// failed, or opening Settings when local network access is off.
struct ConnectFailureSection: View {
    let model: ConnectViewModel
    let failure: ConnectFailure
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Label {
                Text(verbatim: failure.message)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            switch failure {
            case .httpsUnavailable:
                Button {
                    Task { await model.connectWithoutEncryption() }
                } label: {
                    Text(verbatim: L10n.string("ButtonConnectWithoutEncryption"))
                }
            case .localNetworkDenied:
                if let url = ConnectFailure.localNetworkSettingsURL {
                    Button {
                        openURL(url)
                    } label: {
                        Text(verbatim: L10n.string("ButtonOpenSettings"))
                    }
                }
                Button {
                    Task { await model.retry() }
                } label: {
                    Text(verbatim: L10n.string("ButtonRetry"))
                }
            default:
                EmptyView()
            }
        }
        .disabled(model.isBusy)
    }
}

/// The non-blocking warning for plain `http` to a public host (ADR 0002).
struct PlainHTTPWarningSection: View {
    var body: some View {
        Section {
            Label {
                Text(verbatim: L10n.string("MessagePlainHTTPWarning"))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// A button label with a spinner while its action runs.
struct ConnectButtonLabel: View {
    let title: String
    var isRunning = false

    var body: some View {
        HStack {
            Text(verbatim: title)
            if isRunning {
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
