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

/// What CarPlay asks about its own play that the streaming policy blocked on a metered network
/// (``CarPlayRootModel/streamingPrompt``).
public enum CarPlayStreamingPrompt: Sendable, Hashable {
    /// The setting is "ask": Stream (``CarPlayRootModel/confirmStreaming()``) or Cancel.
    case confirm
    /// The setting is "never": why nothing plays, with OK alone.
    case notAllowed
}

/// How a CarPlay play ended (``CarPlayRootModel/play(_:)``): only a started one shows Now Playing.
public enum CarPlayPlayOutcome: Sendable, Hashable {
    /// The play started, or at least nothing reported a failure.
    case started
    /// The streaming policy blocked it; ``CarPlayRootModel/streamingPrompt`` says what to ask.
    case blocked
    /// It failed; the player reports why.
    case failed
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
/// nothing, so CarPlay asks about it itself (``streamingPrompt``), as the phone's player does,
/// since a CarPlay-only launch has no phone screen to ask on. Its play requests the application-primary Now Playing session
/// once playing, and asks to become the system primary one only afterwards, best effort: on a
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
    @ObservationIgnored private let limits: CarPlayLimits
    @ObservationIgnored private let labels: CarPlayLabels
    @ObservationIgnored private let imageBucket: ImageWidthBucket
    private var home: HomeModel?
    private var homeIdentity: SessionIdentity?
    /// The block of CarPlay's last play, while it may still be the player's error.
    private var blockedPlay: PlaybackCoordinatorError?

    /// - Parameters:
    ///   - gate: The session's gate (`SessionLifecycle.gate`).
    ///   - store: The shared library store; `nil` shows the signed-out content once signed in.
    ///   - playItem: The play action while `identity`'s account is the active one, else `nil`.
    ///   - playing: The item in the player, if any.
    ///   - playback: The app's playback, whose error says whether the streaming policy blocked a
    ///     play and which streams or declines it (``confirmStreaming()``, ``declineStreaming()``).
    ///   - limits: The car's list limits (``CarPlayLimits``).
    ///   - imageBucket: The width bucket of row images (``CarPlayContentBuilder/imageBucket``).
    public init(
        gate: @escaping @MainActor () -> AuthGate, store: LibraryStore?,
        playItem: @escaping @MainActor (SessionIdentity) -> PlayItemAction?,
        playing: @escaping @MainActor () -> MediaKey?, playback: (any PlayerPlaybackControlling)? = nil,
        limits: CarPlayLimits = .standard, labels: CarPlayLabels, imageBucket: ImageWidthBucket = .small
    ) {
        self.gate = gate
        self.store = store
        self.playItem = playItem
        self.playing = playing
        self.playback = playback
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
    /// doesn't play or is disabled, the tabs aren't shown, or the account can't play. Failures
    /// are logged; the player shows them.
    @discardableResult
    public func play(_ row: CarPlayRow) -> Task<CarPlayPlayOutcome, Never>? {
        guard case .play(let itemID, let episodeID) = row.action, row.isEnabled,
            case .tabs(let list, _) = content,
            list.rows.contains(where: {
                $0.id == row.id && $0.action == row.action && $0.image == row.image && $0.isEnabled
            }),
            let identity, let playItem = playItem(identity)
        else { return nil }
        blockedPlay = nil
        return Task {
            do {
                try await playItem(itemID: itemID, episodeID: episodeID)
            } catch {
                Log.playback.error("CarPlay: couldn't play: \(error, privacy: .public)")
                return .failed
            }
            return outcome()
        }
    }

    /// What CarPlay asks about its own play that the streaming policy blocked, while that block
    /// is still the player's error: `nil` once it changes or clears, for example when the phone
    /// streamed or cancelled it.
    public var streamingPrompt: CarPlayStreamingPrompt? {
        guard let blockedPlay, playback?.error == blockedPlay else { return nil }
        switch blockedPlay {
        case .streamingNeedsConfirmation: return .confirm
        case .streamingNotAllowed: return .notAllowed
        default: return nil
        }
    }

    /// Stream for ``CarPlayStreamingPrompt/confirm``: plays the blocked item on the metered
    /// network. The policy is checked again, so "never" still blocks. `nil` without that prompt.
    @discardableResult
    public func confirmStreaming() -> Task<CarPlayPlayOutcome, Never>? {
        guard streamingPrompt == .confirm, let playback else { return nil }
        blockedPlay = nil
        return Task {
            await playback.confirmMeteredStreaming()
            return outcome()
        }
    }

    /// Cancel (or OK) for ``streamingPrompt``: a confirmation is declined, which clears the
    /// player's error; a "never" block's message is only dismissed here.
    public func declineStreaming() {
        guard let prompt = streamingPrompt else { return }
        blockedPlay = nil
        if prompt == .confirm { playback?.declineMeteredStreaming() }
    }

    /// The outcome of a play that has returned, by the player's error; a streaming block is kept
    /// for ``streamingPrompt``.
    private func outcome() -> CarPlayPlayOutcome {
        switch playback?.error {
        case nil: return .started
        case .streamingNeedsConfirmation?, .streamingNotAllowed?:
            blockedPlay = playback?.error
            return .blocked
        default: return .failed
        }
    }
}
