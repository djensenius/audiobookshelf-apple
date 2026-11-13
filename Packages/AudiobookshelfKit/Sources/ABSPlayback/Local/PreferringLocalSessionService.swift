import ABSAPI
import ABSCore
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "PreferringLocalSessionService")

/// ``PlaybackSessionService`` that plays downloaded media from this device and streams the rest
/// (ADR 0007, decision 7): a start goes to `local` when every file of a completed download of the
/// media exists, and to `remote` otherwise, including when a file is missing. Each later call goes
/// to the service that owns the session.
///
/// ``mediaProgress(itemID:episodeID:)`` asks `remote` first even for downloaded media, so newer
/// server progress still wins before a local start; when it fails (for example offline), downloaded
/// media gets the progress this device last saw from the server.
public struct PreferringLocalSessionService: PlaybackSessionService {
    public let local: LocalPlaybackSessionService
    public let remote: any PlaybackSessionService

    /// `local` and `remote` must serve the same connection.
    public init(local: LocalPlaybackSessionService, remote: any PlaybackSessionService) {
        precondition(local.serverConnectionID == remote.serverConnectionID, "Services for different connections")
        self.local = local
        self.remote = remote
    }

    public var serverConnectionID: UUID { remote.serverConnectionID }

    public func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        do {
            return try await local.startSession(itemID: itemID, episodeID: episodeID)
        } catch LocalPlaybackError.notDownloaded {
            return try await remote.startSession(itemID: itemID, episodeID: episodeID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Local session failed to start, streaming instead: \(String(describing: error))")
            return try await remote.startSession(itemID: itemID, episodeID: episodeID)
        }
    }

    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        do {
            return try await remote.mediaProgress(itemID: itemID, episodeID: episodeID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard (try? await local.playableItem(itemID: itemID, episodeID: episodeID)) != nil else { throw error }
            return try await local.mediaProgress(itemID: itemID, episodeID: episodeID)
        }
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
