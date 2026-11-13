import ABSAPI
import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation

/// One account session's playback, as the session participant drives it. ``PlaybackScope``
/// conforms; tests pass a fake.
@MainActor
public protocol PlaybackScopeHandle: AnyObject, Sendable {
    /// The coordinator, for ``CurrentPlayback``.
    var playback: any PlayerPlaybackControlling { get }
    /// Raised once if the server rejects a session start as expired.
    var onSessionRejected: (@MainActor () -> Void)? { get set }
    /// Restores the account's last-played item, paused.
    @discardableResult func start() -> Bool
    func play(itemID: String, episodeID: String?, startTime: Double?) async
    /// The account's play queue, read-only; `nil` when the scope has none.
    var queue: (any PlaybackQueueReading)? { get }
    /// The sleep timer, cancelled when the scope retires; `nil` when the scope has none.
    var sleepTimer: SleepTimer? { get }
    /// Changes the queue, unless the scope has retired.
    func editQueue(_ edit: (PlaybackQueue) -> Void)
    func reconnect(client: APIClient?, features: ServerFeatures?)
    /// Progress changed for `key`; the auto-advance prepares again if it concerns it (#160).
    func progressDidChange(for key: MediaKey)
    /// Saves the last-played record; local only.
    func saveLocally()
    /// Stops for good, synchronously, capturing the final position.
    func retire(reason: PlaybackStopReason)
    /// Waits, at most `timeout`, for the retirement's closes, then releases the scope.
    func finishRetirement(timeout: Duration) async -> Result<PlaybackCloseOutcome, any Error>
}

extension PlaybackScope: PlaybackScopeHandle {
    /// The coordinator, with user resumes routed through the scope (``ScopePlayback``). A new
    /// adapter on each read; the participant reads it once per session.
    public var playback: any PlayerPlaybackControlling { ScopePlayback(scope: self) }
}

/// What the app builds a session's ``PlaybackScopeHandle`` from.
public struct PlaybackScopeRequest: Sendable {
    public let connectionID: UUID
    /// `nil` offline: the scope restores, but can't stream until a reconnect.
    public let client: APIClient?
    /// `nil` when the account's features aren't known: no session starts until they are.
    public let features: ServerFeatures?
    public let deviceIdentifiers: any DeviceIdentifying
    /// The one local progress writer every scope shares, so a retired scope's late write can't
    /// supersede a newer committed position.
    public let writer: LocalProgressStore

    public init(
        connectionID: UUID, client: APIClient?, features: ServerFeatures?, deviceIdentifiers: any DeviceIdentifying,
        writer: LocalProgressStore
    ) {
        self.connectionID = connectionID
        self.client = client
        self.features = features
        self.deviceIdentifiers = deviceIdentifiers
        self.writer = writer
    }
}

/// Gives each account session its own playback scope (#183). Register it at
/// ``SessionStage/progressSource``: its coordinator and syncer write progress.
///
/// - **Start** builds the scope, binds ``CurrentPlayback`` to its coordinator, publishes its
///   ``queue`` and ``sleepTimer``, restores the account's last-played item, publishes
///   ``playItem``, and starts the session's own ``bookmarks``.
/// - **Reconnect** swaps the client and features into the same scope, and reconnects the same
///   bookmark store; playback carries on.
/// - **End** retires the scope before its first `await`: playback stops for good and the final
///   position is captured, before the next account can begin. It then ends the bookmark store,
///   waits, within `closeTimeout`, for the close, and releases the scope. The lifecycle may cancel
///   that wait and start the next account while it runs; the old scope stays on its own account's
///   services.
/// - **Flush** saves the last-played record locally; sending progress is the syncer's (#184).
@MainActor
@Observable
public final class PlaybackSessionParticipant: SessionParticipant {
    public typealias MakeScope = @MainActor (PlaybackScopeRequest) -> any PlaybackScopeHandle

