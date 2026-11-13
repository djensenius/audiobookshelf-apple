import ABSAPI
import ABSCore
import ABSData
import Foundation

/// The server calls ``ProgressSyncer`` makes for one connection. ``APIProgressSyncService`` is
/// the live implementation; tests use stubs.
public protocol ProgressSyncService: Sendable {
    var serverConnectionID: UUID { get }
    /// Canonical `GET /api/me/progress/:itemID[/:episodeID]`.
    /// `nil` is authoritative absence, as documented by `APIClient.mediaProgress` for 404,
    /// not an unusable response. Return undated progress as-is; other lookup failures throw.
    func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress?
    /// `POST /api/session/:id/sync`. Must return only once the request's task has completed.
    func syncSession(id: String, report: PlaybackSyncReport) async throws
    /// `GET /api/session/:id`: the open session, with the listening time the server has applied
    /// to it. Throws `APIError.notFound` once it is no longer open.
    func openSession(id: String) async throws -> PlaybackSession
    /// `PATCH /api/me/progress/:itemID[/:episodeID]` with one field group.
    func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws
    /// `POST /api/session/:id/close`, applying `report` first when given: a retried final close
    /// (#382). Throws `APIError.notFound` once the session is no longer open.
    func closeSession(id: String, report: PlaybackSyncReport?) async throws
    /// `GET /api/me/item/listening-sessions/:itemID[/:episodeID]`'s first page: the media's
    /// stored sessions, newest first, which tell whether a close answered 404 counted (#382).
    /// Throws `APIError.notFound` when the item or episode is gone.
    func listeningSessions(itemID: String, episodeID: String?) async throws -> ListeningSessionsPage
}

/// ``ProgressSyncService`` over one connection's ``APIClient``.
public struct APIProgressSyncService: ProgressSyncService {
    public let serverConnectionID: UUID
    private let client: APIClient

    public init(serverConnectionID: UUID, client: APIClient) {
        self.serverConnectionID = serverConnectionID
        self.client = client
    }

    public func syncSession(id: String, report: PlaybackSyncReport) async throws {
        _ = try await client.send(SessionEndpoints.sync(sessionID: id, report: report))
    }

    public func openSession(id: String) async throws -> PlaybackSession {
        try await client.send(SessionEndpoints.openSession(id: id))
    }

    public func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await client.mediaProgress(itemID: itemID, episodeID: episodeID)
    }

    public func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        _ = try await client.send(ProgressEndpoints.update(itemID: itemID, episodeID: episodeID, update))
    }

    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        _ = try await client.send(SessionEndpoints.close(sessionID: id, report: report))
    }

    public func listeningSessions(itemID: String, episodeID: String?) async throws -> ListeningSessionsPage {
        try await client.send(SessionEndpoints.listeningSessions(itemID: itemID, episodeID: episodeID))
    }
}

/// The wall clock (edit times), a monotonic clock (listening time and cadence) and a sleep
/// (retry wakes) for ``ProgressSyncer``; tests drive all three by hand.
public struct ProgressSyncClock: Sendable {
    public var now: @Sendable () -> Date
    /// Monotonic seconds from an arbitrary origin.
    public var uptime: @Sendable () -> TimeInterval
    /// Suspends for at least the given monotonic seconds; throws when cancelled.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date, uptime: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.uptime = uptime
        self.sleep = sleep
    }

    public static var live: ProgressSyncClock {
        let origin = ContinuousClock.now
        return ProgressSyncClock(
            now: { .now },
            uptime: {
                let elapsed = origin.duration(to: .now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
            })
    }
}

/// What ``ProgressSyncer`` reads from playback; ``PlaybackCoordinator`` conforms.
@MainActor
public protocol PlaybackProgressSource: AnyObject {
    var currentTime: Double { get }
    /// Confirmed engine sample, never a seek target; nil while waiting/seeking. Includes the
    /// final pre-stop sample during `finalCloseReport`, even though the engine is already stopped.
    var confirmedPlaybackTime: Double? { get }
    /// The `loaded` event carries a newly chosen start/seek/jump, not automatic resume progress.
    var loadedPositionIsExplicit: Bool { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var chapterIndex: Int? { get }
    /// The open session's title, for playback history.
    var sessionDisplayTitle: String? { get }
    /// Where the latest automatic seek (a resume's rewind, or a load's late landing) landed
    /// (history doesn't count it as a seek).
    var resumeRewindLanding: Double? { get }
    /// The latest load's landing is a seek or jump the user made while it loaded (history records
    /// it as a seek, even at `loaded`'s time).
    var loadLandingIsUserSeek: Bool { get }
    /// How the latest start's server progress moved the stored position (history).
    var startProgressChange: ServerAudioPositionChange? { get }
    var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackCloseHandoff?)? { get set }
    /// Synchronously suppresses sync/PATCH transport before account teardown can suspend.
    var quiesceProgressTransport: (@MainActor () -> Void)? { get set }
    func addObserver(_ handler: @escaping @MainActor (PlaybackCoordinatorEvent) -> Void) -> PlaybackObserverToken
    func removeObserver(_ token: PlaybackObserverToken)
}

extension PlaybackCoordinator: PlaybackProgressSource {
    public var sessionDisplayTitle: String? { session?.displayTitle }
}
