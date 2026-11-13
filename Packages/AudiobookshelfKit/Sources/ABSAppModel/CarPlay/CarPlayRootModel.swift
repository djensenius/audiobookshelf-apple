import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation

/// What CarPlay's root template shows (#79).
public enum CarPlayRootContent: Sendable, Hashable {
    /// Restoring the session, switching or signing out, or loading the first shelves.
    case loading
    /// No account is signed in: sign in on the phone.
    case signedOut
    /// The local store couldn't be opened.
    case storeUnavailable
    /// The first load of the shelves failed, so there's nothing to show.
    case failed
    /// The tab bar with the Continue tab. `playingRowID` is the row of the item in the player.
    case tabs(continueListening: CarPlayList, playingRowID: String?)
}

/// How a CarPlay play ended (``CarPlayRootModel/play(_:)``): only a started one shows Now Playing.
public enum CarPlayPlayOutcome: Sendable, Hashable {
    /// The play started, or at least nothing reported a failure.
    case started
    /// The streaming policy blocked it; ``CarPlayRootModel/alert`` says what to ask.
    case blocked
    /// It failed; ``CarPlayRootModel/alert`` says why.
    case failed
    /// It ended after the account's session changed (a sign-out, a switch) or after a later
    /// CarPlay play: its result belongs to nothing shown, so it shows nothing.
    case discarded
}

/// CarPlay's root (#79): which template to show for the session, the Continue tab's rows and
/// what a tapped row plays. The CarPlay delegate is a thin adapter over it: it shows
/// ``content``, calls ``update()`` each time ``loadTrigger`` changes, and ``play(_:)`` for a
/// tapped row.
///
/// The Continue tab is the Continue Listening shelf of the library a new scene starts in
/// (``LibraryStore/initialLibraryID``), loaded with a ``HomeModel`` of the signed-in account's
/// own: like Home's, it's replaced when the account changes, and dropped when signed out, so
/// signing in again never shows the last account's shelves. Progress changes update the rows
/// at once, through the store's ``LibraryStore/progress``.
///
/// Plays go through the app's ``PlayItemAction`` for the signed-in account, the same path as a
/// play from the app's screens. A play the streaming policy blocks on a metered network starts
/// nothing, so CarPlay asks about it itself (``alert``), as the phone's player does, since a
/// CarPlay-only launch has no phone screen to ask on; a play that fails says why there too. Its
/// play requests the application-primary Now Playing session once playing, and asks to become the system primary one only afterwards, best effort: on a
/// CarPlay-only launch that request fails and is logged, and playback has already started
/// (ADR 0006, Lifecycle).
@MainActor
@Observable
public final class CarPlayRootModel {
    /// What ``update()`` loads for; it changes when the account, the library or the connection
    /// does.
    public struct LoadTrigger: Hashable, Sendable {
        public var identity: SessionIdentity?
        public var libraryID: String?
        public var onlineRevision: Int
    }

    @ObservationIgnored private let gate: @MainActor () -> AuthGate
    @ObservationIgnored private let store: LibraryStore?
    @ObservationIgnored private let playItem: @MainActor (SessionIdentity) -> PlayItemAction?
    @ObservationIgnored private let playing: @MainActor () -> MediaKey?
    @ObservationIgnored private let playback: (any PlayerPlaybackControlling)?
    @ObservationIgnored private let playbackSession: @MainActor () -> AnyObject?
    /// Advanced by each play and confirmation, so only the latest one's result is used.
    @ObservationIgnored private var operation = 0
    @ObservationIgnored private let limits: CarPlayLimits
    @ObservationIgnored private let labels: CarPlayLabels
    @ObservationIgnored private let imageBucket: ImageWidthBucket
    private var home: HomeModel?
    private var homeIdentity: SessionIdentity?
    /// The failure of CarPlay's last play, while it may still be shown (``alert``).
    private var failedPlay: FailedPlay?
    /// The latest play while it's starting, which a tap on the same item joins.
    @ObservationIgnored private var pendingPlay: PendingPlay?

    /// - Parameters:
    ///   - gate: The session's gate (`SessionLifecycle.gate`).
    ///   - store: The shared library store; `nil` shows the signed-out content once signed in.
    ///   - playItem: The play action while `identity`'s account is the active one, else `nil`.
    ///   - playing: The item in the player, if any.
    ///   - playback: The app's playback, whose error says whether a play failed or the streaming
    ///     policy blocked it, and which streams or declines it (``confirmStreaming()``,
    ///     ``dismissAlert()``).
    ///   - playbackSession: The account session `playback` is bound to, `nil` while unbound: a play
    ///     whose session changed before it returned is discarded.
    ///   - limits: The car's list limits (``CarPlayLimits``).
    ///   - imageBucket: The width bucket of row images (``CarPlayContentBuilder/imageBucket``).
    public init(
        gate: @escaping @MainActor () -> AuthGate, store: LibraryStore?,
        playItem: @escaping @MainActor (SessionIdentity) -> PlayItemAction?,
        playing: @escaping @MainActor () -> MediaKey?, playback: (any PlayerPlaybackControlling)? = nil,
        playbackSession: @escaping @MainActor () -> AnyObject? = { nil }, limits: CarPlayLimits = .standard,
        labels: CarPlayLabels, imageBucket: ImageWidthBucket = .small
    ) {
        self.gate = gate
        self.store = store
        self.playItem = playItem
        self.playing = playing
        self.playback = playback
        self.playbackSession = playbackSession
        self.limits = limits
        self.labels = labels
        self.imageBucket = imageBucket
    }

