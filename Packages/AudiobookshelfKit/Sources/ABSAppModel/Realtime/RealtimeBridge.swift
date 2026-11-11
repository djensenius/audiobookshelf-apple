import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Observation

/// The socket's state, for the shell's connection indicator.
public enum RealtimeConnectionState: Sendable, Hashable {
    /// No session, offline, or stopped.
    case idle
    /// Opening the socket or authenticating.
    case connecting
    /// Authenticated: updates arrive.
    case connected
    /// The connection was lost; the socket reconnects with backoff.
    case disconnected
    /// The server rejected the token and refreshing it didn't help.
    case authFailed
}

/// What the player has open, for the "Jump to latest position" offer.
public struct RealtimePlaybackSnapshot: Sendable, Hashable {
    public var libraryItemID: String
    public var episodeID: String?
    /// This device's playback session, if any.
    public var playbackSessionID: String?
    public var isPlaying: Bool

    public init(libraryItemID: String, episodeID: String? = nil, playbackSessionID: String?, isPlaying: Bool) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.playbackSessionID = playbackSessionID
        self.isPlaying = isPlaying
    }
}

/// Keeps the session's progress in step with the server's socket.
///
/// A ``SessionStage/progressSource`` participant: on start it builds a socket from the session's
/// `APIClient` and reads its events in its own task until the session ends.
/// - `user_item_progress_updated` goes to the ``ProgressCache`` only when it is strictly newer
///   than the cached entry, so equal or older values, including echoes of this device's own
///   syncs, never regress it.
/// - `auth_failed` refreshes the rejected token once and reconnects with the new one; an
///   expired session stops the bridge.
/// - `user_updated` goes to ``onUserUpdated`` for the session's user. It never seeds the cache:
///   its progress list isn't known to be complete.
@MainActor
@Observable
public final class RealtimeBridge: SessionParticipant {
    public typealias SocketFactory = @MainActor (RealtimeConfiguration) throws -> any RealtimeConnecting
    public typealias TokenSourceFactory = @MainActor (APIClient) -> any RealtimeTokenSource

    public private(set) var connectionState = RealtimeConnectionState.idle

    /// The session's user changed on the server.
    @ObservationIgnored public var onUserUpdated: (@MainActor (User) -> Void)?
    /// Another session moved the item the paused player has open; see ``playbackSnapshot``.
    @ObservationIgnored public var onRemoteProgress: (@MainActor (UserItemProgressUpdate) -> Void)?
    /// What the player has open, or `nil` when nothing is.
    @ObservationIgnored public var playbackSnapshot: (@MainActor () -> RealtimePlaybackSnapshot?)?
    /// Called after each event is handled; for tests.
    @ObservationIgnored var didHandle: (@MainActor (RealtimeEvent) -> Void)?

    @ObservationIgnored private let progress: ProgressCache
    @ObservationIgnored private let makeSocket: SocketFactory
    @ObservationIgnored private let makeTokenSource: TokenSourceFactory

    /// Bumped on start and stop, so tasks of an earlier session do nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var client: APIClient?
    @ObservationIgnored private var tokens: (any RealtimeTokenSource)?
    @ObservationIgnored private var socket: (any RealtimeConnecting)?
    /// The token the socket was last given.
    @ObservationIgnored private var token: String?
    /// Rejected tokens already refreshed once.
    @ObservationIgnored private var refreshedTokens: Set<String?> = []
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private(set) var readerTask: Task<Void, Never>?
    @ObservationIgnored private(set) var tokenTask: Task<Void, Never>?

    public init(
        progress: ProgressCache,
        makeSocket: @escaping SocketFactory = { try SocketClient(configuration: $0) },
        makeTokenSource: @escaping TokenSourceFactory = { $0 }
    ) {
        self.progress = progress
        self.makeSocket = makeSocket
        self.makeTokenSource = makeTokenSource
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        let previous = detach()
        userID = context.identity.userID
        begin(context)
        await previous.socket?.disconnect()
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        guard !context.isOffline, let client = context.client else { return }
        guard let socket else {
            // Started offline, or still opening with the old client.
            startTask?.cancel()
            generation += 1
            begin(context)
            return
        }
        let tokens = makeTokenSource(client)
        self.client = client
        self.tokens = tokens
        tokenTask?.cancel()
        let generation = generation
        tokenTask = Task { [weak self] in
            guard let token = await tokens.currentAccessToken() else { return }
            guard let self, generation == self.generation, self.client === client else { return }
            guard token != self.token || self.connectionState != .connected else { return }
            self.token = token
            self.connectionState = .connecting
            await socket.updateToken(token)
        }
    }

    /// Stops reading before the first `await`, so no event is applied after this is called.
    public func sessionWillEnd(_ reason: SessionEndReason) async {
        let (socket, reader) = detach()
        userID = nil
        await reader?.value
        await socket?.disconnect()
    }

