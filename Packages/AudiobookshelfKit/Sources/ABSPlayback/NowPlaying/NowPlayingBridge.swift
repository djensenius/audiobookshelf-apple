import ABSCore
import ABSData
import Foundation
import Observation
import Synchronization

/// The cover to show for an item: `coverPath` on the item's library item (as in the session or the
/// ``LastPlayedRecord``).
public struct NowPlayingCover: Sendable, Hashable {
    public var key: MediaKey
    public var coverPath: String

    public init(key: MediaKey, coverPath: String) {
        self.key = key
        self.coverPath = coverPath
    }
}

/// Loads image data (JPEG, PNG, HEIC…) for a cover, from the download or the server's cover
/// endpoint; `nil` when there is none. Runs off the main actor and is cancelled when the item or
/// cover changes.
public typealias NowPlayingCoverProvider = @Sendable (NowPlayingCover) async -> Data?

/// Connects ``PlaybackCoordinator`` to the system Now Playing surfaces, so the coordinator never
/// sees the NowPlaying framework (ADR 0006).
///
/// - **State.** Every ``PlaybackCoordinatorEvent`` (item, session, load, play, pause, seek, tick,
///   end, failure, close) rebuilds a ``NowPlayingState`` from the coordinator's properties and
///   passes it to ``NowPlayingController/update(_:)``, which publishes only what changed. The rate
///   and play state, unloaded position (which can change without an event) and Now Playing settings
///   are observed with Observation, so changes apply at runtime. No item clears the session.
///   Title, author, narrator, release date and cover are cached per item, so a closing session, a
///   restart or a failed load keeps them; a new item shows blank until its session starts.
/// - **Commands.** Remote commands arrive through the controller, which refuses them without an
///   item (``NowPlayingCommandError/noPlayer``) and refuses seeks while seeking from media controls
///   is off. Skips and next/previous track jump by the interval from the user's settings, through
///   ``PlaybackCoordinator/jump(by:)``. Toggle follows the coordinator's play intent
///   (``PlaybackCoordinator/isPlaybackRequested``), so it pauses while starting or stalled. Once the
///   coordinator is gone, a command ends the session and throws ``NowPlayingCommandError/noPlayer``.
/// - **Ownership.** The composition root owns the bridge. The bridge holds the coordinator weakly,
///   and the coordinator holds only a weak observer, so neither keeps the other alive. The bridge
///   owns the controller, whose command handler (this bridge) is weak.
/// - **Threading.** Main actor only. Artwork loads run off the main actor.
///
/// **What the composition root must do** (`AppEnvironment`, P3-04 #44). Runtime gates remain on
/// parent #54 (Lock Screen, Control Center, AirPods, Mac media keys) and #79/#81 (CarPlay):
/// 1. Construct one with ``init(coordinator:settings:coverProvider:entityIdentifiers:)`` right after
///    the coordinator, passing the app's `AppSettings`, a cover provider (download, else the
///    server's cover endpoint) and the App Intents entity mapping.
/// 2. Hold it strongly for the coordinator's lifetime (nothing else retains it). Calling
///    ``invalidate()``, or releasing it, ends the Now Playing session.
/// 3. Call ``requestSystemPrimary()`` after each user-initiated play in the foreground (iOS).
@available(iOSApplicationExtension, unavailable)
@MainActor
public final class NowPlayingBridge: NowPlayingCommandHandling {
    private weak var coordinator: PlaybackCoordinator?
    let controller: NowPlayingController
    private let readSettings: @MainActor () -> NowPlayingSettings
    private let covers: CoverRegistry
    private var observerToken: PlaybackObserverToken?
    /// The last display metadata seen, for one item.
    private var metadata: (key: MediaKey, value: Metadata)?
    private(set) var isInvalidated = false

    /// - Parameters:
    ///   - settings: The jump intervals, seeking and chapter-track settings, observed for changes.
    ///   - coverProvider: Loads the current item's cover.
    ///   - entityIdentifiers: App Intents entities for an item, supplied by the composition root.
    public convenience init(
        coordinator: PlaybackCoordinator, settings: AppSettings, coverProvider: @escaping NowPlayingCoverProvider,
        entityIdentifiers: @escaping NowPlayingEntityIdentifiers
    ) {
        self.init(
            coordinator: coordinator, settings: { NowPlayingSettings(settings) }, coverProvider: coverProvider,
            entityIdentifiers: entityIdentifiers, now: { Date() }, makeSession: { MediaSessionPublisher() })
    }

