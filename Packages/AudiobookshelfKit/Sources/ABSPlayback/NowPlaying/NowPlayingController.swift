import ABSCore
import ABSData
import AppIntents
import Foundation
import NowPlaying

/// Maps a media key to the App Intents entities it represents (for example a `BookEntity`), so Siri
/// and Shortcuts can link Now Playing to the app's entities. Supplied by the composition root;
/// ABSPlayback never imports the entity types (ADR 0006).
public typealias NowPlayingEntityIdentifiers = @Sendable (MediaKey) -> [EntityIdentifier]

/// Errors a remote command reports back to the system.
public enum NowPlayingCommandError: Error, Equatable {
    /// Nothing is playing, or the command handler is gone.
    case noPlayer
    /// A seek arrived while seeking from media controls is off.
    case seekingDisabled
}

/// Publishes the player's state to the system Now Playing surfaces through the NowPlaying framework
/// (`MediaSession`) and routes remote commands to a ``NowPlayingCommandHandling`` (ADR 0006).
///
/// Updates are state-driven: call ``update(_:)`` whenever the player's state changes; each call
/// republishes only what changed. Elapsed time is pushed only when the play state or rate changes,
/// on a seek or jump (elapsed time off the extrapolated position by more than
/// ``elapsedTolerance``), or when the item or chapter changes; between those the system extrapolates
/// from the last snapshot, so periodic ticks publish nothing.
///
/// Wiring to `PlaybackCoordinator` (P2-06a) is a later step. Its events map as follows; each builds a
/// ``NowPlayingState`` from the coordinator's current properties (`mediaKey`, `currentTime`,
/// `duration`, `rate`, `isPlaying`, `chapter`/`chapterIndex`/`chapterRange`, the session's
/// metadata and cover) and passes it to ``update(_:)``:
///
/// | Event | Effect |
/// | --- | --- |
/// | `itemChanged(key)` | `key` set: new item, paused, metadata and artwork reload. `nil`: ``clear()``. |
/// | `loaded(time:)` | Paused at `time` with the session's duration and chapter. |
/// | `playbackStarted` | Playing at `rate`; also call ``requestSystemPrimary()`` on iOS when the user started playback in the foreground. |
/// | `paused(time:)` | Paused at `time`. |
/// | `didSeek(time:)` | Elapsed `time`; detected as a seek and pushed. |
/// | `tick(time:)` | Elapsed `time`; publishes only on a chapter change (or drift past the tolerance). |
/// | `ended` | Paused at the end; the item stays visible until the session closes. |
/// | `failed` | Paused at the last position; the session stays until it closes or another item plays. |
/// | `sessionWillClose` with reason `.stopped` or `.loadFailed` | ``clear()``. With `.itemChanged` the next item's state replaces it. |
///
/// Rate changes made through `setRate` don't emit an event; the integration also updates on the
/// coordinator's observed `rate`. Settings changes are applied by assigning ``settings``.
@MainActor
public final class NowPlayingController {
    /// Elapsed time may drift this far (seconds) from the extrapolated position before it's
    /// republished; larger differences are seeks or jumps.
    public static let elapsedTolerance: Double = 1

    /// Receives remote commands. Held weakly: the player usually owns this controller.
    public weak var commandHandler: (any NowPlayingCommandHandling)?

    /// Jump intervals, seeking and chapter-track mode. Changes republish the commands and metadata
    /// right away.
    public var settings: NowPlayingSettings {
        didSet {
            if settings != oldValue { publish() }
        }
    }

    /// The last state passed to ``update(_:)``; `nil` when cleared.
    public private(set) var state: NowPlayingState?

    private let makeSession: @MainActor () -> any NowPlayingSessionPublishing
    private let artworkProvider: NowPlayingArtworkProvider
    private let entityIdentifiers: NowPlayingEntityIdentifiers
    private let now: @Sendable () -> Date

    private var session: (any NowPlayingSessionPublishing)?
    private(set) var publishedContent: NowPlayingContentDescriptor?
    private(set) var publishedCommands: NowPlayingCommandSet?
    private(set) var publishedTiming: Timing?
    private var cachedEntityIdentifiers: (key: MediaKey, identifiers: [EntityIdentifier])?

    /// Artwork for ``NowPlayingState/artworkKey`` of the current item, once loaded.
    private var loadedArtwork: NowPlayingContentDescriptor.LoadedArtwork?
    /// The item and artwork key ``artworkTask`` loads, or the last one requested.
    private var artworkRequest: ArtworkRequest?
    private var artworkGeneration = 0
    private(set) var artworkTask: Task<Void, Never>?
    private(set) var activationTask: Task<Void, Never>?

