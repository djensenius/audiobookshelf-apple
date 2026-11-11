import ABSAppModel
import ABSCore
import Foundation

/// What the Account tab and the server list do, outside the views so tests can drive them.
///
/// Both go through the session lifecycle, never straight to `AccountManager`, so the running
/// session flushes and ends before the account changes. Each runs in its own task, not the
/// view's: the change replaces the shell, and that must not cancel it half way.
@MainActor
struct AccountActions {
    let lifecycle: SessionLifecycle

    /// Signs out, then opens the identity provider's end-session page with `openURL` if the
    /// server returned one (an OpenID session).
    @discardableResult
    func signOut(openURL: @escaping @MainActor (URL) -> Void) -> Task<Void, Never> {
        Task { [lifecycle] in
            if let endSession = await lifecycle.signOut() { openURL(endSession) }
        }
    }

    /// Switches to another saved connection.
    /// - Returns: A task whose value is whether the switch succeeded; a failure is logged.
    @discardableResult
    func switchAccount(to connectionID: UUID) -> Task<Bool, Never> {
        Task { [lifecycle] in
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
