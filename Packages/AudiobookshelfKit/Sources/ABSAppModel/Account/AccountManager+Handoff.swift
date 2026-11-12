import Foundation

extension AccountManager {
    /// The saved connection signed in to a Handoff activity's account (ADR 0004, "Handoff"): the
    /// first one, most recently used first, that matches it and that ``hasSession(_:)``. An
    /// expiry deletes the tokens but keeps the connection without a sign-out, so a match alone
    /// would offer a switch that fails.
    public func connectionID(for account: HandoffAccount) async -> UUID? {
        for connection in connections where account.matches(connection) {
            if await hasSession(connection.id) { return connection.id }
        }
        return nil
    }
}
