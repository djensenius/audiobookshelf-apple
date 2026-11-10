import ABSAPI
import Foundation

/// What a participant gets when a session starts.
public struct SessionContext: Sendable {
    public let identity: SessionIdentity
    /// The connection's client; `nil` when the source has none.
    public let client: APIClient?
    public let isOffline: Bool
    /// Tells this session apart from every other one of the same lifecycle, including a later
    /// session of the same identity. It stays the same across a reconnect.
    public let sessionID: UInt64

    public init(identity: SessionIdentity, client: APIClient?, isOffline: Bool, sessionID: UInt64) {
        self.identity = identity
        self.client = client
        self.isOffline = isOffline
        self.sessionID = sessionID
    }
}

/// Why a session ends.
public enum SessionEndReason: Sendable, Hashable {
    /// The user signed out.
    case signOut
    /// The user switched to another account or is adding one, or the source changed identity by
    /// itself.
    case `switch`
    /// The user removed the active account: its saved data may be deleted next.
    case removed
    /// The server rejected the session. The tokens are gone, so participants must not send
    /// anything to the server; keep unsent work in the durable store instead.
    case expired
}

/// When a participant starts relative to the library seed. See ``SessionLifecycle``.
public enum SessionStage: Sendable, Hashable {
    /// Starts before ``SessionSeeding/beginSeed(_:)``: the library connect, image request
    /// builders and anything else that doesn't write progress. A `.connect` participant must
    /// never apply progress to the library, or the seed may drop it.
    case connect
    /// Starts after ``SessionSeeding/beginSeed(_:)``: everything that applies progress to the
    /// library (playback, the progress syncer, the realtime socket).
    case progressSource
}

/// Something with per-session state: the library, images, playback, downloads.
///
/// The lifecycle calls these one transition at a time, so:
/// - ``sessionDidStart(_:)``, ``sessionDidReconnect(_:)`` and ``sessionWillEnd(_:)`` must return
///   promptly; they hold up the gate and every other transition. Start network work in a task the
///   participant owns and cancels on end. For example, the library adapter (S7a) must not await
///   `LibraryStore.refresh()` inside `sessionDidStart`: it sets the connection, then refreshes in
///   its own task. The whole teardown is given at most the lifecycle's flush timeout.
/// - A participant must not await ``SessionLifecycle`` transitions (`signOut()`,
///   `switchAccount(to:)` and the rest) from these methods, ``flush()`` or the tasks they start
///   while the transition runs: that would deadlock, so such a call asserts and does nothing.
///   To sign out from there (say, on a rejected request), call
///   ``SessionLifecycle/requestSignOut(of:)`` with the participant's ``SessionContext``, which
///   queues it without waiting and ignores it once that session has ended.
@MainActor
public protocol SessionParticipant: AnyObject, Sendable {
    func sessionDidStart(_ context: SessionContext) async
    /// The same identity came back online or got a new client, for example after a launch with
    /// a locked Keychain. Replace the client from `context`. Called in start order, after the
    /// new seed boundary (``SessionSeeding/beginSeed(_:)``) and before the new seed. The default
    /// does nothing.
    func sessionDidReconnect(_ context: SessionContext) async
    /// Stops the participant's work for the session. With ``SessionEndReason/expired`` this must
    /// not use the network.
    ///
    /// The synchronous part, before the first `await`, must stop every progress write and detach
    /// from the library. The teardown shares one time budget: once it's spent, the lifecycle
    /// cancels the rest of this call and moves on while it may still be running, and the next
    /// account's session can begin. The library's progress cache has no generation check, so a
    /// write after that point would land in the next account.
    func sessionWillEnd(_ reason: SessionEndReason) async
    /// Sends pending work to the server, on background and before a sign-out, switch or removal.
    /// Every participant flushes concurrently, and the lifecycle waits at most its flush
    /// timeout, then cancels the flushes. A flush must honour cancellation, and must tolerate
    /// ``sessionWillEnd(_:)`` arriving while a cancelled flush is still running.
    ///
    /// Flushes may overlap (a background flush during a sign-out's), and a flush may arrive
    /// after ``sessionWillEnd(_:)``; it must then do nothing. The default does nothing.
    func flush() async
}

extension SessionParticipant {
    public func sessionDidReconnect(_ context: SessionContext) async {}
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
    /// task, cancelled when the session ends or reconnects. Cancellation can arrive after the
    /// fetch returned, so the seeder must drop a seed whose session ended or reseeded since,
    /// by a generation or the token from ``beginSeed(_:)``, not only by `Task.isCancelled`.
    func seed(_ context: SessionContext) async
}
