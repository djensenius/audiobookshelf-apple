import ABSAPI
import ABSCore
import ABSData
import Foundation

/// The server side of streaming playback for one connection: starting, resolving and closing
/// sessions (P2-03). ``APIPlaybackSessionService`` is the live implementation; tests use stubs.
public protocol PlaybackSessionService: Sendable {
    /// The connection the sessions belong to; part of every ``MediaKey`` the coordinator builds.
    var serverConnectionID: UUID { get }
    /// `POST /api/items/:id/play[/:episodeId]`.
    func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession
    /// The user's server progress for the media, or `nil` when there is none. The coordinator uses
    /// its `lastUpdate` and `isFinished`: a new session's own `updatedAt` is its creation time.
    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress?
    /// The URLs to load for `session`. Throws ``StreamResolutionError``.
    func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream
    /// `POST /api/session/:id/close`, applying `report` first when given.
    func closeSession(id: String, report: PlaybackSyncReport?) async throws
}

/// A session's stream plan with the URL to load for each of its tracks.
public struct ResolvedStream: Sendable, Hashable {
    public let plan: StreamPlan
    /// One URL per entry of `plan.tracks`, in the same order.
    public let urls: [URL]

    public init(plan: StreamPlan, urls: [URL]) {
        self.plan = plan
        self.urls = urls
    }
}

/// Why a session's tracks can't be played.
public enum StreamResolutionError: Error, Sendable, Hashable {
    case resolution(TrackURLResolutionError)
    /// The connection has custom headers, which need the resource-loader transport the engine
    /// doesn't have yet (ADR 0007 §6).
    case customHeaderTransportUnavailable
    /// A token-fallback track needs an access token and the connection has none.
    case missingAccessToken
    /// The stream plan doesn't have a URL for every timeline track.
    case trackCountMismatch
}

/// The settings the coordinator reads; ``AppSettings`` conforms.
@MainActor
public protocol PlaybackSettingsProviding: AnyObject {
    /// The saved playback rate; the coordinator writes it when the user changes the rate.
    var playbackRate: Double { get set }
    var disableAutoRewind: Bool { get }
    var enableMp3IndexSeeking: Bool { get }
    var streamingUsingCellular: CellularPolicy { get }
}

extension AppSettings: PlaybackSettingsProviding {}

/// Decides whether streaming may start on the current network path (P1-15).
@MainActor
public protocol StreamingPolicyChecking {
    func streamingDecision() async -> NetworkDecision
}

extension NetworkPolicy: StreamingPolicyChecking {
    /// Waits briefly for the first path, so a play at cold launch (CarPlay, an intent) isn't
    /// allowed only because the monitor hasn't reported yet.
    public func streamingDecision() async -> NetworkDecision {
        await canStream(waitingUpTo: .milliseconds(500))
    }
}

/// Reads local progress; ``LocalProgressStore`` conforms.
public protocol LocalProgressReading: Sendable {
    func progress(for key: MediaKey) async throws -> LocalMediaProgressDTO?
}

extension LocalProgressStore: LocalProgressReading {}

/// The last item played on this device, restored paused at launch.
public struct LastPlayedRecord: Sendable, Hashable, Codable {
    public var serverConnectionID: UUID
    public var libraryItemID: String
    public var episodeID: String?
    /// Global seconds.
    public var position: Double
    /// The media duration when known, for display before the item is loaded.
    public var duration: Double?
    /// When the position was saved; drives auto-rewind and the newest-progress choice.
    public var timestamp: Date

    public init(
        serverConnectionID: UUID, libraryItemID: String, episodeID: String?, position: Double, duration: Double?,
        timestamp: Date
    ) {
        self.serverConnectionID = serverConnectionID
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.position = position
        self.duration = duration
        self.timestamp = timestamp
    }

    public var key: MediaKey {
        MediaKey(serverConnectionID: serverConnectionID, libraryItemId: libraryItemID, episodeId: episodeID)
    }
}

/// Persists the ``LastPlayedRecord``.
@MainActor
public protocol LastPlayedStoring: AnyObject {
    func load() -> LastPlayedRecord?
    func save(_ record: LastPlayedRecord)
    func clear()
}

/// Keeps the ``LastPlayedRecord`` as JSON in `UserDefaults` (the App Group store by default).
@MainActor
public final class UserDefaultsLastPlayedStore: LastPlayedStoring {
    public static let defaultKey = "playback_lastPlayed"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = AppSettings.sharedDefaults(), key: String = UserDefaultsLastPlayedStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> LastPlayedRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastPlayedRecord.self, from: data)
    }

    public func save(_ record: LastPlayedRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
