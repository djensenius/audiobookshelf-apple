import ABSAPI
import ABSCore
import ABSData
import ABSRealtime
import Foundation
import Observation

/// The socket's state, for the shell's connection indicator.
public enum RealtimeConnectionState: Sendable, Hashable {
    /// No session, offline, no token, or stopped.
    case idle
    /// Opening the socket or authenticating. `SocketClient` reports nothing when a connection
    /// fails before the namespace is accepted, so the state stays here while it retries.
    case connecting
    /// Authenticated: updates arrive.
    case connected
    /// The connection was lost; the socket reconnects with backoff.
    case disconnected
    /// The server rejected the token, and refreshing it failed or didn't help.
    case authFailed
}

/// What the player has open, for echo detection and the "Jump to latest position" offer.
public struct RealtimePlaybackSnapshot: Sendable, Hashable {
    public var libraryItemID: String
    public var episodeID: String?
    /// This device's playback session, if any.
    public var playbackSessionID: String?
    public var isPlaying: Bool
    /// The player's position, in seconds.
    public var currentTime: Double

    public init(
        libraryItemID: String, episodeID: String? = nil, playbackSessionID: String?, isPlaying: Bool,
        currentTime: Double
    ) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.playbackSessionID = playbackSessionID
        self.isPlaying = isPlaying
        self.currentTime = currentTime
    }
}

/// Keeps the session's progress in step with the server's socket.
///
/// A ``SessionStage/progressSource`` participant: on start it builds a socket from the session's
/// `APIClient` and reads its events in its own task until the session ends.
/// - `user_item_progress_updated` goes to the ``ProgressCache`` only when it is strictly newer
///   than the cached entry (server times are milliseconds, so a tie may predate the cached
///   value; see ADR 0003). An update from this device's own playback session for the item the
///   player has open is its echo and is skipped, whatever its time (the cached value may carry a
///   device-clock time the server's can't be compared with), unless it changes the finished flag.
/// - `auth_failed` refreshes the rejected token and reconnects with the new one: at most once per
///   token, and once until the socket authenticates again. After that, or after a failed
///   refresh, the next ``networkChanged()`` or reconnect retries, with any token. An expired
///   session, or a reconnect without a usable token, closes the socket without a farewell.
/// - `user_updated` goes to ``onUserUpdated`` for the session's user. It never seeds the cache:
///   its progress list isn't known to be complete.
/// - `author_added`, `author_updated` and `author_removed` go to ``onLibraryChange`` with the
///   session's account.
/// - `rss_feed_open` and `rss_feed_closed` go to ``onRssFeedChange``.
///
/// Every dated progress update other than such an echo is also merged into ``localProgress``
/// with ADR 0003's `.socket` source, whether or not the cache took it: the store keeps its own
/// ordering, and only rows it already has (downloaded or locally played media) take the value.
@MainActor
@Observable
public final class RealtimeBridge: SessionParticipant {
    public typealias SocketFactory = @MainActor (RealtimeConfiguration) throws -> any RealtimeConnecting
    public typealias TokenSourceFactory = @MainActor (APIClient) -> any RealtimeTokenSource

    public private(set) var connectionState = RealtimeConnectionState.idle

    /// The session's user changed on the server.
    @ObservationIgnored public var onUserUpdated: (@MainActor (User) -> Void)?
    /// A library's entity changed on the server; with the account of the session it came from,
    /// for ``LibraryStore/applyLibraryChange(_:connectionKey:)``. Nothing arrives after the
    /// session ends.
    @ObservationIgnored public var onLibraryChange: (@MainActor (LibraryChange, LibraryConnectionKey) -> Void)?
    /// An RSS feed was opened or closed on the session's server, for ``RssFeedModel/apply(_:)``.
    /// Nothing arrives after the session ends.
    @ObservationIgnored public var onRssFeedChange: (@MainActor (RssFeedChange) -> Void)?
    /// Offers a jump to another session's position, as the legacy app did: the player has the
    /// item open and is paused, and the update comes from another playback session (whether or
    /// not the cache took it). It must also not be older than the cached progress (if as old, at
    /// its position), and its position must differ from the player's by at least a second.
    @ObservationIgnored public var onRemoteProgress: (@MainActor (UserItemProgressUpdate) -> Void)?
    /// What the player has open, or `nil` when nothing is.
    @ObservationIgnored public var playbackSnapshot: (@MainActor () -> RealtimePlaybackSnapshot?)?
    /// Where socket progress is merged for media with a local row; `nil` merges nothing.
    @ObservationIgnored public var localProgress: LocalProgressStore?
    /// Called after each event is handled; for tests.
    @ObservationIgnored var didHandle: (@MainActor (RealtimeEvent) -> Void)?
    /// Called as the bridge stops, before anything is cancelled; for tests.
    @ObservationIgnored var willDetach: (@MainActor () -> Void)?

