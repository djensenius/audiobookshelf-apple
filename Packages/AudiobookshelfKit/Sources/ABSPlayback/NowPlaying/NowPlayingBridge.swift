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
///   (which changes without an event) and the Now Playing settings are observed with Observation,
///   so a change in the app's settings applies at runtime. No item clears the session.
/// - **Commands.** Remote commands arrive through the controller, which refuses them without an
///   item (``NowPlayingCommandError/noPlayer``) and refuses seeks while seeking from media controls
///   is off. Skips and next/previous track jump by the interval from the user's settings.
/// - **Ownership.** The composition root owns the bridge. The bridge holds the coordinator weakly,
///   and the coordinator holds only a weak observer, so neither keeps the other alive. The bridge
///   owns the controller, whose command handler (this bridge) is weak.
/// - **Threading.** Main actor only. Artwork loads run off the main actor.
///
/// The app's composition root (`AppEnvironment`, P3-04 #44) creates one with
/// ``init(coordinator:settings:coverProvider:entityIdentifiers:)`` once the coordinator exists and
/// keeps it for the coordinator's lifetime; calling ``invalidate()`` (or releasing it) ends the
/// session. When the user starts playback in the app in the foreground, it calls
/// ``requestSystemPrimary()``.
@available(iOSApplicationExtension, unavailable)
@MainActor
public final class NowPlayingBridge: NowPlayingCommandHandling {
    private weak var coordinator: PlaybackCoordinator?
    let controller: NowPlayingController
    private let readSettings: @MainActor () -> NowPlayingSettings
    private let covers: CoverRegistry
    private var observerToken: PlaybackObserverToken?
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
    public func requestSystemPrimary() async {
        await controller.requestSystemPrimary()
    }

    // MARK: State

    /// Publishes the coordinator's current state; clears the session when there is no item.
    func refresh() {
        guard !isInvalidated else { return }
        guard let coordinator else {
            invalidate()
            return
        }
        let state = Self.state(of: coordinator)
        covers.set(state?.artworkKey, cover: state.flatMap { Self.cover(of: coordinator, key: $0.key) })
        controller.update(state)
    }

    /// Reads the settings and the coordinator's rate under observation; either changing republishes.
    private func trackSettingsAndRate() {
        guard !isInvalidated else { return }
        let settings = withObservationTracking {
            _ = coordinator?.rate
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

    static func state(of coordinator: PlaybackCoordinator) -> NowPlayingState? {
        guard let key = coordinator.mediaKey else { return nil }
        let session = coordinator.session
        let record = coordinator.restoredRecord
        var narrator: String?
        if case .book(let metadata) = session?.mediaMetadata { narrator = metadata.narratorName }
        var chapter: NowPlayingState.Chapter?
        if let timeline = coordinator.timeline, let index = coordinator.chapterIndex {
            let current = timeline.chapters[index]
            chapter = NowPlayingState.Chapter(
                title: current.title, index: index, count: timeline.chapters.count,
                range: TimelineRange(start: current.start, end: current.end))
        }
        return NowPlayingState(
            key: key, title: session?.displayTitle ?? record?.title ?? "",
            author: session?.displayAuthor ?? record?.author ?? "", narrator: narrator, chapter: chapter,
            duration: coordinator.duration, elapsed: coordinator.currentTime, rate: coordinator.rate,
            isPlaying: coordinator.isPlaying, artworkKey: cover(of: coordinator, key: key).map(artworkKey(for:)))
    }

    private static func cover(of coordinator: PlaybackCoordinator, key: MediaKey) -> NowPlayingCover? {
        guard let path = coordinator.session?.coverPath ?? coordinator.restoredRecord?.coverPath, !path.isEmpty
        else { return nil }
        return NowPlayingCover(key: key, coverPath: path)
    }

    /// Changes whenever the item or its cover path does, so the controller reloads the artwork.
    private static func artworkKey(for cover: NowPlayingCover) -> String {
        "\(cover.key.rawValue)|\(cover.coverPath)"
    }

    // MARK: NowPlayingCommandHandling

    public func play() async {
        await coordinator?.resume()
    }

    public func pause() async {
        coordinator?.pause()
    }

    public func togglePlayPause() async {
        guard let coordinator else { return }
        if coordinator.isPlaying {
            coordinator.pause()
        } else {
            await coordinator.resume()
        }
    }

    public func skipForward(by seconds: Double) async {
        await jump(by: Self.nonNegative(seconds))
    }

    public func skipBackward(by seconds: Double) async {
        await jump(by: -Self.nonNegative(seconds))
    }

    public func seek(to time: Double) async {
        await coordinator?.seek(to: time)
    }

    public func setRate(_ rate: Double) async {
        coordinator?.setRate(rate)
        // `setRate` emits no event; publish the new rate now rather than after the observation hop.
        refresh()
    }

    private func jump(by offset: Double) async {
        guard let coordinator else { return }
        let time = coordinator.currentTime
        let target =
            if let timeline = coordinator.timeline {
                offset >= 0
                    ? timeline.jumpForward(from: time, by: offset) : timeline.jumpBackward(from: time, by: -offset)
            } else {
                max(time + offset, 0)
            }
        await coordinator.seek(to: target)
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
