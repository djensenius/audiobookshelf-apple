import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What the Account tab and the server list do, outside the views so tests can drive them.
///
/// Both go through the session lifecycle, never straight to `AccountManager`, so the running
/// session flushes and ends before the account changes. Each runs in its own task, not the
/// view's: the change replaces the shell, and that must not cancel it half way. Neither starts
/// unless the session is ready (``SessionLifecycle/acceptsAccountChanges``): while it switches,
/// the old shell stays on screen but is no longer interactive. Each also names the session it
/// was chosen from (``SessionLifecycle/readySession``), and the lifecycle drops it if another
/// change (say, from another window) left that session first.
@MainActor
struct AccountActions {
    let lifecycle: SessionLifecycle
    /// Checks that a server switched to has a saved session before the running one ends.
    var accounts: AccountManager?

    /// Signs out, then opens the identity provider's end-session page with `openURL` if the
    /// server returned one (an OpenID session).
    /// - Returns: The sign-out's task, or `nil` when the session isn't ready.
    @discardableResult
    func signOut(openURL: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        guard let origin = lifecycle.readySession else { return nil }
        return Task { await signOut(from: origin, openURL: openURL) }
    }

    /// The sign-out, chosen from `origin`.
    func signOut(from origin: ReadySession, openURL: @MainActor (URL) -> Void) async {
        if let endSession = await lifecycle.signOut(of: origin) { openURL(endSession) }
    }

    /// Switches to another saved connection.
    /// - Returns: A task whose value is whether that connection's session is ready (a failure is
    ///   logged), or `nil` when the session isn't ready. A switch can fail without throwing: the
    ///   server can reject the saved session or its version, which signs out.
    @discardableResult
    func switchAccount(to connectionID: UUID) -> Task<SwitchOutcome, Never>? {
        guard let origin = lifecycle.readySession else { return nil }
        return Task { await switchAccount(to: connectionID, from: origin) }
    }

    /// The switch, chosen from `origin`.
    /// - Returns: Whether that connection's session is ready.
    func switchAccount(to connectionID: UUID, from origin: ReadySession) async -> SwitchOutcome {
        // Without a session the switch would only fail, after ending the running one.
        if let accounts, await !accounts.hasSession(connectionID) {
            Log.ui.notice("Didn't switch to a server without a saved session")
            return .failed(.other)
        }
        do {
            try await lifecycle.switchAccount(to: connectionID, from: origin)
        } catch {
            Log.ui.error("Couldn't switch servers: \(String(describing: type(of: error)), privacy: .public)")
            return .failed(SwitchFailure(error))
        }
        guard lifecycle.gate.identity?.connectionID == connectionID else {
            Log.ui.notice("A server switch didn't reach the server's session")
            return .failed(.other)
        }
        return .switched
    }
}

/// How ``AccountActions/switchAccount(to:)`` ended.
enum SwitchOutcome: Equatable {
    case switched
    case failed(SwitchFailure)

    var succeeded: Bool { self == .switched }
}

/// Why a switch failed, for the alert the view shows.
enum SwitchFailure: Equatable {
    /// The saved session can't be read while the device is locked (``AccountManager/hasSession(_:)``
    /// lets that through, as the session may be fine): the connect screen's guidance.
    case keychainUnavailable
    case other

    init(_ error: any Error) {
        switch error {
        case let error as KeychainError where error.isUnavailable: self = .keychainUnavailable
        case AccountError.keychain(let error) where error.isUnavailable: self = .keychainUnavailable
        default: self = .other
        }
    }

    var message: String {
        switch self {
        case .keychainUnavailable: ConnectFailure.keychainUnavailable.message
        case .other: L10n.string("MessageSwitchServerFailed")
        }
    }
}

extension SessionLifecycle {
    /// Whether the shell may start a sign-out or a switch: only from a ready session. It reads the
    /// shared gate, so every window agrees, including one that didn't start the change.
    var acceptsAccountChanges: Bool { gate.identity != nil }
}

extension AccountManager {
    /// What the root says when a switch ended signed out (``SessionLifecycle/signedOutSwitches``):
    /// signing in again can't fix a server version the app no longer supports, so that gets the
    /// connect screen's message; otherwise the server rejected the saved session.
    var signedOutSwitchMessage: String {
        if case .server(.unsupportedVersion(let version))? = lastError {
            ConnectFailure.unsupportedVersion(version).message
        } else {
            L10n.string("MessageSwitchServerSignedOut")
        }
    }
}