    @ObservationIgnored private let progress: ProgressCache
    @ObservationIgnored private let makeSocket: SocketFactory
    @ObservationIgnored private let makeTokenSource: TokenSourceFactory

    /// Bumped on start and stop, so tasks of an earlier session do nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var identity: SessionIdentity?
    @ObservationIgnored private var client: APIClient?
    @ObservationIgnored private var tokens: (any RealtimeTokenSource)?
    @ObservationIgnored private var socket: (any RealtimeConnecting)?
    /// The token the socket was last given.
    @ObservationIgnored private var token: String?
    /// Rejected tokens a refresh already replaced; they aren't refreshed again.
    @ObservationIgnored private var refreshedTokens: Set<String?> = []
    /// A refresh succeeded since the socket last authenticated. Further rejections then wait for
    /// a network change or reconnect, so a server that rejects every token can't make the bridge
    /// rotate tokens in a loop.
    @ObservationIgnored private var refreshedSinceInitialized = false
    /// The refresh in flight; cleared when a reconnect or stop supersedes it.
    @ObservationIgnored private var refreshing: Int?
    @ObservationIgnored private var nextRefreshID = 0
    @ObservationIgnored private(set) var startTask: Task<Void, Never>?
    @ObservationIgnored private(set) var readerTask: Task<Void, Never>?
    @ObservationIgnored private(set) var tokenTask: Task<Void, Never>?
    /// The latest merge into ``localProgress``; each waits for the one before it.
    @ObservationIgnored private(set) var mergeTask: Task<Void, Never>?

