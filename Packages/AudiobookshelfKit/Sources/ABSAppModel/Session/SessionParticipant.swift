import ABSAPI
import Foundation

/// What a participant gets when a session starts.
public struct SessionContext: Sendable {
    public let identity: SessionIdentity
    /// The connection's client; `nil` when the source has none.
    public let client: APIClient?
    public let isOffline: Bool

    public init(identity: SessionIdentity, client: APIClient?, isOffline: Bool) {
        self.identity = identity
        self.client = client
        self.isOffline = isOffline
    }
}

/// Why a session ends.
public enum SessionEndReason: Sendable, Hashable {
    /// The user signed out.
    case signOut
    /// The user switched to another account, or the source changed identity by itself.
    case `switch`
    /// The server rejected the session. The tokens are gone, so participants must not send
    /// anything to the server; keep unsent work in the durable store instead.
    case expired
}

/// When a participant starts relative to the library seed. See ``SessionLifecycle``.
public enum SessionStage: Sendable, Hashable {
    /// Starts before ``SessionSeeding/beginSeed(_:)``: the library connect, image request
    /// builders and anything else that doesn't write progress.
    case connect
    /// Starts after ``SessionSeeding/beginSeed(_:)``: everything that applies progress to the
    /// library (playback, the progress syncer, the realtime socket).
    case progressSource
}

/// Something with per-session state: the library, images, playback, downloads.
@MainActor
public protocol SessionParticipant: AnyObject, Sendable {
    func sessionDidStart(_ context: SessionContext) async
    /// Stops the participant's work for the session. With ``SessionEndReason/expired`` this must
    /// not use the network.
    func sessionWillEnd(_ reason: SessionEndReason) async
    /// Sends pending work to the server, on background and before a sign-out or switch. The
    /// lifecycle waits for it only up to its flush timeout. The default does nothing.
    func flush() async
}

extension SessionParticipant {
    public func flush() async {}
}

/// The library's seeding hooks, around the ``SessionStage/progressSource`` participants.
///
/// The seeder is also the first ``SessionStage/connect`` participant: its
/// ``SessionParticipant/sessionDidStart(_:)`` connects the library and its
/// ``SessionParticipant/sessionWillEnd(_:)`` clears it, after every other participant ended.
@MainActor
public protocol SessionSeeding: SessionParticipant {
    /// Marks the seed boundary. Progress applied after it survives the seed.
    func beginSeed(_ context: SessionContext) async
    /// Fetches the user's progress (`/api/me`) and seeds the library with it. Runs in its own
    /// task, cancelled when the session ends; a seed that finishes after the session ended
    /// must be dropped by the seeder.
    func seed(_ context: SessionContext) async
}
