import Foundation

extension AccountManager {
    /// The saved connection signed in to a Handoff activity's account (ADR 0004, "Handoff").
    /// ``connections`` is most recently used first, so the first match wins.
    public func connectionID(for account: HandoffAccount) -> UUID? {
        account.connectionID(in: connections)
    }
}
