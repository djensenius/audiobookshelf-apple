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
///
/// A `/sync` the server answers with 404 reports its session to ``setSessionGoneHandler(_:)``'s
/// handler (#184): the server no longer has it, as after a restart.
public final class AccountPlaybackServices: PlaybackSessionService, ProgressSyncService, LocalSessionUploadService,
    Sendable
{
    /// Called with the ID of a session the server no longer has.
    public typealias SessionGoneHandler = @Sendable (_ sessionID: String) -> Void

    private struct State {
        var client: APIClient?
        var features: ServerFeatures?
        var isInvalidated = false
        var sessionGone: SessionGoneHandler?
    }

    public let serverConnectionID: UUID
    private let deviceIdentifiers: any DeviceIdentifying
    /// Rewrites each URL ``resolveStream(for:)`` returns; `nil` returns the server's.
    private let trackURLOverride: (@Sendable (URL) -> URL)?
    private let state: Mutex<State>

    public init(
        serverConnectionID: UUID, client: APIClient?, features: ServerFeatures?,
        deviceIdentifiers: any DeviceIdentifying, trackURLOverride: (@Sendable (URL) -> URL)? = nil
    ) {
        self.serverConnectionID = serverConnectionID
        self.deviceIdentifiers = deviceIdentifiers
        self.trackURLOverride = trackURLOverride
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
            state.sessionGone = nil
        }
    }

    /// Sets what's called, before the error is rethrown, when a `/sync` answers 404. Ignored after
    /// ``invalidate()``.
    public func setSessionGoneHandler(_ handler: SessionGoneHandler?) {
        state.withLock { state in
            guard !state.isInvalidated else { return }
            state.sessionGone = handler
        }
    }

    /// Whether a session-gone handler is set (tests).
    var hasSessionGoneHandler: Bool { state.withLock { $0.sessionGone != nil } }

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

    /// Throws ``StreamResolutionError/missingAccessToken`` without a client or features. The URLs
    /// go through the track URL override, if there is one; the plan and transport don't (the
    /// engine loads an overridden `file:` URL without the transport).
    public func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        guard let service = sessionService() else { throw StreamResolutionError.missingAccessToken }
        let stream = try await service.resolveStream(for: session)
        guard let trackURLOverride else { return stream }
        return ResolvedStream(
            plan: stream.plan, urls: stream.urls.map(trackURLOverride), transport: stream.transport,
            accessToken: stream.accessToken)
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

    /// A 404 means the server no longer has the session: the session-gone handler hears of it.
    public func syncSession(id: String, report: PlaybackSyncReport) async throws {
        do {
            try await APIProgressSyncService(serverConnectionID: serverConnectionID, client: client())
                .syncSession(id: id, report: report)
        } catch {
            if case .notFound = error as? APIError { state.withLock { $0.sessionGone }?(id) }
            throw error
        }
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

    // MARK: LocalSessionUploadService

    public func uploadAll(_ batch: LocalPlaybackSessionBatch) async throws -> LocalSessionSyncResponse {
        try await APILocalSessionUploadService(client: client()).uploadAll(batch)
    }

    public func upload(_ session: LocalPlaybackSessionPayload) async throws {
        try await APILocalSessionUploadService(client: client()).upload(session)
    }
}
