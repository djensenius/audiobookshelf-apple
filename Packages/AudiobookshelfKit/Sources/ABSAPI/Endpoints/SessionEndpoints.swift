import ABSCore
import Foundation

/// The body of `POST /api/items/:id/play[/:episodeId]` (ADR 0007).
///
/// `forceDirectPlay` is always `false`: the server decides between direct play and HLS from
/// `supportedMimeTypes`. Set `forceTranscode` only for the direct-play to HLS fallback.
public struct PlaybackStartRequest: Encodable, Sendable, Hashable {
    /// The `mediaPlayer` value for sessions played with `AVPlayer`.
    public static let avPlayer = "AVPlayer"

    public var deviceInfo: DeviceInfo
    public var supportedMimeTypes: [String]
    public var mediaPlayer: String
    public let forceDirectPlay = false
    public var forceTranscode: Bool

    public init(
        deviceInfo: DeviceInfo, supportedMimeTypes: [String], mediaPlayer: String = Self.avPlayer,
        forceTranscode: Bool = false
    ) {
        self.deviceInfo = deviceInfo
        self.supportedMimeTypes = supportedMimeTypes
        self.mediaPlayer = mediaPlayer
        self.forceTranscode = forceTranscode
    }

    enum CodingKeys: String, CodingKey {
        case deviceInfo, supportedMimeTypes, mediaPlayer, forceDirectPlay, forceTranscode
    }
}

/// The body of `/api/session/:id/sync` and of a final `/api/session/:id/close`. The server adds
/// `timeListened` (wall-clock seconds since the last acknowledged report) to the session's total.
///
/// Non-finite or negative values become `0`: `JSONEncoder` can't encode NaN or infinity, and an
/// HLS item's duration is often indefinite.
public struct PlaybackSyncReport: Encodable, Sendable, Hashable {
    public let currentTime: Double
    public let timeListened: Double
    public let duration: Double

    public init(currentTime: Double, timeListened: Double, duration: Double) {
        self.currentTime = Self.sanitized(currentTime)
        self.timeListened = Self.sanitized(timeListened)
        self.duration = Self.sanitized(duration)
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}

/// Why a session can't be uploaded with `/api/session/local` or `/api/session/local-all`.
public enum LocalSessionPayloadError: Error, Sendable, Hashable {
    /// Only locally played sessions (`playMethod` 3) are uploaded.
    case notLocal(PlayMethod)
    /// The id must be a UUID so resends update the same server record (ADR 0007).
    case invalidID(String)
    /// The server compares `updatedAt` with its progress; without it, stale local progress would
    /// overwrite newer server progress.
    case missingStartedAt
    /// Without a `deviceId` the server creates a new device row for every upload.
    case missingDeviceID
}

/// A locally played session reported with `POST /api/session/local` or
/// `POST /api/session/local-all`. The server stores it under `id` (a UUID, so resends update
/// the same record) and replaces `userId`, `serverVersion`, and, for new sessions,
/// `deviceInfo` with its own values.
public struct LocalPlaybackSessionPayload: Encodable, Sendable, Hashable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let mediaType: MediaType
    public let displayTitle: String?
    public let displayAuthor: String?
    public let duration: Double
    public let playMethod: PlayMethod
    public let mediaPlayer: String
    public let startTime: Double
    public let currentTime: Double
    public let timeListening: Double
    /// Epoch milliseconds.
    public let startedAt: Int
    /// Epoch milliseconds; `startedAt` when the session was never updated. The server keeps its
    /// own progress when that is newer.
    public let updatedAt: Int
    /// Sent with `/session/local`; `/session/local-all` sends one `deviceInfo` for the batch.
    public let deviceInfo: DeviceInfo?

    /// A payload for `POST /api/session/local`.
    public init(session: PlaybackSession, deviceInfo: DeviceInfo) throws(LocalSessionPayloadError) {
        try Self.validate(deviceInfo)
        try self.init(validating: session, deviceInfo: deviceInfo)
    }