    /// Plays an item in the current account's scope; `nil` between sessions.
    public private(set) var playItem: PlayItemAction?
    /// The current account's play queue; `nil` between sessions.
    public private(set) var queue: PlaybackQueueControl?
    /// The current scope's sleep timer, for the player's `\.sleepTimer` environment value; `nil`
    /// between sessions and for a scope without one.
    public private(set) var sleepTimer: SleepTimer?
    /// The current account's bookmarks (#57's D13): a store of its own for each session; `nil`
    /// between sessions. The app's `RealtimeBridge` replaces its list on the socket's `user_updated`
    /// (``RealtimeBridge/route(library:accounts:bookmarks:playback:localProgress:)``).
    public private(set) var bookmarks: BookmarkStore?
    /// The latest ended session's close outcome, or why it isn't durable; `nil` until it finishes.
    /// A retirement the lifecycle cancelled can finish after a later session ended; its result is
    /// dropped rather than replacing that session's.
    public private(set) var lastEnd: Result<PlaybackCloseOutcome, any Error>?

    @ObservationIgnored private var scope: (any PlaybackScopeHandle)?
    /// The running scope's session.
    @ObservationIgnored private var scopeSessionID: UInt64?
    /// The running scope's connection, for ``progressDidChange(libraryItemID:episodeID:)``.
    @ObservationIgnored private var scopeConnectionID: UUID?
    /// The session whose retirement ``lastEnd`` reports.
    @ObservationIgnored private var latestEndedSessionID: UInt64?
    /// Reports a session starting while another is running. Tests record instead of stopping.
    @ObservationIgnored var reportMisuse: @MainActor (String) -> Void = { assertionFailure($0) }
    @ObservationIgnored private let current: CurrentPlayback
    @ObservationIgnored private let writer: LocalProgressStore
    @ObservationIgnored private let deviceIdentifiers: any DeviceIdentifying
    @ObservationIgnored private let features: @MainActor (SessionIdentity) -> ServerFeatures?
    @ObservationIgnored private let requestSignOut: @MainActor (SessionContext) -> Void
    @ObservationIgnored private let closeTimeout: Duration
    @ObservationIgnored private let makeBookmarks: @MainActor () -> BookmarkStore
    @ObservationIgnored private let makeScope: MakeScope

    /// - Parameters:
    ///   - current: The proxy the player screens read, re-bound to each session's coordinator.
    ///   - writer: The one local progress store, shared by every scope.
    ///   - features: The account's server features, or `nil` when unknown. Never invented: with
    ///     `nil`, the scope can't start sessions.
    ///   - requestSignOut: Called with the session's context when the server rejects it as
    ///     expired; the app passes ``SessionLifecycle/requestSignOut(of:)``.
    ///   - closeTimeout: How long an ending session waits for its close.
    ///   - makeBookmarks: Builds each session's bookmark store; the app passes one whose
    ///     `isOffline` reads the lifecycle's gate.
    ///   - makeScope: Builds the scope; the app passes ``PlaybackScope/make(_:makeNowPlaying:)``.
    public init(
        current: CurrentPlayback, writer: LocalProgressStore, deviceIdentifiers: any DeviceIdentifying,
        features: @escaping @MainActor (SessionIdentity) -> ServerFeatures?,
        requestSignOut: @escaping @MainActor (SessionContext) -> Void,
        closeTimeout: Duration = PlaybackCoordinator.closeWaitTimeout,
        makeBookmarks: @escaping @MainActor () -> BookmarkStore = { BookmarkStore() },
        makeScope: @escaping MakeScope
    ) {
        self.current = current
        self.writer = writer
        self.deviceIdentifiers = deviceIdentifiers
        self.features = features
        self.requestSignOut = requestSignOut
        self.closeTimeout = closeTimeout
        self.makeBookmarks = makeBookmarks
        self.makeScope = makeScope
    }

    /// How an account session's end stops its playback.
    public nonisolated static func stopReason(for reason: SessionEndReason) -> PlaybackStopReason {
        switch reason {
        case .switch: .accountSwitch
        case .signOut: .signOut
        case .removed: .accountRemoved
        case .expired: .expired
        }
    }

