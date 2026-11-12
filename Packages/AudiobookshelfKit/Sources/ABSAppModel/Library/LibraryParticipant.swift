import ABSAPI
import ABSCore
import Foundation

/// Connects the shared ``LibraryStore`` to the session (S7a): the lifecycle's seeder
/// (``SessionLifecycle/register(seeder:)``), so it starts first and ends last.
///
/// - Start attaches the session's client and account, and the login's default library, then
///   refreshes the libraries in a task the participant owns, so the hook returns promptly.
/// - The seed boundary is ``ProgressCache/beginSeed()``; the seed fetches `GET /api/me`
///   (``UserEndpoints/progress()``) with the client of the seed's context and seeds the cache
///   with its full list. Nothing else ever seeds it. A seed whose session ended, reconnected
///   or reseeded since its boundary is dropped by the participant's generation and the token,
///   not only by cancellation. An offline session or one without a client doesn't seed; its
///   reconnect does.
/// - A reconnect attaches the new client from its context, keeping the account's data, and
///   refreshes again.
/// - End cancels the refresh and clears the store synchronously, so the clear always runs,
///   even once the teardown's deadline passed.
///
/// A partial pipeline is fine: start without a boundary or seed leaves the cache unseeded, and
/// end without a start does nothing but clear.
@MainActor
public final class LibraryParticipant: SessionSeeding {
    /// Fetches the user's full progress list (`GET /api/me`) through a client.
    public typealias FetchProgress = @Sendable (APIClient) async throws -> [MediaProgress]

    public let store: LibraryStore
    private let defaultLibraryID: @MainActor () -> String?
    private let service: @MainActor (APIClient) -> any LibraryService
    private let fetchProgress: FetchProgress

    /// The running session, between start and end.
    private var sessionID: UInt64?
    /// Bumped by every start, boundary and end, so a seed begun before one of them is dropped.
    private var generation = 0
    private var seedToken: ProgressCache.SeedToken?
    private var refreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - defaultLibraryID: the signed-in user's default library from login
    ///     (`AuthResponse.userDefaultLibraryId`), read at start and reconnect.
    ///   - service: the library service for a session's client; the client itself in the app.
    ///   - fetchProgress: the `/api/me` request; tests replace it.
    public init(
        store: LibraryStore, defaultLibraryID: @escaping @MainActor () -> String? = { nil },
        service: @escaping @MainActor (APIClient) -> any LibraryService = { $0 },
        fetchProgress: @escaping FetchProgress = { try await $0.send(UserEndpoints.progress()).mediaProgress }
    ) {
        self.store = store
        self.defaultLibraryID = defaultLibraryID
        self.service = service
        self.fetchProgress = fetchProgress
    }

    // MARK: SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        generation += 1
        sessionID = context.sessionID
        seedToken = nil
        attach(context)
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        guard sessionID == context.sessionID else { return }
        attach(context)
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        // All synchronous: it must run even when the lifecycle cancels the rest of the teardown.
        generation += 1
        sessionID = nil
        seedToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        store.clear()
    }

    // MARK: SessionSeeding

    public func beginSeed(_ context: SessionContext) async {
        guard sessionID == context.sessionID else { return }
        generation += 1
        seedToken = store.progress.beginSeed()
    }

    public func seed(_ context: SessionContext) async {
        guard sessionID == context.sessionID, let token = seedToken, let client = context.client,
            !context.isOffline
        else { return }
        let generation = generation
        let progress: [MediaProgress]
        do {
            progress = try await fetchProgress(client)
        } catch {
            if !(error is CancellationError) {
                Log.api.error("Couldn't load the progress to seed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        // The session ended, reconnected or reseeded while the request ran.
        guard !Task.isCancelled, generation == self.generation, sessionID == context.sessionID,
            seedToken == token
        else { return }
        store.progress.seed(progress, token: token)
    }

    // MARK: Progress

    /// Where a progress source of `context`'s session (playback, the syncer, the socket)
    /// applies progress: the store's ``ProgressCache/apply(_:)`` while that session runs. Once
    /// it ended the sink drops everything and returns `false`, so a late write can't land in the
    /// next account's cache.
    public func progressSink(for context: SessionContext) -> @MainActor (MediaProgress) -> Bool {
        let sessionID = context.sessionID
        return { [weak self] progress in
            guard let self, self.sessionID == sessionID else { return false }
            return self.store.progress.apply(progress)
        }
    }

    // MARK: Private

    private func attach(_ context: SessionContext) {
        let key = LibraryConnectionKey(connectionID: context.identity.connectionID, userID: context.identity.userID)
        store.attach(
            client: context.client.map(service), connectionKey: key, defaultLibraryID: defaultLibraryID())
        refreshTask?.cancel()
        refreshTask = nil
        guard context.client != nil, !context.isOffline else { return }
        let store = store
        refreshTask = Task { await store.refresh() }
    }
}
