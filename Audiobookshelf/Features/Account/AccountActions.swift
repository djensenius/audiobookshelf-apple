import ABSAppModel
import ABSCore
import Foundation

/// What the Account tab and the server list do, outside the views so tests can drive them.
///
/// Both go through the session lifecycle, never straight to `AccountManager`, so the running
/// session flushes and ends before the account changes. Each runs in its own task, not the
/// view's: the change replaces the shell, and that must not cancel it half way. Neither starts
/// unless the session is ready (``SessionLifecycle/acceptsAccountChanges``): while it switches,
/// the old shell stays on screen but is no longer interactive. Each also names the account it
/// was chosen from, and the lifecycle drops it if another change (say, from another window)
/// left that account first.
@MainActor
struct AccountActions {
    let lifecycle: SessionLifecycle

    /// Signs out, then opens the identity provider's end-session page with `openURL` if the
    /// server returned one (an OpenID session).
    /// - Returns: The sign-out's task, or `nil` when the session isn't ready.
    @discardableResult
    func signOut(openURL: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        guard let identity = lifecycle.gate.identity else { return nil }
        return Task { [lifecycle] in
            if let endSession = await lifecycle.signOut(of: identity) { openURL(endSession) }
        }
    }

    /// Switches to another saved connection.
    /// - Returns: A task whose value is whether that connection's session is ready (a failure is
    ///   logged), or `nil` when the session isn't ready. A switch can fail without throwing: the
    ///   server can reject the saved session or its version, which signs out.
    @discardableResult
    func switchAccount(to connectionID: UUID) -> Task<Bool, Never>? {
        guard let identity = lifecycle.gate.identity else { return nil }
        return Task { [lifecycle] in
            do {
                try await lifecycle.switchAccount(to: connectionID, from: identity)
            } catch {
                Log.ui.error("Couldn't switch servers: \(String(describing: type(of: error)), privacy: .public)")
                return false
            }
            guard lifecycle.gate.identity?.connectionID == connectionID else {
                Log.ui.notice("A server switch didn't reach the server's session")
                return false
            }
            return true
        }
    }
}

extension SessionLifecycle {
    /// Whether the shell may start a sign-out or a switch: only from a ready session. It reads the
    /// shared gate, so every window agrees, including one that didn't start the change.
    var acceptsAccountChanges: Bool { gate.identity != nil }
}

extension AuthGate {
    /// Whether going from this gate to `next` is a switch that ended signed out: the server
    /// rejected the saved session (or its version) of the account switched to. The old shell,
    /// and any message it would show, is gone by then, so the root tells the user.
    func signsOutSwitch(to next: AuthGate) -> Bool {
        if case .switching = self { next == .connect } else { false }
    }
}
