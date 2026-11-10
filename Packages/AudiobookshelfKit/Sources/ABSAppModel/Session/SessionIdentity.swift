import Foundation

/// Who is signed in: one user on one saved server connection.
///
/// A change of identity (another server, or another user on the same server) ends the session
/// and starts a new one. Views key per-identity state on it, for example with `.id(identity)`.
public struct SessionIdentity: Sendable, Hashable, Codable {
    /// The saved connection's id, which is also the server ID used by images and navigation.
    public let connectionID: UUID
    /// The server's user ID.
    public let userID: String

    public init(connectionID: UUID, userID: String) {
        self.connectionID = connectionID
        self.userID = userID
    }

    /// The scene storage key for this identity's navigation snapshot (ADR 0004):
    /// `nav.snapshot.<serverID>.<userID>`.
    public var snapshotKey: String {
        "nav.snapshot.\(connectionID.uuidString).\(userID)"
    }
}
