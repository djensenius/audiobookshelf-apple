import ABSAPI
import Foundation
import Observation

/// The account state ``SessionLifecycle`` follows.
public enum AccountSessionPhase: Sendable, Hashable {
    case signedOut
    /// Restoring the saved session or switching to another connection.
    case restoring
    /// Signed in. `isOffline` is `true` when the saved session is used without the server.
    case active(SessionIdentity, isOffline: Bool)

    public var identity: SessionIdentity? {
        if case .active(let identity, _) = self { identity } else { nil }
    }
}

/// The accounts seam of ``SessionLifecycle``; `AccountManager` conforms through an adapter.
///
/// ``phase`` and ``client`` must be observable: the lifecycle watches them with `Observations`.
/// A session whose identity disappears without a ``SessionLifecycle`` transition is treated as
/// expired on the server. Sign out, switch and remove through ``SessionLifecycle``, not the
/// source, so the session is flushed and ended first; before signing in to another account
/// while signed in, run the sign-in inside ``SessionLifecycle/performAccountChange(from:_:)``.
@MainActor
public protocol AccountSessionSource: AnyObject, Observable, Sendable {
    var phase: AccountSessionPhase { get }
    /// The active connection's client, or `nil` when there's none (for example offline with an
    /// unreadable Keychain).
    var client: APIClient? { get }

    /// Restores the saved session at launch.
    /// - Throws: Only when the local store can't be used; the gate then shows
    ///   ``AuthGate/storeUnavailable(_:)``. Otherwise failures leave ``phase`` signed out.
    func restore() async throws
    /// Signs out of the active connection.
    /// - Returns: An OpenID end-session URL to open, if the server returned one.
    func logout() async -> URL?
    /// Signs out of `connectionID` after it stopped being active, as when the server signed it
    /// out first; does nothing if it's active again or another sign-in replaced its session.
    /// - Returns: An OpenID end-session URL to open, as for ``logout()``.
    func logout(connectionID: UUID) async -> URL?
    /// Makes another saved connection active.
    func `switch`(to connectionID: UUID) async throws
    /// Forgets a saved connection, signing out if it's the active one.
    /// - Returns: An OpenID end-session URL to open, as for ``logout()``.
    func remove(_ connectionID: UUID) async throws -> URL?
    /// The saved connection signed in to a Handoff activity's account, for
    /// ``HandoffActivity/resolve(using:)``: one that matches it and still has a saved session to
    /// switch to. `nil` when no connection here is.
    func connectionID(for account: HandoffAccount) async -> UUID?
}

extension AccountSessionSource {
    /// Nothing to sign out of once the connection isn't active.
    public func logout(connectionID: UUID) async -> URL? { nil }

    /// No saved connections to match, so an activity that names an account opens nothing.
    public func connectionID(for account: HandoffAccount) async -> UUID? { nil }
}
