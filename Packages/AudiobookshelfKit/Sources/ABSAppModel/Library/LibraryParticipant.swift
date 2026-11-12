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
///   with its full list. Nothing else ever seeds it. When rows couldn't be decoded the list is
///   incomplete, and seeding it would remove their progress, so the cache is kept as it is.
///   A transient failure (offline, timeout, 408, 429, 5xx) is retried within the seed after a
///   short backoff (2, 5 and 10 seconds), so a flaky sign-in still seeds the cache this session.
///   A seed whose session ended, reconnected or reseeded since its boundary is dropped by the
///   participant's generation and the token, not only by cancellation. An offline session or
///   one without a client doesn't seed; its reconnect does.
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
    public typealias FetchProgress = @Sendable (APIClient) async throws -> UserProgressResponse
    /// Waits out a retry's backoff; throws when cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The backoff before each retry of a transient seed failure.
    public static let defaultRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]

    public let store: LibraryStore
    private let defaultLibraryID: @MainActor () -> String?
    private let service: @MainActor (APIClient) -> any LibraryService
    private let fetchProgress: FetchProgress
    private let retryDelays: [Duration]
    private let sleep: Sleep

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
    ///   - retryDelays: the backoff before each retry of a transient seed failure; its count is
    ///     the number of retries.
    ///   - sleep: waits out a backoff; tests replace it so they don't wait.
    public init(
        store: LibraryStore, defaultLibraryID: @escaping @MainActor () -> String? = { nil },
        service: @escaping @MainActor (APIClient) -> any LibraryService = { $0 },
        fetchProgress: @escaping FetchProgress = { try await $0.send(UserEndpoints.progress()) },
        retryDelays: [Duration] = LibraryParticipant.defaultRetryDelays,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.defaultLibraryID = defaultLibraryID
        self.service = service
        self.fetchProgress = fetchProgress
        self.retryDelays = retryDelays
        self.sleep = sleep
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
        var retries = retryDelays[...]
        while true {
            do {
                let response = try await fetchProgress(client)
                // The session ended, reconnected or reseeded while the request ran.
                guard isCurrent(generation, context, token) else { return }
                guard response.skippedRows == 0 else {
                    // An incomplete list would remove the skipped rows' progress as if the
                    // server had deleted it.
                    Log.api.error(
                        "Skipped \(response.skippedRows, privacy: .public) malformed progress rows; keeping the cache"
                    )
                    return
                }
                store.progress.seed(response.mediaProgress, token: token)
                return
            } catch let error as APIError where error.isTransient && !retries.isEmpty {
                Log.api.info(
                    "Retrying the progress seed after: \(Log.redact(String(describing: error)), privacy: .public)")
                do { try await sleep(retries.removeFirst()) } catch { return }
                guard isCurrent(generation, context, token) else { return }
            } catch {
                if !(error is CancellationError) {
                    Log.api.error(
                        "Couldn't load the progress to seed: \(Log.redact(String(describing: error)), privacy: .public)"
                    )
                }
                return
            }
        }
    }

    // MARK: Private

    /// Whether a seed begun at `generation` with `token` still belongs to the running session:
    /// not cancelled, and no end, reconnect or new boundary since.
    private func isCurrent(_ generation: Int, _ context: SessionContext, _ token: ProgressCache.SeedToken) -> Bool {
        !Task.isCancelled && generation == self.generation && sessionID == context.sessionID && seedToken == token
    }

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