    /// The signed-in account, while the store serves it.
    private var identity: SessionIdentity? {
        guard case .ready(let identity, _) = gate(), let store, store.serves(identity) else { return nil }
        return identity
    }

    public var content: CarPlayRootContent {
        switch gate() {
        case .launching, .switching, .signingOut: return .loading
        case .connect: return .signedOut
        case .storeUnavailable: return .storeUnavailable
        case .ready: break
        }
        guard let identity, let store else { return store == nil ? .signedOut : .loading }
        let builder = CarPlayContentBuilder(
            limits: limits, labels: labels, serverID: identity.connectionID, imageBucket: imageBucket)
        guard store.initialLibraryID != nil else {
            // Without a library there's no shelf, once the libraries are known.
            if store.hasLoaded { return tabs(builder.continueListening(sections: [], progress: { _ in nil })) }
            return store.error == nil ? .loading : .failed
        }
        guard let home, homeIdentity == identity, home.libraryID == store.initialLibraryID else { return .loading }
        guard home.hasLoaded else { return home.error == nil ? .loading : .failed }
        let progress = store.progress
        let list = builder.continueListening(sections: home.sections) {
            progress.progress(libraryItemID: $0.itemID, episodeID: $0.episodeID).map(ItemProgress.init)
        }
        return tabs(list)
    }

    private func tabs(_ list: CarPlayList) -> CarPlayRootContent {
        let key = playing()
        let row = key.flatMap { key in
            list.rows.first {
                $0.action == .play(itemID: key.libraryItemId, episodeID: key.episodeId)
                    && key.serverConnectionID == identity?.connectionID
            }
        }
        return .tabs(continueListening: list, playingRowID: row?.id)
    }

    public var loadTrigger: LoadTrigger {
        LoadTrigger(identity: identity, libraryID: store?.initialLibraryID, onlineRevision: store?.onlineRevision ?? 0)
    }

    /// Loads the Continue tab's shelves for the signed-in account unless they're loaded, creating
    /// its ``HomeModel`` on the first call for the account. Signed out, drops the model.
    public func update() async {
        guard let model = prepare() else { return }
        await model.load()
    }

    /// Reloads the Continue tab's shelves, for example when the tab shows again after Now Playing.
    /// Without a library to show, it reloads the libraries first, so a first libraries request
    /// that failed is retried.
    public func refresh() async {
        if identity != nil, let store, store.initialLibraryID == nil { await store.refresh() }
        guard let model = prepare() else { return }
        if model.hasLoaded { await model.refresh() } else { await model.load() }
    }

    private func prepare() -> HomeModel? {
        guard let identity, let store else {
            home = nil
            homeIdentity = nil
            return nil
        }
        if home == nil || homeIdentity != identity {
            home = HomeModel(store: store)
            homeIdentity = identity
        }
        home?.libraryID = store.initialLibraryID
        return home?.libraryID == nil ? nil : home
    }

    /// Starts playing `row` through the account's play action, for a tapped row. Returns the
    /// play, whose outcome says whether to show Now Playing, or `nil` when nothing plays: the
    /// tab doesn't show the row (by its ID, action and image, whatever its progress), the row
    /// doesn't play or is disabled, the tabs aren't shown, or the account can't play. A failure
    /// or a streaming block becomes the ``alert``. Tapped again while it's starting (the same
    /// item, account and session), the same play is returned: the coordinator would return at
    /// once for the item it's loading, and its outcome is the first tap's. Another item's tap
    /// supersedes it.
    @discardableResult
    public func play(_ row: CarPlayRow) -> Task<CarPlayPlayOutcome, Never>? {
        guard case .play(let itemID, let episodeID) = row.action, row.isEnabled,
            case .tabs(let list, _) = content,
            list.rows.contains(where: {
                $0.id == row.id && $0.action == row.action && $0.image == row.image && $0.isEnabled
            }),
            let identity, let playItem = playItem(identity)
        else { return nil }
        if let pendingPlay, pendingPlay.origin.action == row.action, pendingPlay.origin.operation == operation,
            isCurrent(pendingPlay.origin)
        {
            return pendingPlay.task
        }
        let origin = begin(identity, action: row.action)
        let task = Task {
            let threw: Bool
            do {
                try await playItem(itemID: itemID, episodeID: episodeID)
                threw = false
            } catch {
                Log.playback.error("CarPlay: couldn't play: \(error, privacy: .public)")
                threw = true
            }
            if pendingPlay?.origin.operation == origin.operation { pendingPlay = nil }
            return finish(origin, threw: threw)
        }
        pendingPlay = PendingPlay(origin: origin, task: task)
        return task
    }

