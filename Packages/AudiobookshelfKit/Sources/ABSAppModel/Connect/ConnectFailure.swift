import ABSAPI
import ABSCore
import Foundation

/// Why connecting or signing in failed, for the connect screen to show as a localized message.
///
/// ABSAppModel doesn't import ABSUI, so the app maps each case to its `L10n` string.
public enum ConnectFailure: Error, Sendable, Hashable {
    case invalidAddress
    /// A custom header has no name or an invalid one, or a value on more than one line.
    case invalidCustomHeader
    /// `Authorization` and `Cookie` can't be custom headers.
    case reservedHeader(name: String)
    case cannotConnect
    /// The host is on the local network and the user turned off local network access. Recover
    /// in Settings, then retry.
    case localNetworkDenied
    /// TLS: the certificate isn't trusted, or the server requires a client certificate.
    case untrustedCertificate
    /// TLS: the handshake failed, for example `https` to a server that only speaks `http`.
    case secureConnectionFailed
    /// App Transport Security refused a plain-HTTP connection.
    case insecureConnectionBlocked
    /// `https` couldn't connect and the server has custom headers: connecting to this explicit
    /// `http` address sends them unencrypted, so the user has to confirm it.
    case httpsUnavailable(ServerAddress)
    case notAudiobookshelf
    case serverNotInitialized
    /// The server's version, `nil` or unparseable if unknown, is older than the minimum.
    case unsupportedVersion(String?)
    /// The server or a proxy answered 401 or 403 without a sign-in.
    case accessDenied(status: Int)
    case statusFailed(status: Int)
    case redirectedToOtherHost(String)
    case insecureRedirect
    case loginRedirected
    case invalidCredentials
    case tooManyAttempts
    /// The saved session ended; sign in again.
    case sessionExpired
    /// The saved sign-in can't be read while the device is locked.
    case keychainUnavailable
    case unexpected
    /// A message from ABSAPI that has no localized string yet (OpenID errors).
    case message(String)

    /// The failure for `error`, or `nil` when the user cancelled.
    init?(_ error: any Error) {
        switch error {
        case is CancellationError, OIDCLoginError.cancelled:
            return nil
        case let error as ServerValidationError:
            self.init(error)
        case let error as OIDCLoginError:
            self = .message(error.errorDescription ?? "")
        case CustomHeaderError.reserved(let name):
            self = .reservedHeader(name: name)
        case let error as AccountError:
            switch error {
            case .server(let error): self.init(error)
            case .keychain(let error) where error.isUnavailable: self = .keychainUnavailable
            case .notSignedIn: self = .sessionExpired
            case .keychain, .connectionNotFound: self = .unexpected
            }
        default:
            self = .unexpected
        }
    }

    private init(_ error: ServerValidationError) {
        switch error {
        case .invalidAddress: self = .invalidAddress
        case .reservedHeader(.reserved(let name)): self = .reservedHeader(name: name)
        case .cannotConnect(.secureConnectionFailed): self = .secureConnectionFailed
        case .cannotConnect(.appTransportSecurityRequiresSecureConnection): self = .insecureConnectionBlocked
        case .cannotConnect, .timedOut: self = .cannotConnect
        case .untrustedCertificate: self = .untrustedCertificate
        case .httpsUnavailable(let address): self = .httpsUnavailable(address)
        case .notAudiobookshelf: self = .notAudiobookshelf
        case .serverNotInitialized: self = .serverNotInitialized
        case .unsupportedVersion(let version): self = .unsupportedVersion(version)
        case .accessDenied(let status): self = .accessDenied(status: status)
        case .statusFailed(let status): self = .statusFailed(status: status)
        case .redirectedToOtherHost(let host): self = .redirectedToOtherHost(host)
        case .insecureRedirect: self = .insecureRedirect
        case .loginRedirected: self = .loginRedirected
        case .invalidCredentials: self = .invalidCredentials
        case .tooManyAttempts: self = .tooManyAttempts
        case .sessionExpired: self = .sessionExpired
        case .missingTokens, .unexpected: self = .unexpected
        }
    }
}
