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
    public var currentTime: Double
    public var timeListened: Double
    public var duration: Double

    public init(currentTime: Double, timeListened: Double, duration: Double) {
        self.currentTime = currentTime
        self.timeListened = timeListened
        self.duration = duration
    }
}

/// A locally played session reported with `POST /api/session/local` or
/// `POST /api/session/local-all`. The server stores it under `id` (a UUID, so resends update
/// the same record) and replaces `userId`, `serverVersion`, and, for new sessions,
/// `deviceInfo` with its own values.
public struct LocalPlaybackSessionPayload: Encodable, Sendable, Hashable {
    public var id: String
    public var libraryItemId: String
    public var episodeId: String?
    public var mediaType: MediaType
    public var displayTitle: String?
    public var displayAuthor: String?
    public var duration: Double
    public var playMethod: PlayMethod
    public var mediaPlayer: String
    public var startTime: Double
    public var currentTime: Double
    public var timeListening: Double
    /// Epoch milliseconds.
    public var startedAt: Int?
    /// Epoch milliseconds. The server keeps its own progress when that is newer.
    public var updatedAt: Int?
    /// Sent with `/session/local`; `/session/local-all` sends one `deviceInfo` for the batch.
    public var deviceInfo: DeviceInfo?

    /// - Parameter includeDeviceInfo: `false` for sessions in a `/session/local-all` batch.
    public init(session: PlaybackSession, includeDeviceInfo: Bool) {
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
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        deviceInfo = includeDeviceInfo ? session.deviceInfo : nil
    }
}

/// The body of `POST /api/session/local-all`.
public struct LocalPlaybackSessionBatch: Encodable, Sendable, Hashable {
    public var sessions: [LocalPlaybackSessionPayload]
    public var deviceInfo: DeviceInfo?

    public init(sessions: [LocalPlaybackSessionPayload], deviceInfo: DeviceInfo?) {
        self.sessions = sessions
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

    /// `POST /api/session/:id/sync`.
    public static func sync(sessionID: String, report: PlaybackSyncReport) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/api/session/\(pathSegment(sessionID))/sync", body: report)
    }

    /// `POST /api/session/:id/close`, applying `report` first when given.
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