    /// What CarPlay shows about its own last play: a streaming block to confirm
    /// (``PlayerErrorMessage/streamingNeedsConfirmation``: Stream or Cancel) or explain, or a
    /// failure (OK alone). Only while the account's session is the play's and its error is still
    /// the player's: `nil` once it changes or clears, for example when the phone answered it.
    public var alert: PlayerErrorMessage? {
        guard let failedPlay, isCurrent(failedPlay.origin), playback?.error == failedPlay.error else { return nil }
        return failedPlay.message
    }

    /// Stream for ``PlayerErrorMessage/streamingNeedsConfirmation``: plays the blocked item on the
    /// metered network. The policy is checked again, so "never" still blocks. `nil` without that
    /// alert. The consent goes to the player only if, when the task runs, the block is still the
    /// one asked about, in the same session, with no later operation; otherwise it's discarded,
    /// so it can't authorize another item's block or a rebound playback's. While the replay starts,
    /// it's the blocked row's play, which a tap on that row joins (``play(_:)``).
    @discardableResult
    public func confirmStreaming() -> Task<CarPlayPlayOutcome, Never>? {
        guard alert == .streamingNeedsConfirmation, let blocked = failedPlay, let playback, let identity else {
            return nil
        }
        let origin = begin(identity, action: blocked.origin.action)
        let task = Task {
            // Once it ends, discarded or not, a tap starts afresh.
            defer { if pendingPlay?.origin.operation == origin.operation { pendingPlay = nil } }
            guard origin.operation == operation, isCurrent(origin), isCurrent(blocked.origin),
                playback.error == blocked.error
            else { return CarPlayPlayOutcome.discarded }
            await playback.confirmMeteredStreaming()
            return finish(origin, threw: false)
        }
        pendingPlay = PendingPlay(origin: origin, task: task)
        return task
    }

    /// Cancel or OK for ``alert``: a confirmation is declined, which clears the player's error;
    /// anything else is only dismissed here.
    public func dismissAlert() {
        guard let alert else { return }
        failedPlay = nil
        if alert == .streamingNeedsConfirmation { playback?.declineMeteredStreaming() }
    }

    /// Where a play or confirmation started: the row's action, the account, its playback session
    /// (held weakly, so a later session at the same address isn't taken for it), and the operation.
    private struct Origin {
        let action: CarPlayRow.Action
        let identity: SessionIdentity
        weak var session: AnyObject?
        let hadSession: Bool
        let operation: Int
    }

    /// A play while it's starting.
    private struct PendingPlay {
        let origin: Origin
        let task: Task<CarPlayPlayOutcome, Never>
    }

    /// A play's failure, with the player's error it came from (`nil` when the play threw).
    private struct FailedPlay {
        let origin: Origin
        let error: PlaybackCoordinatorError?
        let message: PlayerErrorMessage
    }

    /// Starts an operation, superseding the previous one and its alert.
    private func begin(_ identity: SessionIdentity, action: CarPlayRow.Action) -> Origin {
        operation += 1
        failedPlay = nil
        let session = playbackSession()
        return Origin(
            action: action, identity: identity, session: session, hadSession: session != nil, operation: operation)
    }

    /// Whether `origin`'s account and playback session are still the current ones. A play
    /// started before the playback was bound may see it bound.
    private func isCurrent(_ origin: Origin) -> Bool {
        guard identity == origin.identity else { return false }
        guard origin.hadSession else { return true }
        guard let session = origin.session else { return false }
        return session === playbackSession()
    }

    /// The outcome of an operation that has returned, by the player's error; a failure or block
    /// is kept for ``alert``. Discarded once a later operation started or the account's session
    /// changed: the playback may then be unbound (no error, which isn't a start) or another
    /// account's.
    private func finish(_ origin: Origin, threw: Bool) -> CarPlayPlayOutcome {
        guard origin.operation == operation, isCurrent(origin) else { return .discarded }
        let error = playback?.error
        guard error != nil || threw else { return .started }
        let message = error.map(PlayerErrorMessage.init) ?? .playbackFailed
        failedPlay = FailedPlay(origin: origin, error: error, message: message)
        switch message {
        case .streamingNeedsConfirmation, .streamingNotAllowed: return .blocked
        default: return .failed
        }
    }
}