    struct Timing: Equatable {
        var elapsed: Double
        var rate: Double
        var isPlaying: Bool
        var timestamp: Date
    }

    private struct ArtworkRequest: Equatable {
        var key: MediaKey
        var artworkKey: String?
    }

    /// - Parameters:
    ///   - artworkProvider: Loads cover data for ``NowPlayingState/artworkKey``.
    ///   - entityIdentifiers: App Intents entities for an item.
    ///   - now: The clock used to timestamp elapsed time.
    public convenience init(
        commandHandler: (any NowPlayingCommandHandling)?,
        settings: NowPlayingSettings,
        artworkProvider: @escaping NowPlayingArtworkProvider,
        entityIdentifiers: @escaping NowPlayingEntityIdentifiers,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            commandHandler: commandHandler, settings: settings, artworkProvider: artworkProvider,
            entityIdentifiers: entityIdentifiers, now: now, makeSession: { MediaSessionPublisher() })
    }

    init(
        commandHandler: (any NowPlayingCommandHandling)?,
        settings: NowPlayingSettings,
        artworkProvider: @escaping NowPlayingArtworkProvider,
        entityIdentifiers: @escaping NowPlayingEntityIdentifiers,
        now: @escaping @Sendable () -> Date,
        makeSession: @escaping @MainActor () -> any NowPlayingSessionPublishing
    ) {
        self.commandHandler = commandHandler
        self.settings = settings
        self.artworkProvider = artworkProvider
        self.entityIdentifiers = entityIdentifiers
        self.now = now
        self.makeSession = makeSession
    }

    /// Whether a session is published.
    public var isActive: Bool { session != nil }

    /// Publishes `state`, starting a session if there is none; `nil` is the same as ``clear()``.
    public func update(_ state: NowPlayingState?) {
        guard let state else {
            clear()
            return
        }
        self.state = state
        loadArtworkIfNeeded(for: state)
        if session == nil {
            let session = makeSession()
            self.session = session
            publish()
            activationTask = Task {
                do {
                    try await session.becomeApplicationPrimary()
                } catch {
                    Log.playback.error("Now Playing: couldn't become application primary: \(error, privacy: .public)")
                }
            }
        } else {
            publish()
        }
    }

    /// Removes everything from the system surfaces and ends the session (stop, `sessionWillClose`).
    public func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration += 1
        artworkRequest = nil
        loadedArtwork = nil
        activationTask?.cancel()
        activationTask = nil
        if let session {
            session.setCommands([])
            session.setPlaybackSnapshot(nil)
            session.setContent(nil)
        }
        session = nil
        state = nil
        publishedContent = nil
        publishedCommands = nil
        publishedTiming = nil
        cachedEntityIdentifiers = nil
    }

    /// Asks to become the system's Now Playing app (Lock Screen, Control Center). iOS only, and only
    /// effective while the app is in the foreground, so call it when the user starts playback in the
    /// app. Does nothing on macOS or without a session. Failures are logged, never thrown, so they
    /// never block playback.
    public func requestSystemPrimary() async {
        guard let session else { return }
        do {
            try await session.becomeSystemPrimary()
        } catch {
            Log.playback.error("Now Playing: couldn't become system primary: \(error, privacy: .public)")
        }
    }

    // MARK: Commands

    func perform(_ command: NowPlayingCommand) async throws {
        guard let handler = commandHandler, let state else { throw NowPlayingCommandError.noPlayer }
        switch command {
        case .play: await handler.play()
        case .pause: await handler.pause()
        case .togglePlayPause: await handler.togglePlayPause()
        case .skipForward(let seconds): await handler.skipForward(by: seconds)
        case .skipBackward(let seconds): await handler.skipBackward(by: seconds)
        // Next and previous track jump, as in the legacy app (AirPods double and triple press).
        case .nextTrack: await handler.skipForward(by: settings.jumpForwardTime)
        case .previousTrack: await handler.skipBackward(by: settings.jumpBackwardsTime)
        case .seek(let position):
            guard settings.allowSeekingOnMediaControls else { throw NowPlayingCommandError.seekingDisabled }
            await handler.seek(to: globalTime(forPublished: position, in: state))
        case .changeRate(let rate): await handler.setRate(rate)
        }
    }

    /// Global time for a position on the published timeline (chapter-relative in chapter-track mode).
    private func globalTime(forPublished position: Double, in state: NowPlayingState) -> Double {
        if settings.chapterTrack, let chapter = state.chapter {
            return chapter.range.time(forElapsed: position)
        }
        return TimelineRange(start: 0, end: max(state.duration, 0)).time(forElapsed: position)
    }

    // MARK: Publishing

    private func publish() {
        guard let session, let state else { return }

        let content = contentDescriptor(for: state)
        let previousContent = publishedContent
        if content != previousContent {
            session.setContent(content.makeContent(entityIdentifiers: identifiers(for: state.key)))
            publishedContent = content
        }

        let commands = NowPlayingCommandSet(
            skipForwardInterval: settings.jumpForwardTime, skipBackwardInterval: settings.jumpBackwardsTime,
            supportedRates: settings.supportedRates, canSeek: settings.allowSeekingOnMediaControls)
        if commands != publishedCommands {
            session.setCommands(commands.makeCommands { [weak self] command in try await self?.perform(command) })
            publishedCommands = commands
        }

        // A new item or chapter (in chapter-track mode, a new time base) always gets a fresh snapshot.
        let timeBaseChanged =
            previousContent?.id != content.id || previousContent?.chapter != content.chapter
            || previousContent?.duration != content.duration
        let elapsed = publishedElapsed(for: state)
        if timeBaseChanged || needsTimingUpdate(elapsed: elapsed, state: state) {
            let timing = Timing(elapsed: elapsed, rate: state.rate, isPlaying: state.isPlaying, timestamp: now())
            session.setPlaybackSnapshot(
                MediaPlaybackSnapshot(
                    state: timing.isPlaying ? .playing(rate: Float(timing.rate)) : .paused,
                    elapsedTime: timing.elapsed, timestamp: timing.timestamp))
            publishedTiming = timing
        }
    }

    private func needsTimingUpdate(elapsed: Double, state: NowPlayingState) -> Bool {
        guard let last = publishedTiming else { return true }
        if last.isPlaying != state.isPlaying || last.rate != state.rate { return true }
        let expected =
            last.isPlaying ? last.elapsed + now().timeIntervalSince(last.timestamp) * last.rate : last.elapsed
        return abs(elapsed - expected) > Self.elapsedTolerance
    }

    private func contentDescriptor(for state: NowPlayingState) -> NowPlayingContentDescriptor {
        let chapterTrack = settings.chapterTrack ? state.chapter : nil
        let duration = chapterTrack?.range.duration ?? state.duration
        return NowPlayingContentDescriptor(
            id: state.key.rawValue,
            isPodcastEpisode: state.isPodcastEpisode,
            title: chapterTrack?.title ?? state.title,
            author: state.author,
            narrator: state.isPodcastEpisode ? nil : state.narrator,
            releaseDate: state.isPodcastEpisode ? state.releaseDate : nil,
            chapter: state.chapter.map { .init(current: $0.index + 1, total: $0.count) },
            duration: duration.isFinite && duration > 0 ? duration : nil,
            artwork: loadedArtwork.flatMap { $0.key == state.artworkKey ? $0 : nil })
    }

    private func publishedElapsed(for state: NowPlayingState) -> Double {
        if settings.chapterTrack, let chapter = state.chapter {
            return chapter.range.elapsed(at: state.elapsed)
        }
        return state.elapsed.isFinite ? max(state.elapsed, 0) : 0
    }

    private func identifiers(for key: MediaKey) -> [EntityIdentifier] {
        if let cached = cachedEntityIdentifiers, cached.key == key { return cached.identifiers }
        let identifiers = entityIdentifiers(key)
        cachedEntityIdentifiers = (key, identifiers)
        return identifiers
    }

    // MARK: Artwork

    private func loadArtworkIfNeeded(for state: NowPlayingState) {
        let request = ArtworkRequest(key: state.key, artworkKey: state.artworkKey)
        guard request != artworkRequest else { return }
        artworkRequest = request
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration += 1
        loadedArtwork = nil
        guard let artworkKey = state.artworkKey else { return }
        let generation = artworkGeneration
        let provider = artworkProvider
        artworkTask = Task { [weak self] in
            let data = await provider(artworkKey)
            self?.artworkLoaded(data, key: artworkKey, generation: generation)
        }
    }

    private func artworkLoaded(_ data: Data?, key: String, generation: Int) {
        // A newer item or artwork key was requested (or the session cleared) while this one loaded.
        guard generation == artworkGeneration, let data else { return }
        loadedArtwork = .init(key: key, data: data)
        publish()
    }
}