    init(
        coordinator: PlaybackCoordinator, settings: @escaping @MainActor () -> NowPlayingSettings,
        coverProvider: @escaping NowPlayingCoverProvider, entityIdentifiers: @escaping NowPlayingEntityIdentifiers,
        now: @escaping @Sendable () -> Date,
        makeSession: @escaping @MainActor () -> any NowPlayingSessionPublishing
    ) {
        let covers = CoverRegistry()
        self.coordinator = coordinator
        self.readSettings = settings
        self.covers = covers
        controller = NowPlayingController(
            commandHandler: nil, settings: settings(),
            artworkProvider: { artworkKey in
                guard let cover = covers.cover(for: artworkKey) else { return nil }
                return await coverProvider(cover)
            },
            entityIdentifiers: entityIdentifiers, now: now, makeSession: makeSession)
        controller.commandHandler = self
        observerToken = coordinator.addObserver { [weak self] _ in self?.refresh() }
        trackSettingsAndRate()
        refresh()
    }

    isolated deinit {
        invalidate()
    }

    /// Stops following the coordinator and ends the Now Playing session. Idempotent.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if let observerToken { coordinator?.removeObserver(observerToken) }
        observerToken = nil
        controller.commandHandler = nil
        controller.clear()
    }

    /// See ``NowPlayingController/requestSystemPrimary()``: iOS only, after a user-initiated play in
    /// the foreground; best effort.
    public func requestSystemPrimary(while isStillWanted: @MainActor () -> Bool = { true }) async {
        await controller.requestSystemPrimary(while: isStillWanted)
    }

    // MARK: State

    /// Publishes the coordinator's current state; clears the session when there is no item.
    func refresh() {
        guard !isInvalidated else { return }
        guard let coordinator else {
            invalidate()
            return
        }
        let key = coordinator.mediaKey
        if metadata?.key != key { metadata = nil }
        if let key, let fresh = Self.metadata(of: coordinator, key: key, includeRestored: metadata == nil) {
            metadata = (key, fresh)
        }
        let current = key.flatMap { metadata?.key == $0 ? metadata?.value : nil }
        let state = key.map { Self.state(of: coordinator, key: $0, metadata: current ?? Metadata()) }
        covers.set(state?.artworkKey, cover: current?.cover)
        controller.update(state)
    }

    /// Observes settings, rate, play state, audio session activation, pending seeks and unloaded
    /// position without events.
    /// The loaded clock follows coordinator events, avoiding observation work for every tick.
    private func trackSettingsAndRate() {
        guard !isInvalidated else { return }
        let settings = withObservationTracking {
            _ = coordinator?.rate
            _ = coordinator?.isPlaying
            _ = coordinator?.isBuffering
            _ = coordinator?.isAudioSessionActive
            _ = coordinator?.pendingSeekTarget
            if let coordinator, coordinator.phase != .loaded { _ = coordinator.currentTime }
            return readSettings()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.settingsOrRateChanged() }
        }
        controller.settings = settings
    }

    private func settingsOrRateChanged() {
        trackSettingsAndRate()
        refresh()
    }

    /// The display metadata for `key`, cached by ``refresh()`` so a closing session, a restart or a
    /// failed load (which drop the session) never blank the item out.
    struct Metadata: Equatable {
        var title = ""
        var author = ""
        var narrator: String?
        var releaseDate: Date?
        var cover: NowPlayingCover?
    }

    /// Live session metadata for `key`. A restored record only seeds an empty cache; it must not
    /// overwrite live metadata when a failed load drops the session but keeps the restored record.
    static func metadata(of coordinator: PlaybackCoordinator, key: MediaKey, includeRestored: Bool) -> Metadata? {
        if let session = coordinator.session, session.libraryItemId == key.libraryItemId,
            session.episodeId == key.episodeId
        {
            var metadata = Metadata(
                title: session.displayTitle ?? "", author: session.displayAuthor ?? "",
                cover: cover(key: key, path: session.coverPath))
            switch session.mediaMetadata {
            case .book(let book):
                metadata.narrator = book.narratorName
            case .podcast(let podcast):
                // The show, as the legacy app did; podcasts have no narrator.
                metadata.author = podcast.title
                if case .podcast(let show) = session.libraryItem?.media,
                    let published = show.episodes?.first(where: { $0.id == key.episodeId })?.publishedAt
                {
                    metadata.releaseDate = Date(timeIntervalSince1970: Double(published) / 1000)
                }
            case nil:
                break
            }
            return metadata
        }
        if includeRestored, let record = coordinator.restoredRecord, record.key == key {
            return Metadata(
                title: record.title ?? "", author: record.author ?? "", cover: cover(key: key, path: record.coverPath))
        }
        return nil
    }

    /// Published play state: playing while the coordinator plays, and also while loaded media stalls
    /// with play requested (published as buffering, elapsed time held), so the system offers pause
    /// for a stalled stream, including a stream's first buffering. Never before the engine has
    /// activated its audio session (``PlaybackCoordinator/isAudioSessionActive``; while starting, or
    /// loaded with the catch-up seek in flight): the first playing state activates the Now Playing
    /// session, and the engine's audio session must be active first (ADR 0006).
    static func state(of coordinator: PlaybackCoordinator, key: MediaKey, metadata: Metadata) -> NowPlayingState {
        var chapter: NowPlayingState.Chapter?
        if let timeline = coordinator.timeline, let index = coordinator.chapterIndex {
            let current = timeline.chapters[index]
            chapter = NowPlayingState.Chapter(
                title: current.title, index: index, count: timeline.chapters.count,
                range: TimelineRange(start: current.start, end: current.end))
        }
        let stalled =
            !coordinator.isPlaying && coordinator.isAudioSessionActive
            && coordinator.isBuffering && coordinator.isPlaybackRequested
        return NowPlayingState(
            key: key, title: metadata.title, author: metadata.author, narrator: metadata.narrator,
            releaseDate: metadata.releaseDate, chapter: chapter, duration: coordinator.duration,
            elapsed: coordinator.currentTime, rate: coordinator.rate, isPlaying: coordinator.isPlaying || stalled,
            artworkKey: metadata.cover.map(artworkKey(for:)), isBuffering: stalled)
    }

    private static func cover(key: MediaKey, path: String?) -> NowPlayingCover? {
        guard let path, !path.isEmpty else { return nil }
        return NowPlayingCover(key: key, coverPath: path)
    }

    /// Changes whenever the item or its cover path does, so the controller reloads the artwork.
    private static func artworkKey(for cover: NowPlayingCover) -> String {
        "\(cover.key.rawValue)|\(cover.coverPath)"
    }

    // MARK: NowPlayingCommandHandling

    /// The coordinator, or (once it's gone) ends the session and refuses the command.
    private func liveCoordinator() throws(NowPlayingCommandError) -> PlaybackCoordinator {
        guard let coordinator else {
            invalidate()
            throw .noPlayer
        }
        return coordinator
    }

    public func play() async throws {
        try await liveCoordinator().resume()
    }

    public func pause() async throws {
        try liveCoordinator().pause()
        refresh()
    }

    /// Pauses while playback is requested (also while starting or stalled), else resumes.
    public func togglePlayPause() async throws {
        let coordinator = try liveCoordinator()
        if coordinator.isPlaybackRequested {
            coordinator.pause()
            refresh()
        } else {
            await coordinator.resume()
        }
    }

    /// Skips (and next track) go through ``PlaybackCoordinator/jump(by:)``, which adds up rapid
    /// skips and applies skips while starting after the resume position is resolved. Jumps and
    /// seeks while unloaded emit no event, so each command republishes.
    public func skipForward(by seconds: Double) async throws {
        try await liveCoordinator().jump(by: Self.nonNegative(seconds))
        refresh()
    }

    public func skipBackward(by seconds: Double) async throws {
        try await liveCoordinator().jump(by: -Self.nonNegative(seconds))
        refresh()
    }

    public func seek(to time: Double) async throws {
        try await liveCoordinator().seek(to: time)
        refresh()
    }

    public func setRate(_ rate: Double) async throws {
        try liveCoordinator().setRate(rate)
        // `setRate` emits no event; publish the new rate now rather than after the observation hop.
        refresh()
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }
}

/// The cover behind the current artwork key, read by the controller's artwork provider off the main
/// actor. Holds only the latest one: a stale load finds nothing and the controller ignores it anyway.
private final class CoverRegistry: Sendable {
    private let current = Mutex<(artworkKey: String, cover: NowPlayingCover)?>(nil)

    func set(_ artworkKey: String?, cover: NowPlayingCover?) {
        current.withLock { current in
            if let artworkKey, let cover { current = (artworkKey, cover) } else { current = nil }
        }
    }

    func cover(for artworkKey: String) -> NowPlayingCover? {
        current.withLock { $0?.artworkKey == artworkKey ? $0?.cover : nil }
    }
}
