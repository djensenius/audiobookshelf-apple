import ABSAPI
import ABSCore
import Foundation

/// The server calls ``ProgressSyncer`` makes for one connection. ``APIProgressSyncService`` is
/// the live implementation; tests use stubs.
public protocol ProgressSyncService: Sendable {
    var serverConnectionID: UUID { get }
    /// `POST /api/session/:id/sync`. Must return only once the request's task has completed.
    func syncSession(id: String, report: PlaybackSyncReport) async throws
    /// `PATCH /api/me/progress/:itemID[/:episodeID]` with one field group.
    func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws
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

    public func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        _ = try await client.send(ProgressEndpoints.update(itemID: itemID, episodeID: episodeID, update))
    }
}

/// The wall clock (edit times) and a monotonic clock (listening time and cadence) for
/// ``ProgressSyncer``; tests drive both by hand.
public struct ProgressSyncClock: Sendable {
    public var now: @Sendable () -> Date
    /// Monotonic seconds from an arbitrary origin.
    public var uptime: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> Date, uptime: @escaping @Sendable () -> TimeInterval) {
        self.now = now
        self.uptime = uptime
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
    var duration: Double { get }
    var isPlaying: Bool { get }
    var chapterIndex: Int? { get }
    var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackSyncReport?)? { get set }
    func addObserver(_ handler: @escaping @MainActor (PlaybackCoordinatorEvent) -> Void) -> PlaybackObserverToken
    func removeObserver(_ token: PlaybackObserverToken)
}

extension PlaybackCoordinator: PlaybackProgressSource {}