    public init(
        progress: ProgressCache,
        makeSocket: @escaping SocketFactory = {
            // Each session's socket gets its own cookie jar.
            try SocketClient(configuration: $0, transport: URLSessionWebSocketTransport.isolated())
        },
        makeTokenSource: @escaping TokenSourceFactory = { $0 }
    ) {
        self.progress = progress
        self.makeSocket = makeSocket
        self.makeTokenSource = makeTokenSource
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        let previous = detach()
        identity = context.identity
        begin(context)
        await previous.socket?.disconnect(sendingFarewell: true)
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        guard !context.isOffline, let client = context.client else { return }
        guard let socket else {
            // Started offline or without a token, or still opening with the old client.
            startTask?.cancel()
            begin(context)
            return
        }
        let tokens = makeTokenSource(client)
        self.client = client
        self.tokens = tokens
        refreshing = nil
        // An explicit recovery point: every token may be refreshed again.
        refreshedSinceInitialized = false
        refreshedTokens = []
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            let token = await Self.usableToken(from: tokens)
            guard let self, !Task.isCancelled, self.client === client else { return }
            guard let token else {
                // The session ended, or its token expired: the socket mustn't keep the old one.
                Log.realtime.notice("No usable token after a reconnect; closing the socket")
                let (socket, reader) = self.detach()
                await reader?.value
                await socket?.disconnect(sendingFarewell: false)
                return
            }
            guard token != self.token || self.connectionState != .connected else { return }
            self.token = token
            self.connectionState = .connecting
            await socket.updateToken(token)
        }
    }

    /// Stops reading before the first `await`, so no event is applied after this is called.
    /// With ``SessionEndReason/expired`` the socket is closed without a farewell.
    public func sessionWillEnd(_ reason: SessionEndReason) async {
        let (socket, reader) = detach()
        identity = nil
        await reader?.value
        await socket?.disconnect(sendingFarewell: reason != .expired)
    }

    /// Reconnects at once after a network change. While the socket's token is rejected (the
    /// socket then ignores network changes), it instead refreshes the token again, once per call,
    /// even one already refreshed, and reconnects with the result.
    public func networkChanged() async {
        if connectionState == .authFailed {
            refreshedSinceInitialized = false
            refreshedTokens = []
            if refreshRejectedToken() {
                Log.realtime.notice("Retrying the socket's token refresh after a network change")
                return
            }
        }
        await socket?.networkChanged()
    }

    // MARK: - Connection

    private func begin(_ context: SessionContext) {
        generation += 1
        guard !context.isOffline, let client = context.client else {
            connectionState = .idle
            return
        }
        let generation = generation
        let tokens = makeTokenSource(client)
        self.client = client
        self.tokens = tokens
        connectionState = .connecting
        startTask = Task { [weak self] in
            let configuration = await client.configuration
            let token = await Self.usableToken(from: tokens)
            await self?.open(configuration: configuration, token: token, generation: generation)
        }
    }

    private func open(configuration: APIClientConfiguration, token: String?, generation: Int) async {
        guard generation == self.generation, !Task.isCancelled else { return }
        guard let token else {
            // A reconnect with a token opens the socket.
            connectionState = .idle
            return
        }
        let socket: any RealtimeConnecting
        do {
            socket = try makeSocket(
                RealtimeConfiguration(
                    serverAddress: configuration.baseURL, token: token, customHeaders: configuration.customHeaders))
        } catch {
            Log.realtime.error(
                "Couldn't create the socket: \(Self.logSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
            )
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
        if generation != self.generation { await socket.disconnect(sendingFarewell: false) }
    }

    /// Stops every task and forgets the session synchronously. Returns the socket to disconnect
    /// and the reader to wait for.
    private func detach() -> (socket: (any RealtimeConnecting)?, reader: Task<Void, Never>?) {
        willDetach?()
        generation += 1
        startTask?.cancel()
        startTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        refreshing = nil
        refreshedSinceInitialized = false
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

    /// The token to connect with, refreshed first if it is about to expire; `nil` when there is
    /// none, the session ended, or it expired and couldn't be refreshed. (`APIClient` itself
    /// returns the stored token after a transient refresh failure while it is still valid.)
    private static func usableToken(from tokens: any RealtimeTokenSource) async -> String? {
        do {
            return try await tokens.accessToken(replacing: nil)
        } catch let error where endsSession(error) || error is CancellationError {
            return nil
        } catch {
            Log.realtime.notice(
                "Couldn't refresh the socket's token: \(Self.logSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
            )
            return nil
        }
    }

    // MARK: - Events

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .connected:
            // The namespace is open; authenticating.
            connectionState = .connecting
        case .initialized:
            connectionState = .connected
            refreshedSinceInitialized = false
        case .disconnected(let reason):
            switch reason {
            case .clientRequested, .authFailed: break
            case .networkChanged, .tokenUpdated: connectionState = .connecting
            default: connectionState = .disconnected
            }
        case .authFailed:
            connectionState = .authFailed
            if !refreshRejectedToken(), refreshing == nil {
                Log.realtime.error("The socket rejected a refreshed token; waiting for a network change")
            }
        case .userUpdated(let user):
            if user.id == identity?.userID { onUserUpdated?(user) }
        case .userItemProgressUpdated(let update):
            apply(update)
        case .collectionChanged(let change):
            deliver(.collection(change))
        case .playlistChanged(let change, let userID):
            deliver(.playlist(change, userID: userID))
        case .authorChanged(let change):
            deliver(.author(change))
        case .rssFeedChanged(let change):
            onRssFeedChange?(change)
        }
        didHandle?(event)
    }

    private func deliver(_ change: LibraryChange) {
        guard let identity else { return }
        onLibraryChange?(change, LibraryConnectionKey(connectionID: identity.connectionID, userID: identity.userID))
    }

    private func apply(_ update: UserItemProgressUpdate) {
        let incoming = update.progress
        let snapshot = playbackSnapshot?()
        let isOpen =
            snapshot.map { $0.libraryItemID == incoming.libraryItemId && $0.episodeID == incoming.episodeId } ?? false
        let cached = progress.progress(libraryItemID: incoming.libraryItemId, episodeID: incoming.episodeId)
        // An echo of this device's own playback sync. Its position is skipped, but a change of the
        // finished flag (the server's auto-finish) still goes through the usual newer-wins check;
        // if the device's clock ran ahead it is dropped there, and the progress syncer reconciles.
        if isOpen, let own = snapshot?.playbackSessionID, update.sessionId == own,
            cached == nil || cached?.isFinished == incoming.isFinished
        {
            return
        }
        merge(incoming)
        if Self.supersedes(incoming, cached) { progress.apply(incoming) }
        if isOpen, let snapshot, let onRemoteProgress, Self.offersJump(update, to: snapshot, cached: cached) {
            onRemoteProgress(update)
        }
    }

    /// Merges dated `progress` into ``localProgress`` as a `.socket` value, after the merges before
    /// it. A merge still waiting when the session ends is dropped.
    private func merge(_ progress: MediaProgress) {
        guard let store = localProgress, let identity, let lastUpdate = progress.lastUpdate else { return }
        let key = MediaKey(
            serverConnectionID: identity.connectionID, libraryItemId: progress.libraryItemId,
            episodeId: progress.episodeId)
        let server = ProgressBaseline(
            currentTime: progress.currentTime, progress: progress.progress, duration: progress.duration,
            isFinished: progress.isFinished,
            finishedAt: progress.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(lastUpdate) / 1000))
        let generation = generation
        let previous = mergeTask
        mergeTask = Task { [weak self] in
            let capturedAt = await store.captureGeneration()
            await previous?.value
            guard let self, generation == self.generation else { return }
            do {
                try await store.applyServerProgress([key: server], capturedAt: capturedAt, source: .socket)
            } catch {
                Log.realtime.error(
                    "Couldn't merge socket progress: \(Self.logSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
                )
            }
        }
    }

    /// Refreshes the socket's rejected token, unless a refresh is running, one already succeeded
    /// since the socket last authenticated, or one already replaced this token. Returns whether
    /// it started one.
    @discardableResult
    private func refreshRejectedToken() -> Bool {
        guard let tokens, let socket, refreshing == nil, !refreshedSinceInitialized else { return false }
        let rejected = token
        guard !refreshedTokens.contains(rejected) else { return false }
        nextRefreshID += 1
        let id = nextRefreshID
        refreshing = id
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            let result: Result<String, any Error>
            do {
                result = .success(try await tokens.accessToken(replacing: rejected))
            } catch {
                result = .failure(error)
            }
            await self?.finishRefresh(result, rejected: rejected, id: id, socket: socket)
        }
        return true
    }

    private func finishRefresh(
        _ result: Result<String, any Error>, rejected: String?, id: Int, socket: any RealtimeConnecting
    ) async {
        // A reconnect or stop since then cleared `refreshing`.
        guard refreshing == id, !Task.isCancelled else { return }
        refreshing = nil
        switch result {
        case .success(let fresh):
            refreshedTokens.insert(rejected)
            refreshedSinceInitialized = true
            token = fresh
            connectionState = .connecting
            await socket.updateToken(fresh)
        case .failure(let error) where Self.endsSession(error):
            Log.realtime.notice("The session expired; stopping the socket")
            let (socket, reader) = detach()
            await reader?.value
            await socket?.disconnect(sendingFarewell: false)
        case .failure(let error):
            // Not recorded, so the next auth failure, network change or reconnect retries.
            if !(error is CancellationError) {
                Log.realtime.error(
                    "Couldn't refresh the socket's token: \(Self.logSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
                )
            }
        }
    }

    /// What may be logged publicly about `error`: its case and status code, never a message or
    /// decoder text, which can quote the server's response (as `ServerValidatorError`'s
    /// `diagnosticDescription` does).
    static func logSummary(of error: any Error) -> String {
        switch error as? APIError {
        case .http(let status, _): "http(status: \(status))"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .encoding: "encoding"
        case .decoding: "decoding"
        case let error?: String(describing: error)
        case nil: String(describing: type(of: error))
        }
    }

    private static func endsSession(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .sessionExpired, .notAuthenticated: true
        default: false
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

    /// How far apart, in seconds, two positions must be to count as different.
    static let positionTolerance = 1.0

    /// The legacy app's rule (`layouts/default.vue`): the player has the item open and is paused,
    /// and the update comes from another playback session, whether or not the cache took it. In
    /// addition, the update must not be older than the cached progress (no jump backwards to a
    /// stale event); one as old must match the cached position within ``positionTolerance`` (the
    /// same progress, already fetched). Its position must differ from the player's by at least
    /// ``positionTolerance``, so an update that only changed the ebook location or the finished
    /// flag offers nothing.
    private static func offersJump(
        _ update: UserItemProgressUpdate, to snapshot: RealtimePlaybackSnapshot, cached: MediaProgress?
    ) -> Bool {
        if let incoming = update.progress.lastUpdate, let cached, let cachedTime = cached.lastUpdate {
            if incoming < cachedTime { return false }
            if incoming == cachedTime,
                abs(update.progress.currentTime - cached.currentTime) >= positionTolerance
            {
                return false
            }
        }
        return !snapshot.isPlaying && update.sessionId != snapshot.playbackSessionID
            && abs(update.progress.currentTime - snapshot.currentTime) >= positionTolerance
    }
}
