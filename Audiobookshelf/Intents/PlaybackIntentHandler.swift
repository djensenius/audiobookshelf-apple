import ABSAppModel
import ABSCore
import ABSPlayback

/// Runs the shared playback intents (`AudiobookshelfShared/Intents`) on the app's player, the
/// ``PlaybackCoordinator`` the player screens and CarPlay use, through ``PlaybackIntentPerformer``,
/// which holds the tested mapping. Whoever builds the coordinator registers one with
/// ``PlaybackIntentRouter``.
@MainActor
final class PlaybackIntentHandler: PlaybackIntentHandling {
    private let playback: any PlayerPlaybackControlling
    private let settings: AppSettings
    private let sleepTimer: @MainActor () -> (any SleepTimerStarting)?
    private let ready: @MainActor () async -> Void

    /// - Parameters:
    ///   - playback: The signed-in account's playback (``CurrentPlayback`` in the app).
    ///   - settings: The jump intervals used when an intent doesn't give one.
    ///   - sleepTimer: The current playback's sleep timer, read for each intent, since each account
    ///     session has its own.
    ///   - ready: Awaited before each command. An intent can launch the app without a scene, and
    ///     only scenes start the session lifecycle, so the app passes `SessionLifecycle.start()`,
    ///     which restores the saved account's session and last-played item once.
    init(
        playback: any PlayerPlaybackControlling, settings: AppSettings,
        sleepTimer: @escaping @MainActor () -> (any SleepTimerStarting)? = { nil },
        ready: @escaping @MainActor () async -> Void = {}
    ) {
        self.playback = playback
        self.settings = settings
        self.sleepTimer = sleepTimer
        self.ready = ready
    }

    /// The performer, once `ready` has returned.
    private func performer() async -> PlaybackIntentPerformer {
        await ready()
        return PlaybackIntentPerformer(playback: playback, sleepTimer: sleepTimer(), settings: settings)
    }

    func resume() async throws {
        do throws(PlaybackIntentFailure) {
            try await performer().resume()
        } catch {
            throw PlaybackIntentError(error)
        }
    }

    func pause() async throws {
        do throws(PlaybackIntentFailure) {
            try await performer().pause()
        } catch {
            throw PlaybackIntentError(error)
        }
    }

    func togglePlayback() async throws {
        do throws(PlaybackIntentFailure) {
            try await performer().togglePlayPause()
        } catch {
            throw PlaybackIntentError(error)
        }
    }

    func jump(forward: Bool, seconds: Int?) async throws {
        do throws(PlaybackIntentFailure) {
            try await performer().jump(forward: forward, seconds: seconds)
        } catch {
            throw PlaybackIntentError(error)
        }
    }

    func setSleepTimer(minutes: Int?) async throws {
        do throws(PlaybackIntentFailure) {
            try await performer().setSleepTimer(minutes.map(PlaybackSleepRequest.minutes) ?? .endOfChapter)
        } catch {
            throw PlaybackIntentError(error)
        }
    }

    func setSpeed(_ rate: Double) async throws {
        do throws(PlaybackIntentFailure) {
            try await performer().setSpeed(rate)
        } catch {
            throw PlaybackIntentError(error)
        }
    }
}

extension PlaybackIntentError {
    /// The dialog for a ``PlaybackIntentPerformer`` failure.
    init(_ failure: PlaybackIntentFailure) {
        switch failure {
        case .nothingToResume: self = .nothingToResume
        case .nothingPlaying: self = .nothingPlaying
        case .sleepTimerUnavailable: self = .sleepTimerUnavailable
        case .noChapterEnd: self = .noChapterEnd
        case .jumpFailed: self = .jumpFailed
        case .playbackFailed: self = .playbackFailed
        }
    }
}
