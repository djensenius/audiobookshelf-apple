import ABSAPI
import ABSCore
import ABSData
import Foundation
import Synchronization

/// ``PlaybackSessionService`` that plays downloaded media from this device and streams the rest
/// (ADR 0007, decision 7). A start:
///
/// - streams media with no completed download (``LocalPlaybackError/notDownloaded``);
/// - plays a completed download locally when every file it plays exists;
/// - otherwise throws ``LocalPlaybackError/downloadFilesMissing(_:)`` and contacts no server: a
///   download never falls back to streaming silently. The caller shows the error with a "Stream
///   instead" action, which calls ``streamInstead(_:)`` and starts again.
///
/// Any other local failure (a store error, cancellation) is thrown as is, never streamed: past the
/// download lookup the media may be downloaded.
///
/// Each later call goes to the service that owns the session. ``mediaProgress(itemID:episodeID:)``
/// always asks `remote`, even for downloaded media, so newer server progress still wins before a
/// local start; when it fails (for example offline), the error reaches the coordinator, which then
/// reads local progress itself rather than taking a cache for a server answer.
///
/// A forced transcode (the direct-play to HLS fallback after a decode or format error) always
/// streams: only the server transcodes.
public final class PreferringLocalSessionService: PlaybackSessionService {
    public let local: LocalPlaybackSessionService
    public let remote: any PlaybackSessionService
    /// The media whose next start streams although it is downloaded.
    private let streamingInstead = Mutex<Set<MediaKey>>([])

    /// `local` and `remote` must serve the same connection.
    public init(local: LocalPlaybackSessionService, remote: any PlaybackSessionService) {
        precondition(local.serverConnectionID == remote.serverConnectionID, "Services for different connections")
        self.local = local
        self.remote = remote
    }

    /// The user chose "Stream instead" for `key` after ``LocalPlaybackError/downloadFilesMissing(_:)``:
    /// its next start, and only that one, is a normal server session. A later start checks the
    /// download again.
    public func streamInstead(_ key: MediaKey) {
        _ = streamingInstead.withLock { $0.insert(key) }
    }

    public var serverConnectionID: UUID { remote.serverConnectionID }

    public func startSession(itemID: String, episodeID: String?, forceTranscode: Bool) async throws
        -> PlaybackSession
    {
        if forceTranscode {
            return try await remote.startSession(itemID: itemID, episodeID: episodeID, forceTranscode: true)
        }
        let key = MediaKey(serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        if streamingInstead.withLock({ $0.remove(key) != nil }) {
            return try await remote.startSession(itemID: itemID, episodeID: episodeID)
        }
        do {
            return try await local.startSession(itemID: itemID, episodeID: episodeID)
        } catch LocalPlaybackError.notDownloaded {
            return try await remote.startSession(itemID: itemID, episodeID: episodeID)
        }
    }

    /// Always `remote`'s answer or error, even for downloaded media: what the device cached from
    /// the server isn't a fetch, so offline the coordinator reads local progress itself.
    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await remote.mediaProgress(itemID: itemID, episodeID: episodeID)
    }

    public func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        if session.playMethod == .local { return try await local.resolveStream(for: session) }
        return try await remote.resolveStream(for: session)
    }

    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        if await local.owns(sessionID: id) { return try await local.closeSession(id: id, report: report) }
        try await remote.closeSession(id: id, report: report)
    }

    /// Only a streamed session has a token to refresh.
    public func refreshStreamAccess(replacing rejected: String?) async throws {
        try await remote.refreshStreamAccess(replacing: rejected)
    }

    public func sessionStatus(id: String) async -> PlaybackSessionStatus {
        await sessionCheck(id: id).status
    }

    public func sessionCheck(id: String) async -> PlaybackSessionCheck {
        if await local.owns(sessionID: id) { return await local.sessionCheck(id: id) }
        return await remote.sessionCheck(id: id)
    }
}