    init(validating session: PlaybackSession, deviceInfo: DeviceInfo?) throws(LocalSessionPayloadError) {
        guard session.playMethod == .local else { throw .notLocal(session.playMethod) }
        guard UUID(uuidString: session.id) != nil else { throw .invalidID(session.id) }
        guard let startedAt = session.startedAt else { throw .missingStartedAt }
        id = session.id
        libraryItemId = session.libraryItemId
        episodeId = session.episodeId
        mediaType = session.mediaType
        displayTitle = session.displayTitle
        displayAuthor = session.displayAuthor
        duration = session.duration
        playMethod = session.playMethod
        mediaPlayer = session.mediaPlayer ?? PlaybackStartRequest.avPlayer
        startTime = session.startTime
        currentTime = session.currentTime
        timeListening = session.timeListening
        self.startedAt = startedAt
        updatedAt = session.updatedAt ?? startedAt
        self.deviceInfo = deviceInfo
    }

    static func validate(_ deviceInfo: DeviceInfo) throws(LocalSessionPayloadError) {
        guard let deviceID = deviceInfo.deviceId, !deviceID.isEmpty else { throw .missingDeviceID }
    }
}

/// The body of `POST /api/session/local-all`.
public struct LocalPlaybackSessionBatch: Encodable, Sendable, Hashable {
    public let sessions: [LocalPlaybackSessionPayload]
    public let deviceInfo: DeviceInfo

    /// Validates every session like ``LocalPlaybackSessionPayload/init(session:deviceInfo:)``.
    public init(sessions: [PlaybackSession], deviceInfo: DeviceInfo) throws(LocalSessionPayloadError) {
        try LocalPlaybackSessionPayload.validate(deviceInfo)
        var payloads: [LocalPlaybackSessionPayload] = []
        for session in sessions {
            payloads.append(try LocalPlaybackSessionPayload(validating: session, deviceInfo: nil))
        }
        self.sessions = payloads
        self.deviceInfo = deviceInfo
    }
}

/// The response of `POST /api/session/local-all`: one result per uploaded session.
public struct LocalSessionSyncResponse: Decodable, Sendable, Hashable {
    public let results: [LocalSessionSyncResult]
}

public struct LocalSessionSyncResult: Decodable, Sendable, Hashable {
    /// The stored session id (a `play_local_` id is rewritten to a UUID).
    public let id: String
    public let success: Bool
    /// Whether the server updated the user's media progress from this session.
    public let progressSynced: Bool?
    public let error: String?
}

/// Playback session endpoints (ADR 0007).
public enum SessionEndpoints {
    /// `POST /api/items/:id/play[/:episodeId]`: opens a session. Starting a session closes this
    /// user's other open sessions with the same `deviceInfo.deviceId`.
    public static func start(
        itemID: String, episodeID: String? = nil, request: PlaybackStartRequest
    ) -> Endpoint<PlaybackSession> {
        var path = "/api/items/\(pathSegment(itemID))/play"
        if let episodeID { path += "/\(pathSegment(episodeID))" }
        return Endpoint(.post, path, body: request)
    }

    /// `GET /api/session/:id`: the open session with its live `timeListening`. A 404 means the
    /// session is no longer open on the server.
    public static func openSession(id: String) -> Endpoint<PlaybackSession> {
        Endpoint(.get, "/api/session/\(pathSegment(id))")
    }

    /// `POST /api/session/:id/sync`. Throws ``APIError/notFound`` when the session is no longer
    /// open on the server (restart, 36-hour idle, or a newer session from this device).
    public static func sync(sessionID: String, report: PlaybackSyncReport) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/api/session/\(pathSegment(sessionID))/sync", body: report)
    }

    /// `POST /api/session/:id/close`, applying `report` first when given. Throws
    /// ``APIError/notFound`` when the session is no longer open; a retried close that gets a 404
    /// may already have been applied (ADR 0007 reconciliation).
    public static func close(sessionID: String, report: PlaybackSyncReport? = nil) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/api/session/\(pathSegment(sessionID))/close", body: report)
    }

    /// `POST /api/session/local`: creates or updates one locally played session.
    public static func syncLocal(_ session: LocalPlaybackSessionPayload) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/api/session/local", body: session)
    }

    /// `POST /api/session/local-all`: uploads unsent local sessions.
    public static func syncLocalAll(_ batch: LocalPlaybackSessionBatch) -> Endpoint<LocalSessionSyncResponse> {
        Endpoint(.post, "/api/session/local-all", body: batch)
    }
}
