import ABSAppModel
import ABSCore
import Foundation

/// What the Account tab and the server list do, outside the views so tests can drive them.
///
/// Both go through the session lifecycle, never straight to `AccountManager`, so the running
/// session flushes and ends before the account changes. Each runs in its own task, not the
/// view's: the change replaces the shell, and that must not cancel it half way. Neither starts
/// unless the session is ready (``SessionLifecycle/acceptsAccountChanges``): while it switches,
/// the old shell stays on screen but is no longer interactive.
@MainActor
struct AccountActions {
    let lifecycle: SessionLifecycle

    /// Signs out, then opens the identity provider's end-session page with `openURL` if the
    /// server returned one (an OpenID session).
    /// - Returns: The sign-out's task, or `nil` when the session isn't ready.
    @discardableResult
    func signOut(openURL: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        guard lifecycle.acceptsAccountChanges else { return nil }
        return Task { [lifecycle] in
            if let endSession = await lifecycle.signOut() { openURL(endSession) }
        }
    }

    /// Switches to another saved connection.
    /// - Returns: A task whose value is whether the switch succeeded (a failure is logged), or
    ///   `nil` when the session isn't ready.
    @discardableResult
    func switchAccount(to connectionID: UUID) -> Task<Bool, Never>? {
        guard lifecycle.acceptsAccountChanges else { return nil }
        return Task { [lifecycle] in
            do {
                try await lifecycle.switchAccount(to: connectionID)
                return true
            } catch {
                Log.ui.error("Couldn't switch servers: \(String(describing: type(of: error)), privacy: .public)")
                return false
            }
        }
    }
}

extension SessionLifecycle {
    /// Whether the shell may start a sign-out or a switch: only from a ready session. It reads the
    /// shared gate, so every window agrees, including one that didn't start the change.
    var acceptsAccountChanges: Bool { gate.identity != nil }
}
