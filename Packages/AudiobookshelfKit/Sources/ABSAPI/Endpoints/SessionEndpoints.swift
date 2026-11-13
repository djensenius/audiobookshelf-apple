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
public struct PlaybackSyncReport: Encodable, Sendable, Hashable {
    public let currentTime: Double
    public let timeListened: Double
    public let duration: Double

    /// Returns `nil` when `currentTime` is NaN, infinite or negative (for example
    /// `CMTime.invalid.seconds`): the server would rewind the item to 0 on every device, and the
    /// position never jumps back to 0 (ADR 0007), so the caller skips that report.
    ///
    /// A non-finite or negative `timeListened` or `duration` becomes `0`: `JSONEncoder` can't
    /// encode NaN or infinity, and an HLS item's duration is often indefinite.
    public init?(currentTime: Double, timeListened: Double, duration: Double) {
        guard currentTime.isFinite, currentTime >= 0 else { return nil }
        self.currentTime = currentTime
        self.timeListened = Self.clamped(timeListened)
        self.duration = Self.clamped(duration)
    }

    private static func clamped(_ value: Double) -> Double {
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
    /// `startTime` or `currentTime` is NaN, infinite or negative: uploading it would move the
    /// server's progress (ADR 0007: the position never jumps back to 0).
    case invalidPosition
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
    /// Sent with `/session/local`; ``LocalPlaybackSessionBatch`` drops it and sends one
    /// `deviceInfo` for the batch.
    public internal(set) var deviceInfo: DeviceInfo?

    /// A validated payload for `POST /api/session/local` or, in a ``LocalPlaybackSessionBatch``,
    /// `POST /api/session/local-all`. Throws for an invalid session, so callers can drop it
    /// before batching; a non-finite or negative duration or listening time is clamped to `0`.
    public init(session: PlaybackSession, deviceInfo: DeviceInfo) throws(LocalSessionPayloadError) {
        try Self.validate(deviceInfo)
        guard session.playMethod == .local else { throw .notLocal(session.playMethod) }
        guard UUID(uuidString: session.id) != nil else { throw .invalidID(session.id) }
        guard let startedAt = session.startedAt else { throw .missingStartedAt }
        guard Self.isValidPosition(session.startTime), Self.isValidPosition(session.currentTime) else {
            throw .invalidPosition
        }
        id = session.id
        libraryItemId = session.libraryItemId
        episodeId = session.episodeId
        mediaType = session.mediaType
        displayTitle = session.displayTitle
        displayAuthor = session.displayAuthor
        duration = Self.clamped(session.duration)
        playMethod = session.playMethod
        mediaPlayer = session.mediaPlayer ?? PlaybackStartRequest.avPlayer
        startTime = session.startTime
        currentTime = session.currentTime
        timeListening = Self.clamped(session.timeListening)
        self.startedAt = startedAt
        updatedAt = session.updatedAt ?? startedAt
        self.deviceInfo = deviceInfo
    }

    private static func isValidPosition(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    /// A non-finite or negative duration or listening time becomes `0`, as in
    /// ``PlaybackSyncReport``, so the payload always encodes.
    private static func clamped(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    static func validate(_ deviceInfo: DeviceInfo) throws(LocalSessionPayloadError) {
        guard let deviceID = deviceInfo.deviceId, !deviceID.isEmpty else { throw .missingDeviceID }
    }
}

/// The body of `POST /api/session/local-all`.
public struct LocalPlaybackSessionBatch: Encodable, Sendable, Hashable {
    public let sessions: [LocalPlaybackSessionPayload]
    public let deviceInfo: DeviceInfo

    /// Takes payloads that were each validated by their own init, so one invalid session never
    /// blocks the others; only `deviceInfo` is checked here.
    public init(sessions: [LocalPlaybackSessionPayload], deviceInfo: DeviceInfo) throws(LocalSessionPayloadError) {
        try LocalPlaybackSessionPayload.validate(deviceInfo)
        self.sessions = sessions.map { payload in
            var payload = payload
            payload.deviceInfo = nil
            return payload
        }
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

    /// `POST /api/session/local`: creates or updates one locally played session. Only redirects on
    /// the server's origin are followed (``Endpoint/staysOnOrigin``): a 307 or 308 elsewhere would
    /// re-post the session's title and position, and that origin's reply could be taken for the
    /// server's acknowledgement.
    public static func syncLocal(_ session: LocalPlaybackSessionPayload) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/api/session/local", body: session, staysOnOrigin: true)
    }

    /// `POST /api/session/local-all`: uploads unsent local sessions. Only redirects on the
    /// server's origin are followed, as for ``syncLocal(_:)``.
    public static func syncLocalAll(_ batch: LocalPlaybackSessionBatch) -> Endpoint<LocalSessionSyncResponse> {
        Endpoint(.post, "/api/session/local-all", body: batch, staysOnOrigin: true)
    }
}
