import ABSAPI
import ABSCore
import Foundation
import Observation

private let logger = Log.playback

/// What ADR 0007 Decision 3 does about an item or player failure. The HTTP status is only a hint:
/// until the session check (`GET /api/session/{id}`) exists, a failure that might mean "session
/// gone" spends the readiness retries first and then escalates to a rebuild, as the ADR does
/// when that budget runs out.
enum PlaybackRecoveryAction: Sendable, Hashable {
    /// Segment-readiness retries: re-seek the same item (the engine recreates a failed item or
    /// player), then escalate to rebuilds.
    case retry
    /// Session rebuilds only. Network loss, until the network wait exists: the ADR's "path
    /// satisfied, still failing" rule.
    case rebuild
    /// The 401 path: one token refresh, then a rebuild.
    case refresh
    /// Not recoverable: shown at once. Decode and unsupported formats belong to the direct-play
    /// to HLS fallback, which isn't built yet.
    case fatal
}

extension PlaybackFailure {
    var recoveryAction: PlaybackRecoveryAction {
        switch kind {
        case .http(status: 401): .refresh
        case .http(let status) where status == 404 || status == 408 || status == 429 || (500..<600).contains(status):
            .retry
        case .http: .fatal
        case .unknown: .retry
        case .network: .rebuild
        case .tls, .decode, .unsupported, .cancelled: .fatal
        }
    }
}

/// How a recovery's session rebuild ended.
enum PlaybackRecoveryRebuild: Sendable, Equatable {
    /// The new session loaded; `generation` is the coordinator's for it.
    case recovered(generation: Int)
    /// The attempt failed; the coordinator is unloaded at `generation`, the rebuild's own.
    case failed(PlaybackCoordinatorError, generation: Int)
    /// Something else (a play, stop or cancellation) replaced it.
    case superseded
}

/// What recovery needs from the coordinator, which owns the engine and sessions.
@MainActor
struct PlaybackRecoveryHost {
    /// The coordinator's current generation: any other value supersedes the episode.
    var generation: () -> Int
    /// The latest intended position: a pending or in-flight seek's target, else the saved
    /// position, never a new session's `currentTime`.
    var target: () -> Double
    /// Seeks the engine to `target`; on a failed item or player the engine rebuilds them.
    var reseek: (_ target: Double) async -> SeekResult
    /// Starts the engine after a successful re-seek.
    var play: () -> Void
    /// Closes the session and starts a new one at `target`, playing only if `playing`. The attempt
    /// takes the next generation (`generation() + 1`) at once, before suspending.
    var rebuild: (_ target: Double, _ playing: Bool) async -> PlaybackRecoveryRebuild
    /// Refreshes the access token once; returns the error that stops recovery, if any.
    var refresh: () async -> PlaybackCoordinatorError?
    /// Surfaces `error` and ends recovery.
    var giveUp: (PlaybackCoordinatorError) -> Void
}

/// Recovers from item and player failures per ADR 0007 Decision 3 (Part of #148).
///
/// - **Episode.** A failure starts an episode, which keeps the budgets across failures until
///   ``episodeReset`` of confirmed playback, a give-up, or anything that changes the
///   coordinator's generation (a play, stop or restart).
/// - **Budgets.** Up to ``retryDelays``.count re-seeks with that backoff, then up to
///   ``rebuildDelays``.count session rebuilds with that backoff. Once a rebuild has run, the item
///   is new, so recovery only rebuilds. Then it gives up with
///   ``PlaybackCoordinatorError/recoveryExhausted``.
/// - **401.** The first one in an episode refreshes the token, then rebuilds (counted against the
///   rebuild budget). A second one stops with ``PlaybackCoordinatorError/streamRejected``; there is
///   never a second refresh.
/// - **One run at a time.** A failure while a run is in flight only updates its cause.
/// - **Supersession.** Each await rechecks the generation and the run's token: a stopped, replaced
///   or restarted item is never recovered. A user seek while loaded takes over
///   (``yieldToSeek()``); one while unloaded moves ``PlaybackRecoveryHost/target``, which every
///   attempt reads afresh. A stale recovery seek never writes a position: the coordinator
///   publishes only the user's.
@MainActor
@Observable
final class PlaybackRecovery {
    /// Segment-readiness backoff.
    static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    /// Session-rebuild backoff.
    static let rebuildDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    /// Confirmed playback that ends an episode.
    static let episodeReset: TimeInterval = 30

    private enum Cause: Equatable {
        case failure(PlaybackFailure)
        /// A rebuild's `/play` failed transiently: rebuild again.
        case rebuildFailed
    }

    private struct Episode {
        var generation: Int
        var cause: Cause
        var wantsPlay: Bool
        var retries = 0
        var rebuilds = 0
        var refreshed = false
        var playingSince: Date?
        /// A failure arrived while the attempt in flight was awaited: the attempt failed.
        var failedDuringAttempt = false
    }

    @ObservationIgnored var host: PlaybackRecoveryHost?
    private let wait: @Sendable (Duration) async -> Void
    // Observed, as ``wantsPlay(at:)`` feeds the coordinator's play intent.
    private var episode: Episode?
    private var isRunning = false
    @ObservationIgnored private var token = 0
    /// The generation of the rebuild in flight: failures at it are its new item's.
    @ObservationIgnored private var attemptGeneration: Int?

    init(wait: @escaping @Sendable (Duration) async -> Void) {
        self.wait = wait
    }

