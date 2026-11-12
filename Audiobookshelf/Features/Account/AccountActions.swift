import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What the Account tab and the server list do, outside the views so tests can drive them.
///
/// Both go through the session lifecycle, so the running session ends first, each in its own
/// task, as the change replaces the shell. Neither starts unless the session is ready
/// (``SessionLifecycle/acceptsAccountChanges``), and each names the session it was chosen from
/// (``SessionLifecycle/readySession``), so the lifecycle drops it if another change left it.
@MainActor
struct AccountActions {
    let lifecycle: SessionLifecycle
    /// Checks that a server switched to has a saved session before the running one ends.
    var accounts: AccountManager?

    /// Signs out, then opens any OpenID end-session page with `openURL`.
    /// - Returns: The sign-out's task, or `nil` when the session isn't ready.
    @discardableResult
    func signOut(openURL: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        guard let origin = lifecycle.readySession else { return nil }
        return Task { await signOut(from: origin, openURL: openURL) }
    }

    /// The sign-out, chosen from `origin`.
    func signOut(from origin: ReadySession, openURL: @MainActor (URL) -> Void) async {
        open(await lifecycle.signOut(of: origin), with: openURL)
    }

    /// Opens `endSession` right away, unless a sign-in has begun since the sign-out.
    func open(_ endSession: URL?, with openURL: @MainActor (URL) -> Void) {
        guard let endSession, accounts?.hasBegunSinceLogout != true else { return }
        openURL(endSession)
    }

    /// Switches to another saved connection.
    /// - Returns: The switch's task, or `nil` when the session isn't ready.
    @discardableResult
    func switchAccount(to connectionID: UUID) -> Task<SwitchOutcome, Never>? {
        guard let origin = lifecycle.readySession else { return nil }
        return Task { await switchAccount(to: connectionID, from: origin) }
    }

    /// The switch, chosen from `origin`; it succeeds only if that connection's session is ready.
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
        return .switched(epoch: lifecycle.linkEpoch)
    }

    /// Whether the server list offers to remove `connectionID`: a saved server other than the
    /// running one (Log Out covers that), only while the session is ready, so not during another
    /// window's switch.
    func canRemove(_ connectionID: UUID) -> Bool {
        guard let accounts, let running = lifecycle.readySession else { return false }
        return connectionID != running.identity.connectionID && connectionID != accounts.activeConnection?.id
    }

    /// Whether the server list has any row removal could ever apply to: a saved server other than
    /// the active one. Structural, so it doesn't flicker with a switch or removal in flight; the
    /// list's Edit control shows while it holds, and edit mode ends once it doesn't.
    static func offersRemoval(among connectionIDs: [UUID], activeID: UUID?) -> Bool {
        connectionIDs.contains { $0 != activeID }
    }

    /// Forgets a saved server other than the running one, and its saved session, through
    /// ``SessionLifecycle/removeInactiveAccount(_:from:)``; the session keeps running. Chosen from
    /// the ready session, the removal fails, rather than signing out, if a change queued before it
    /// (say, another window's switch to this server) made the server active or ended that session.
    /// - Returns: The removal's task, which says whether it succeeded, or `nil` when
    ///   ``canRemove(_:)`` refuses it.
    @discardableResult
    func removeServer(_ connectionID: UUID) -> Task<Bool, Never>? {
        guard canRemove(connectionID), let origin = lifecycle.readySession else { return nil }
        return Task {
            do {
                try await lifecycle.removeInactiveAccount(connectionID, from: origin)
                return true
            } catch {
                Log.ui.error("Couldn't remove a server: \(String(describing: type(of: error)), privacy: .public)")
                return false
            }
        }
    }
}

/// How ``AccountActions/switchAccount(to:)`` ended.
enum SwitchOutcome: Equatable {
    /// With the new account's link epoch, which a later change, say from another window, moves on.
    case switched(epoch: UInt64)
    case failed(SwitchFailure)

    var succeeded: Bool { if case .switched = self { true } else { false } }
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
    /// What the root says when a switch ended signed out (``SessionLifecycle/signedOutSwitches``)
    /// after `error`: an unreadable Keychain or unsupported version, which signing in again can't
    /// fix, get the connect screen's message; otherwise the server rejected the saved session.
    func signedOutSwitchMessage(after error: (any Error)? = nil) -> String {
        if let error, SwitchFailure(error) == .keychainUnavailable {
            SwitchFailure.keychainUnavailable.message
        } else if case .server(.unsupportedVersion(let version))? = lastError {
            ConnectFailure.unsupportedVersion(version).message
        } else {
            L10n.string("MessageSwitchServerSignedOut")
        }
    }
}
