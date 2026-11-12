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
    /// its `currentTime`, `lastUpdate` and `isFinished` together, since the session's own position
    /// comes from a separate request and can differ (its `updatedAt` is just its creation time).
    /// When there is none, or this fails, the session's position is used only if there is no local
    /// progress or record. Server timestamps are compared with device ones, so clock skew between
    /// them can pick the older position.
    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress?
    /// The URLs to load for `session`. Throws ``StreamResolutionError`` when they can't be built, and
    /// `CancellationError` when the caller is cancelled: the coordinator drops that start without
    /// reporting a failure, and reports any other error as unexpected.
    func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream
    /// `POST /api/session/:id/close`, applying `report` first when given.
    func closeSession(id: String, report: PlaybackSyncReport?) async throws
}

/// A session's stream plan with the URL to load for each of its tracks.
public struct ResolvedStream: Sendable, Hashable {
    public let plan: StreamPlan
    /// One URL per entry of `plan.tracks`, in the same order.
    public let urls: [URL]
    /// For ``StreamPlan/Transport/customHeaderResourceLoader``, the transport that loads `urls`
    /// with the connection's custom headers; `nil` for plain `AVURLAsset`s.
    public let transport: HeaderStreamingTransport?

    public init(plan: StreamPlan, urls: [URL], transport: HeaderStreamingTransport? = nil) {
        self.plan = plan
        self.urls = urls
        self.transport = transport
    }
}

/// Why a session's tracks can't be played.
public enum StreamResolutionError: Error, Sendable, Hashable {
    case resolution(TrackURLResolutionError)
    /// A token-fallback track needs an access token and the connection has none: it is signed out,
    /// or the server rejected its refresh token, so the user has to sign in again.
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
    /// The decision for the path known now, without waiting (an auto-advance's last check).
    func currentStreamingDecision() -> NetworkDecision
}

extension NetworkPolicy: StreamingPolicyChecking {
    /// Waits briefly for the first path, so a play at cold launch (CarPlay, an intent) isn't
    /// allowed only because the monitor hasn't reported yet.
    public func streamingDecision() async -> NetworkDecision {
        await canStream(waitingUpTo: .milliseconds(500))
    }

    public func currentStreamingDecision() -> NetworkDecision { canStream() }
}

/// Reads local progress and admits a start or active-session baseline GET (#279/#281);
/// ``LocalProgressStore`` conforms.
public protocol LocalProgressReading: Sendable {
    func progress(for key: MediaKey) async throws -> LocalMediaProgressDTO?
    func captureStartProgress(for key: MediaKey) async throws -> PlaybackStartProgressCapture
    @discardableResult
    func applyStartProgress(_ progress: MediaProgress, captured: PlaybackStartProgressCapture) async throws -> Bool
}

extension LocalProgressStore: LocalProgressReading {}

/// The last item played on this device, restored paused at launch. Fields added after the first
/// release decode as absent, so older records still load.
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
    /// The media played to its end; the next play starts from the beginning.
    public var isFinished: Bool
    /// Display metadata for the restored, not yet loaded item. The cover is `coverPath` on
    /// `libraryItemID`.
    public var title: String?
    public var author: String?
    public var coverPath: String?
    public var chapterTitle: String?

    public init(
        serverConnectionID: UUID, libraryItemID: String, episodeID: String?, position: Double, duration: Double?,
        timestamp: Date, isFinished: Bool = false, title: String? = nil, author: String? = nil,
        coverPath: String? = nil, chapterTitle: String? = nil
    ) {
        self.serverConnectionID = serverConnectionID
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.position = position
        self.duration = duration
        self.timestamp = timestamp
        self.isFinished = isFinished
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.chapterTitle = chapterTitle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverConnectionID = try container.decode(UUID.self, forKey: .serverConnectionID)
        libraryItemID = try container.decode(String.self, forKey: .libraryItemID)
        episodeID = try container.decodeIfPresent(String.self, forKey: .episodeID)
        position = try container.decode(Double.self, forKey: .position)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isFinished = try container.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
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