    /// Recovers from `failure` of the item loaded at `generation`. `wasPlaying` is whether play was
    /// requested when it failed.
    func recover(from failure: PlaybackFailure, generation: Int, wasPlaying: Bool) {
        guard let host else { return }
        if isRunning, var episode, generation == attemptGeneration || episode.generation == generation {
            // The attempt in flight failed; its run reads the cause when the attempt returns.
            episode.cause = .failure(failure)
            episode.failedDuringAttempt = true
            self.episode = episode
            return
        }
        if var episode, episode.generation == generation {
            episode.cause = .failure(failure)
            episode.wantsPlay = wasPlaying
            episode.playingSince = nil
            self.episode = episode
        } else {
            episode = Episode(generation: generation, cause: .failure(failure), wantsPlay: wasPlaying)
        }
        // A run for an older generation (if any) is superseded.
        token += 1
        isRunning = false
        // Not recoverable: shown at once, as without recovery.
        if let episode, case .surface(let error) = step(for: episode) { return giveUp(error, host) }
        let run = token
        isRunning = true
        Task { await self.run(run, host: host) }
    }

    /// A user seek while loaded takes over the run in flight; returns whether it should play once
    /// it lands. The episode and its budgets stay.
    func yieldToSeek() -> Bool {
        guard isRunning, let episode else { return false }
        token += 1
        isRunning = false
        return episode.wantsPlay
    }

    /// A pause or resume changes whether recovery plays when it succeeds; a pause also ends the
    /// confirmed playback interval.
    func notePlayIntent(_ wantsPlay: Bool) {
        episode?.wantsPlay = wantsPlay
        if !wantsPlay { notePlaybackStopped() }
    }

    /// Whether a run in flight for the item at `generation` will play it once it succeeds: the
    /// user's play intent while the engine, having failed, holds none.
    func wantsPlay(at generation: Int) -> Bool {
        guard isRunning, let episode else { return false }
        return episode.generation == generation && episode.wantsPlay
    }

    /// Playback left the playing state (a pause, a system pause, buffering): the
    /// ``episodeReset`` interval must start again.
    func notePlaybackStopped() {
        if episode?.playingSince != nil { episode?.playingSince = nil }
    }

    /// A tick while playing at `generation`: ends the episode after ``episodeReset`` of it.
    func notePlaying(at date: Date, generation: Int) {
        guard !isRunning, let episode, episode.generation == generation else { return }
        guard let since = episode.playingSince else {
            self.episode?.playingSince = date
            return
        }
        if date.timeIntervalSince(since) >= Self.episodeReset { self.episode = nil }
    }

    private func isCurrent(_ run: Int, _ host: PlaybackRecoveryHost) -> Bool {
        run == token && episode?.generation == host.generation()
    }

    private func run(_ run: Int, host: PlaybackRecoveryHost) async {
        defer { if run == token { isRunning = false } }
        while isCurrent(run, host), var episode {
            switch step(for: episode) {
            case .surface(let error):
                return giveUp(error, host)
            case .reseek:
                let delay = Self.retryDelays[episode.retries]
                episode.retries += 1
                self.episode = episode
                await wait(delay)
                guard isCurrent(run, host) else { return }
                self.episode?.failedDuringAttempt = false
                let result = await host.reseek(host.target())
                guard isCurrent(run, host) else { return }
                if result == .completed, self.episode?.failedDuringAttempt == false {
                    if self.episode?.wantsPlay == true { host.play() }
                    return
                }
            case .refresh:
                guard episode.rebuilds < Self.rebuildDelays.count else { return giveUp(.recoveryExhausted, host) }
                episode.refreshed = true
                self.episode = episode
                let error = await host.refresh()
                guard isCurrent(run, host) else { return }
                if let error { return giveUp(error, host) }
                guard await rebuild(run, host) else { return }
            case .rebuild:
                guard episode.rebuilds < Self.rebuildDelays.count else { return giveUp(.recoveryExhausted, host) }
                guard await rebuild(run, host) else { return }
            }
        }
    }

    private enum Step {
        case reseek, rebuild, refresh
        case surface(PlaybackCoordinatorError)
    }

    private func step(for episode: Episode) -> Step {
        guard case .failure(let failure) = episode.cause else { return .rebuild }
        switch failure.recoveryAction {
        case .fatal: return .surface(.playback(failure))
        case .refresh: return episode.refreshed ? .surface(.streamRejected) : .refresh
        case .retry where episode.rebuilds == 0 && episode.retries < Self.retryDelays.count: return .reseek
        case .retry, .rebuild: return .rebuild
        }
    }

    /// One rebuild attempt; returns whether the run goes on (the attempt failed recoverably).
    private func rebuild(_ run: Int, _ host: PlaybackRecoveryHost) async -> Bool {
        guard var episode else { return false }
        let delay = Self.rebuildDelays[episode.rebuilds]
        episode.rebuilds += 1
        self.episode = episode
        await wait(delay)
        guard isCurrent(run, host) else { return false }
        self.episode?.failedDuringAttempt = false
        attemptGeneration = host.generation() + 1
        let outcome = await host.rebuild(host.target(), self.episode?.wantsPlay ?? false)
        attemptGeneration = nil
        guard run == token else { return false }
        switch outcome {
        case .superseded:
            return false
        case .recovered(let generation):
            self.episode?.generation = generation
            // The new item failed before the attempt returned: that attempt failed.
            return self.episode?.failedDuringAttempt == true
        case .failed(let error, let generation):
            self.episode?.generation = generation
            logger.info("Recovery rebuild failed (\(String(describing: error), privacy: .private))")
            switch error {
            case .playback(let failure): self.episode?.cause = .failure(failure)
            case .sessionStartFailed(let apiError) where apiError.isTransient: self.episode?.cause = .rebuildFailed
            default:
                giveUp(error, host)
                return false
            }
            return true
        }
    }

    private func giveUp(_ error: PlaybackCoordinatorError, _ host: PlaybackRecoveryHost) {
        episode = nil
        host.giveUp(error)
    }
}