    /// Reconnects at once after a network change.
    public func networkChanged() async {
        await socket?.networkChanged()
    }

    // MARK: - Connection

    private func begin(_ context: SessionContext) {
        guard !context.isOffline, let client = context.client else {
            connectionState = .idle
            return
        }
        generation += 1
        let generation = generation
        let tokens = makeTokenSource(client)
        self.client = client
        self.tokens = tokens
        connectionState = .connecting
        startTask = Task { [weak self] in
            let configuration = await client.configuration
            let token = await tokens.currentAccessToken()
            await self?.open(configuration: configuration, token: token, generation: generation)
        }
    }

    private func open(configuration: APIClientConfiguration, token: String?, generation: Int) async {
        guard generation == self.generation, !Task.isCancelled else { return }
        let socket: any RealtimeConnecting
        do {
            socket = try makeSocket(
                RealtimeConfiguration(
                    serverAddress: configuration.baseURL, token: token, customHeaders: configuration.customHeaders))
        } catch {
            Log.realtime.error("Couldn't create the socket: \(String(describing: error), privacy: .public)")
            connectionState = .idle
            return
        }
        self.socket = socket
        self.token = token
        readerTask = Task { [weak self] in
            for await event in socket.events {
                // Checked after every resumption: the session may have ended while it waited.
                guard let self, generation == self.generation else { return }
                self.handle(event)
            }
        }
        await socket.connect()
        // The session may have ended while connecting, and its disconnect run first.
        if generation != self.generation { await socket.disconnect() }
    }

    /// Stops every task and forgets the session synchronously. Returns the socket to disconnect
    /// and the reader to wait for.
    private func detach() -> (socket: (any RealtimeConnecting)?, reader: Task<Void, Never>?) {
        generation += 1
        startTask?.cancel()
        startTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        let reader = readerTask
        reader?.cancel()
        readerTask = nil
        let socket = self.socket
        self.socket = nil
        client = nil
        tokens = nil
        token = nil
        refreshedTokens = []
        connectionState = .idle
        return (socket, reader)
    }

    // MARK: - Events

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .connected:
            // The namespace is open; authenticating.
            connectionState = .connecting
        case .initialized:
            connectionState = .connected
        case .disconnected(let reason):
            switch reason {
            case .clientRequested, .authFailed: break
            case .networkChanged, .tokenUpdated: connectionState = .connecting
            default: connectionState = .disconnected
            }
        case .authFailed:
            authFailed()
        case .userUpdated(let user):
            if user.id == userID { onUserUpdated?(user) }
        case .userItemProgressUpdated(let update):
            apply(update)
        case .playlistAdded:
            break
        }
        didHandle?(event)
    }

    private func apply(_ update: UserItemProgressUpdate) {
        let incoming = update.progress
        let cached = progress.progress(libraryItemID: incoming.libraryItemId, episodeID: incoming.episodeId)
        guard Self.supersedes(incoming, cached), progress.apply(incoming) else { return }
        guard let onRemoteProgress, let snapshot = playbackSnapshot?(), Self.offersJump(update, to: snapshot) else {
            return
        }
        onRemoteProgress(update)
    }

    /// Refreshes the rejected token once, then reconnects with the new one.
    private func authFailed() {
        connectionState = .authFailed
        guard let tokens, let socket else { return }
        let rejected = token
        guard refreshedTokens.insert(rejected).inserted else {
            Log.realtime.error("The socket rejected a refreshed token")
            return
        }
        tokenTask?.cancel()
        let generation = generation
        tokenTask = Task { [weak self] in
            do {
                let fresh = try await tokens.accessToken(replacing: rejected)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.token = fresh
                self.connectionState = .connecting
                await socket.updateToken(fresh)
            } catch APIError.sessionExpired, APIError.notAuthenticated {
                guard let self, generation == self.generation else { return }
                Log.realtime.notice("The session expired; stopping the socket")
                let (socket, reader) = self.detach()
                await reader?.value
                await socket?.disconnect()
            } catch {
                Log.realtime.error(
                    "Couldn't refresh the socket's token: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether `incoming` is strictly newer than `cached`. Server progress is always dated, so an
    /// undated value never replaces cached progress.
    private static func supersedes(_ incoming: MediaProgress, _ cached: MediaProgress?) -> Bool {
        guard let cached else { return true }
        switch (incoming.lastUpdate, cached.lastUpdate) {
        case (let incoming?, let cached?): return incoming > cached
        case (.some, nil): return true
        case (nil, _): return false
        }
    }

    /// The legacy app's rule (`layouts/default.vue`): the paused player has the item open, and
    /// the update comes from another playback session.
    private static func offersJump(_ update: UserItemProgressUpdate, to snapshot: RealtimePlaybackSnapshot) -> Bool {
        !snapshot.isPlaying && snapshot.libraryItemID == update.progress.libraryItemId
            && snapshot.episodeID == update.progress.episodeId && update.sessionId != snapshot.playbackSessionID
    }
}
