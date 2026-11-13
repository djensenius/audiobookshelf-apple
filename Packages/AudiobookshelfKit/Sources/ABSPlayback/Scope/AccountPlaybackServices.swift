import ABSAPI
import ABSCore
import Foundation
import Synchronization

/// One account's playback and progress-sync services, over a client and server features that can
/// be replaced while the playback scope lives (#183).
///
/// A playback scope keeps its coordinator, and the coordinator its services, for the whole account
/// session. A reconnect gives the account a new client (and, after a launch offline, its features),
/// which ``update(client:features:)`` swaps in without rebuilding the scope, so playback carries
/// on. With no client the server calls throw, and with no features no session starts, so a scope
/// can exist offline: it restores the last-played item, but can't stream.
///
/// Features are never invented: without the account's own (or its saved version's), no session
/// starts.
///
/// Every call reads its client and features once, under one lock, and awaits only that snapshot.
/// A request in flight across a reconnect finishes on the client it started with; the next uses
/// the new pair. ``invalidate()`` rejects later calls but can't retract a request under way. The
/// identity never changes here: a different account ends the scope.
public final class AccountPlaybackServices: PlaybackSessionService, ProgressSyncService, Sendable {
    private struct State {
        var client: APIClient?
        var features: ServerFeatures?
        var isInvalidated = false
    }

    public let serverConnectionID: UUID
    private let deviceIdentifiers: any DeviceIdentifying
    private let state: Mutex<State>

    public init(
        serverConnectionID: UUID, client: APIClient?, features: ServerFeatures?,
        deviceIdentifiers: any DeviceIdentifying
    ) {
        self.serverConnectionID = serverConnectionID
        self.deviceIdentifiers = deviceIdentifiers
        state = Mutex(State(client: client, features: features))
    }

    /// Replaces the client and features, after a reconnect. Ignored after ``invalidate()``.
    public func update(client: APIClient?, features: ServerFeatures?) {
        state.withLock { state in
            guard !state.isInvalidated else { return }
            state.client = client
            state.features = features
        }
    }

    /// Drops the client and features for good: every later server call throws. For an account
    /// that ends without network access (expiry, sign-out, removal).
    public func invalidate() {
        state.withLock { state in
            state.isInvalidated = true
            state.client = nil
            state.features = nil
        }
    }

    /// Whether ``startSession(itemID:episodeID:)`` can reach the server: there is a client and
    /// features, and the services weren't invalidated.
    public var canStartSessions: Bool {
        state.withLock { $0.client != nil && $0.features != nil }
    }

    /// The live session service for the current client and features, or `nil` without both.
    private func sessionService() -> APIPlaybackSessionService? {
        let (client, features) = state.withLock { ($0.client, $0.features) }
        guard let client, let features else { return nil }
        return APIPlaybackSessionService(
            serverConnectionID: serverConnectionID, client: client, features: features,
            deviceIdentifiers: deviceIdentifiers)
    }

    /// The current client; ``APIError/notAuthenticated`` without one.
    func client() throws -> APIClient {
        guard let client = state.withLock({ $0.client }) else { throw APIError.notAuthenticated }
        return client
    }

    // MARK: PlaybackSessionService

    /// Throws ``APIError/notAuthenticated`` without a client or features.
    public func startSession(itemID: String, episodeID: String?, forceTranscode: Bool) async throws
        -> PlaybackSession
    {
        guard let service = sessionService() else { throw APIError.notAuthenticated }
        return try await service.startSession(itemID: itemID, episodeID: episodeID, forceTranscode: forceTranscode)
    }

    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await client().mediaProgress(itemID: itemID, episodeID: episodeID)
    }

    /// Throws ``StreamResolutionError/missingAccessToken`` without a client or features.
    public func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        guard let service = sessionService() else { throw StreamResolutionError.missingAccessToken }
        return try await service.resolveStream(for: session)
    }

    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        _ = try await client().send(SessionEndpoints.close(sessionID: id, report: report))
    }

    /// Throws ``APIError/notAuthenticated`` without a client or features.
    public func refreshStreamAccess(replacing rejected: String?) async throws {
        guard let service = sessionService() else { throw APIError.notAuthenticated }
        try await service.refreshStreamAccess(replacing: rejected)
    }

    public func sessionStatus(id: String) async -> PlaybackSessionStatus {
        await sessionCheck(id: id).status
    }

    public func sessionCheck(id: String) async -> PlaybackSessionCheck {
        guard let client = try? client() else { return PlaybackSessionCheck(status: .unknown) }
        return await .lookUp(id: id, on: client)
    }

    // MARK: ProgressSyncService

    public func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await client().mediaProgress(itemID: itemID, episodeID: episodeID)
    }

    public func syncSession(id: String, report: PlaybackSyncReport) async throws {
        try await APIProgressSyncService(serverConnectionID: serverConnectionID, client: client())
            .syncSession(id: id, report: report)
    }

    public func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        try await APIProgressSyncService(serverConnectionID: serverConnectionID, client: client())
            .updateProgress(itemID: itemID, episodeID: episodeID, update)
    }

    public func openSession(id: String) async throws -> PlaybackSession {
        try await APIProgressSyncService(serverConnectionID: serverConnectionID, client: client())
            .openSession(id: id)
    }

    public func listeningSessions(itemID: String, episodeID: String?) async throws -> ListeningSessionsPage {
        try await APIProgressSyncService(serverConnectionID: serverConnectionID, client: client())
            .listeningSessions(itemID: itemID, episodeID: episodeID)
    }
}