    public func sessionDidStart(_ context: SessionContext) async {
        if scope != nil {
            // Never orphan a live coordinator: retire it as for a switch, and release it.
            Log.playback.fault("A playback session started before the last one ended")
            reportMisuse("A playback session started before the last one ended")
            if let ending = retireScope(reason: .accountSwitch) {
                Task { await self.finishRetirement(ending, reason: .switch) }
            }
        }
        let scope = makeScope(
            PlaybackScopeRequest(
                connectionID: context.identity.connectionID, client: context.client,
                features: features(context.identity), deviceIdentifiers: deviceIdentifiers, writer: writer))
        self.scope = scope
        scopeSessionID = context.sessionID
        scopeConnectionID = context.identity.connectionID
        scope.onSessionRejected = { [weak self, weak scope] in
            guard let self, let scope, self.scope === scope else { return }
            self.requestSignOut(context)
        }
        current.bind(scope.playback)
        queue = PlaybackQueueControl(scope: scope)
        sleepTimer = scope.sleepTimer
        let bookmarks = makeBookmarks()
        self.bookmarks = bookmarks
        scope.start()
        playItem = PlayItemAction { [weak scope] itemID, episodeID, startTime in
            await scope?.play(itemID: itemID, episodeID: episodeID, startTime: startTime)
        }
        await bookmarks.sessionDidStart(context)
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        scope?.reconnect(client: context.client, features: features(context.identity))
        await bookmarks?.sessionDidReconnect(context)
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        // Everything up to the first `await` runs before the lifecycle can move on.
        guard let ending = retireScope(reason: Self.stopReason(for: reason)) else { return }
        await finishRetirement(ending, reason: reason)
    }

    private struct EndingScope {
        let scope: any PlaybackScopeHandle
        let sessionID: UInt64
        let bookmarks: BookmarkStore?
    }

    /// Detaches and retires the running scope, synchronously.
    private func retireScope(reason: PlaybackStopReason) -> EndingScope? {
        guard let scope, let sessionID = scopeSessionID else { return nil }
        let bookmarks = bookmarks
        self.scope = nil
        scopeSessionID = nil
        scopeConnectionID = nil
        latestEndedSessionID = sessionID
        // The previous session's result no longer describes the latest end.
        lastEnd = nil
        playItem = nil
        queue = nil
        sleepTimer = nil
        self.bookmarks = nil
        scope.onSessionRejected = nil
        scope.retire(reason: reason)
        current.bind(nil)
        return EndingScope(scope: scope, sessionID: sessionID, bookmarks: bookmarks)
    }

    /// Ends the retired scope's bookmark store, waits for its close and releases it; records the
    /// result unless a later session ended meanwhile.
    private func finishRetirement(_ ending: EndingScope, reason: SessionEndReason) async {
        await ending.bookmarks?.sessionWillEnd(reason)
        let result = await ending.scope.finishRetirement(timeout: closeTimeout)
        if case .failure(let error) = result {
            Log.playback.error(
                "Playback scope ended without a durable close: \(Self.name(of: error), privacy: .public)")
        }
        guard latestEndedSessionID == ending.sessionID else { return }
        lastEnd = result
    }

    /// The library's progress for an item or episode changed (``ProgressCache/onChange``): tells
    /// the running scope, as progress on its account. Nothing between sessions.
    public func progressDidChange(libraryItemID: String, episodeID: String?) {
        guard let scope, let scopeConnectionID else { return }
        scope.progressDidChange(
            for: MediaKey(serverConnectionID: scopeConnectionID, libraryItemId: libraryItemID, episodeId: episodeID))
    }

    public func flush() async {
        scope?.saveLocally()
    }

    /// The error's case name, without session IDs.
    private static func name(of error: any Error) -> String {
        switch error {
        case is CancellationError: "cancelled"
        case PlaybackCloseError.missingReporter: "missingReporter"
        case PlaybackCloseError.positionCommitFailed: "positionCommitFailed"
        case PlaybackCloseError.transportFailed: "transportFailed"
        case PlaybackCloseError.timedOut: "timedOut"
        default: "other"
        }
    }
}
