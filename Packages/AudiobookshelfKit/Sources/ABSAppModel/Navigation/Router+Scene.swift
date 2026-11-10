import Foundation

extension Router {
    /// A router for the scene of `identity`. Its server is the saved connection's ID and its
    /// user is the account's, so it accepts exactly the snapshots stored under
    /// ``SessionIdentity/snapshotKey`` and discards every other.
    public convenience init(identity: SessionIdentity) {
        self.init(serverID: identity.connectionID.uuidString, userID: identity.userID)
    }

    /// Starts a scene the way ADR 0004 orders it: restores the saved snapshot, adapts the
    /// selection to the size class, and only then opens the link that launched or continued
    /// the scene.
    ///
    /// The order matters. A restore resets every path and pending request, so a link opened
    /// before it would be lost, and ``normalize(isCompact:)`` must see the restored selection
    /// before the link navigates. A scene that has no link yet leaves its restored state as it
    /// is.
    /// - Parameters:
    ///   - data: The scene's saved ``snapshotData``; `nil` or unreadable data starts from the
    ///     defaults.
    ///   - isCompact: Whether the scene's horizontal size class is compact.
    ///   - link: A link the scene held until it was ready, for example one that cold-launched
    ///     the app.
    public func restoreScene(from data: Data?, isCompact: Bool, opening link: DeepLink?) {
        restore(from: data)
        normalize(isCompact: isCompact)
        if let link { open(link) }
    }
}
