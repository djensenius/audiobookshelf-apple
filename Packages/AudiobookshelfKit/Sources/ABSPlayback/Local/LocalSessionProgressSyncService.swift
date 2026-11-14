import ABSAPI
import ABSCore
import Foundation
import Synchronization

/// ``ProgressSyncService`` for a scope that plays downloads (ADR 0007, decision 7; #74): the
/// reports of a session ``local`` started stay on this device, everything else goes to `remote`.
///
/// No server has a local session, so its `/sync` would answer 404 and have the scope replace it
/// over and over. Instead its reports are saved for upload (``LocalPlaybackSessionService/syncSession(id:report:)``),
/// and a retried final close saves it as the coordinator's close does. Each save then calls the
/// ``setLocalSaveHandler(_:)`` handler: the scope uploads the connection's pending sessions, so
/// an online device reports while it plays (`POST /api/session/local`), and an offline one keeps
/// them for the next reconnect. Progress reads and PATCHes always go to `remote`: they're about
/// the media, not the session.
public final class LocalSessionProgressSyncService: ProgressSyncService {
    public let local: LocalPlaybackSessionService
    public let remote: any ProgressSyncService
    private let localSaved = Mutex<(@Sendable () -> Void)?>(nil)

    /// `local` and `remote` must serve the same connection.
    public init(local: LocalPlaybackSessionService, remote: any ProgressSyncService) {
        precondition(local.serverConnectionID == remote.serverConnectionID, "Services for different connections")
        self.local = local
        self.remote = remote
    }

    /// Sets what's called after each local session's report is saved.
    public func setLocalSaveHandler(_ handler: (@Sendable () -> Void)?) {
        localSaved.withLock { $0 = handler }
    }

    public var serverConnectionID: UUID { remote.serverConnectionID }

    public func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await remote.fetchProgress(itemID: itemID, episodeID: episodeID)
    }

    public func syncSession(id: String, report: PlaybackSyncReport) async throws {
        guard await local.owns(sessionID: id) else { return try await remote.syncSession(id: id, report: report) }
        try await local.syncSession(id: id, report: report)
        localSaved.withLock { $0 }?()
    }

    public func openSession(id: String) async throws -> PlaybackSession {
        try await remote.openSession(id: id)
    }

    public func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        try await remote.updateProgress(itemID: itemID, episodeID: episodeID, update)
    }

    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        guard await local.owns(sessionID: id) else { return try await remote.closeSession(id: id, report: report) }
        try await local.closeSession(id: id, report: report)
        localSaved.withLock { $0 }?()
    }

    public func listeningSessions(itemID: String, episodeID: String?) async throws -> ListeningSessionsPage {
        try await remote.listeningSessions(itemID: itemID, episodeID: episodeID)
    }
}
