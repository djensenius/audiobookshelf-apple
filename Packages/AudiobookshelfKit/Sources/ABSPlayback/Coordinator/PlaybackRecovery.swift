import ABSAPI
import ABSCore
import Foundation
import Observation

private let logger = Log.playback

/// What ADR 0007 Decision 3 does about an item or player failure. The HTTP status is only a hint:
/// the session check (``PlaybackSessionStatus``) before an attempt can turn a re-seek into a
/// rebuild (session gone), a rebuild into a re-seek (session alive), or either into the 401 path.
enum PlaybackRecoveryAction: Sendable, Hashable {
    /// Segment-readiness retries: re-seek the same item (the engine recreates a failed item or
    /// player), then escalate to rebuilds.
    case retry
    /// Network loss: once the path is satisfied, a re-seek if the session is alive, else rebuilds.
    case rebuild
    /// The 401 path: one token refresh, then a rebuild.
    case refresh
    /// A decode or format error: on direct play, one rebuild with `forceTranscode` (the direct-play
    /// to HLS fallback); on HLS, or once that fallback has run, shown at once.
    case transcode
    /// Not recoverable: shown at once.
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
        case .decode, .unsupported: .transcode
        case .tls, .cancelled: .fatal
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
    /// Closes the session and starts a new one at `target`, playing only if `playing`, as an HLS
    /// transcode if `forceTranscode`. The attempt takes the next generation (`generation() + 1`)
    /// at once, before suspending.
    var rebuild: (_ target: Double, _ playing: Bool, _ forceTranscode: Bool) async -> PlaybackRecoveryRebuild
    /// Whether the direct-play to HLS fallback can still run: the item is direct play, and no
    /// forced transcode has run since the user's start.
    var canTranscode: () -> Bool
    /// Refreshes the access token once; returns the error that stops recovery, if any.
    var refresh: () async -> PlaybackCoordinatorError?
    /// Looks up the loaded session (`GET /api/session/{id}`); ``PlaybackSessionStatus/unknown``
    /// with none. A lookup that refreshed the token spends the episode's refresh.
    var checkSession: () async -> PlaybackSessionCheck
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
///   never a second refresh. A session lookup whose request refreshed the token spends that one
///   refresh too (#491). A decode, format or final error during the refresh, or the waits after
///   it, takes its own step instead of that rebuild.
/// - **Decode and format errors.** On direct play, one rebuild with `forceTranscode` (the HLS
///   fallback), counted against the rebuild budget; on HLS, or once the fallback has run since the
///   user's play, they surface at once.
/// - **Stalls.** A stall with no error (``PlaybackFailure/stalled``) is retried as a readiness
///   failure, but playback that resumes on its own before the attempt ends the run unspent.
/// - **Network and session.** Before each attempt, recovery waits while the network path is
///   unsatisfied (no budget is spent offline) for up to ``networkWaitLimit``, then gives up with
///   ``PlaybackCoordinatorError/recoveryExhausted``; once the path returns it skips that attempt's
///   backoff. Before a re-seek, and after the path returns, it checks the session (see
///   ``PlaybackRecoveryAction``).
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
    /// The longest wait for an unsatisfied network path.
    static let networkWaitLimit: Duration = .seconds(300)

    private enum Cause: Equatable {
        case failure(PlaybackFailure)
        /// A rebuild's `/play` failed transiently: rebuild again.
        case rebuildFailed
    }

    private struct Episode {
        /// Kept across seek takeovers and rebuilds; a new episode, after another item's failure or
        /// after one ended, gets a new one.
        let id: Int
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
    private let paths: (any NetworkPathSource)?
    // Observed, as ``wantsPlay(at:)`` feeds the coordinator's play intent.
    private var episode: Episode?
    private var isRunning = false
    /// The run waiting for an unsatisfied path; observed, as it feeds the player's waiting state.
    private var waitingRun: Int?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var lastEpisodeID = 0
    /// The generation of the rebuild in flight: failures at it are its new item's.
    @ObservationIgnored private var attemptGeneration: Int?

    /// - Parameter paths: The network path; `nil` treats it as always satisfied.
    init(wait: @escaping @Sendable (Duration) async -> Void, paths: (any NetworkPathSource)? = nil) {
        self.wait = wait
        self.paths = paths
    }

    /// Recovers from `failure` of the item loaded at `generation`. `wasPlaying` is whether play was
    /// requested when it failed.
    func recover(from failure: PlaybackFailure, generation: Int, wasPlaying: Bool) {
        guard let host else { return }
        if isRunning, var episode, generation == attemptGeneration || episode.generation == generation {
            // The attempt in flight, or the backoff before it, failed: its run reads the cause before
            // the attempt or when the attempt returns.
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
            lastEpisodeID += 1
            episode = Episode(
                id: lastEpisodeID, generation: generation, cause: .failure(failure), wantsPlay: wasPlaying)
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
        isRecovering(at: generation) && episode?.wantsPlay == true
    }

    /// Whether a run is in flight for the item at `generation`.
    func isRecovering(at generation: Int) -> Bool {
        isRunning && episode?.generation == generation
    }

    /// Whether the run in flight for the item at `generation` is waiting for the network (ADR 0007's
    /// "Waiting for network"): not once a seek, stop or newer run replaced it.
    func isWaitingForNetwork(at generation: Int) -> Bool {
        isRecovering(at: generation) && waitingRun != nil && waitingRun == token
    }

    /// Playback left the playing state (a pause, a system pause, buffering): the
    /// ``episodeReset`` interval must start again.
    func notePlaybackStopped() {
        if episode?.playingSince != nil { episode?.playingSince = nil }
    }

    /// A tick while playing at `generation`: playback resumed on its own, so a stall's run in flight
    /// ends, spending no budget before its attempt. Ends the episode after ``episodeReset`` of it.
    func notePlaying(at date: Date, generation: Int) {
        if isRunning, let episode, episode.generation == generation, episode.cause == .failure(.stalled) {
            logger.info("A stall resolved before recovery's attempt")
            token += 1
            isRunning = false
        }
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
        // The path came back during this attempt's lookup or backoff: retry at once.
        var cameBack = false
        while isCurrent(run, host), let current = episode {
            switch step(for: current) {
            case .surface(let error): return giveUp(error, host)
            // Out of attempts: never wait for the network first.
            case .rebuild where current.rebuilds >= Self.rebuildDelays.count,
                .refresh where current.rebuilds >= Self.rebuildDelays.count,
                .transcode where current.rebuilds >= Self.rebuildDelays.count:
                return giveUp(.recoveryExhausted, host)
            default: break
            }
            let network = await waitForNetwork(run)
            guard isCurrent(run, host) else { return }
            if network == .timedOut { return giveUp(.recoveryExhausted, host) }
            let returned = cameBack || network == .returned
            cameBack = false
            var session = PlaybackSessionStatus.unknown
            if returned || needsSessionCheck(current) {
                session = await checkSession(host)
                guard isCurrent(run, host) else { return }
            }
            guard let episode = self.episode else { return }
            let step = step(for: episode, session: session)
            let delay: Duration
            switch step {
            case .surface(let error): return giveUp(error, host)
            case .reseek: delay = Self.retryDelays[episode.retries]
            case .rebuild, .refresh, .transcode:
                guard episode.rebuilds < Self.rebuildDelays.count else { return giveUp(.recoveryExhausted, host) }
                delay = Self.rebuildDelays[episode.rebuilds]
            }
            // Back online: retry at once.
            if !returned {
                await wait(delay)
                guard isCurrent(run, host) else { return }
            }
            // The path may have dropped during the lookup or backoff: no attempt (or budget) offline.
            switch await waitForNetwork(run) {
            case .online: break
            case .returned:
                cameBack = true
                continue
            case .timedOut:
                guard isCurrent(run, host) else { return }
                return giveUp(.recoveryExhausted, host)
            }
            guard isCurrent(run, host) else { return }
            // A failure during the backoff (a decode error's fallback, a 401's refresh, a final
            // error) may call for another step: start over, with that step's budget and backoff.
            if let latest = self.episode, self.step(for: latest, session: session) != step { continue }
            switch step {
            case .surface: return
            case .reseek:
                self.episode?.retries += 1
                self.episode?.failedDuringAttempt = false
                let result = await host.reseek(host.target())
                guard isCurrent(run, host) else { return }
                if result == .completed, self.episode?.failedDuringAttempt == false {
                    if self.episode?.wantsPlay == true { host.play() }
                    return
                }
            case .refresh:
                self.episode?.refreshed = true
                // Failures until now were weighed above; ``rebuildAfterRefresh(_:_:)`` weighs the
                // ones during the refresh and its waits.
                self.episode?.failedDuringAttempt = false
                let error = await host.refresh()
                guard isCurrent(run, host) else { return }
                if let error { return giveUp(error, host) }
                guard await rebuildAfterRefresh(run, host) else { return }
            case .rebuild:
                guard await rebuild(run, host) else { return }
            case .transcode:
                guard await rebuild(run, host, forceTranscode: true) else { return }
            }
        }
    }

    private enum Step: Equatable {
        case reseek, rebuild, refresh, transcode
        case surface(PlaybackCoordinatorError)
    }

    /// The next attempt for `episode`, given what the session check found.
    private func step(for episode: Episode, session: PlaybackSessionStatus = .unknown) -> Step {
        guard case .failure(let failure) = episode.cause else { return .rebuild }
        let action = failure.recoveryAction
        if action == .fatal { return .surface(.playback(failure)) }
        // Once per play, and never from HLS: the error is the media's.
        if action == .transcode { return host?.canTranscode() == true ? .transcode : .surface(.playback(failure)) }
        if action == .refresh || session == .unauthorized {
            return episode.refreshed ? .surface(.streamRejected) : .refresh
        }
        // A gone session is never re-seeked: a rebuild starts a new one.
        let canReseek = episode.rebuilds == 0 && episode.retries < Self.retryDelays.count && session != .gone
        switch action {
        case .retry where canReseek: return .reseek
        case .rebuild where canReseek && session == .alive: return .reseek
        default: return .rebuild
        }
    }

    /// Whether the session decides the next attempt: before a re-seek, or one that could be.
    private func needsSessionCheck(_ episode: Episode) -> Bool {
        guard episode.rebuilds == 0, case .failure(let failure) = episode.cause else { return false }
        return step(for: episode) == .reseek || failure.recoveryAction == .rebuild
    }

    private enum NetworkWait {
        /// Satisfied without waiting.
        case online
        /// Satisfied after waiting.
        case returned
        case timedOut
    }

    /// Waits while the network path is unsatisfied, up to ``networkWaitLimit``; ``isWaitingForNetwork(at:)``
    /// meanwhile, while `run` is current.
    private func waitForNetwork(_ run: Int) async -> NetworkWait {
        guard let paths else { return .online }
        enum Event { case path(online: Bool), timedOut }
        let (events, sink) = AsyncStream<Event>.makeStream()
        let forward = Task {
            for await path in paths.paths() { sink.yield(.path(online: path.isOnline)) }
            sink.finish()
        }
        var timer: Task<Void, Never>?
        defer {
            forward.cancel()
            timer?.cancel()
            if waitingRun == run { waitingRun = nil }
        }
        for await event in events {
            switch event {
            case .path(online: true):
                return timer == nil ? .online : .returned
            case .path(online: false):
                guard timer == nil else { continue }
                logger.info("Recovery is waiting for the network")
                waitingRun = run
                timer = Task { [wait] in
                    await wait(Self.networkWaitLimit)
                    if !Task.isCancelled { sink.yield(.timedOut) }
                }
            case .timedOut:
                return .timedOut
            }
        }
        // The path source ended: don't wait on it.
        return timer == nil ? .online : .returned
    }

    /// The rebuild after a refresh, which the path may have dropped during: it waits for the path
    /// (no `/play` offline) and checks the session once it returns; a 401 then, the one refresh
    /// already spent, surfaces. The path may drop again during that lookup, so it is gated again
    /// before the rebuild (each wait has its own limit, as in ``run(_:host:)``). A failure during
    /// the refresh or those waits that needs its own step takes it instead of the rebuild, which
    /// would clear it (see ``failedForItsOwnStep``). Returns whether the run goes on.
    private func rebuildAfterRefresh(_ run: Int, _ host: PlaybackRecoveryHost) async -> Bool {
        while true {
            let network = await waitForNetwork(run)
            guard isCurrent(run, host) else { return false }
            switch network {
            case .online:
                // Back to the loop, with that step's budget and backoff; the refresh stays spent.
                if failedForItsOwnStep { return true }
                return await rebuild(run, host)
            case .timedOut:
                giveUp(.recoveryExhausted, host)
                return false
            case .returned:
                let session = await checkSession(host)
                guard isCurrent(run, host) else { return false }
                if session == .unauthorized {
                    giveUp(.streamRejected, host)
                    return false
                }
            }
        }
    }

    /// Whether a failure during the attempt in flight calls for something a rebuild doesn't do: a
    /// decode or format error's HLS fallback (or, on HLS, its error), or a final error. A 401 is
    /// not one: after a refresh it was the old token's, and the rebuild is its remedy.
    private var failedForItsOwnStep: Bool {
        guard let episode, episode.failedDuringAttempt, case .failure(let failure) = episode.cause else {
            return false
        }
        switch failure.recoveryAction {
        case .transcode, .fatal: return true
        case .retry, .rebuild, .refresh: return false
        }
    }

    /// One rebuild attempt, an HLS transcode if `forceTranscode`; returns whether the run goes on
    /// (the attempt failed recoverably).
    private func rebuild(_ run: Int, _ host: PlaybackRecoveryHost, forceTranscode: Bool = false) async -> Bool {
        guard episode != nil else { return false }
        self.episode?.rebuilds += 1
        self.episode?.failedDuringAttempt = false
        let attempt = host.generation() + 1
        attemptGeneration = attempt
        let outcome = await host.rebuild(host.target(), self.episode?.wantsPlay ?? false, forceTranscode)
        // A newer run's rebuild may have replaced the marker meanwhile.
        if attemptGeneration == attempt { attemptGeneration = nil }
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

    /// Looks up the session, charging a refresh its request made to the episode's one refresh,
    /// even if a user seek took the run over meanwhile; not to an episode that replaced it.
    private func checkSession(_ host: PlaybackRecoveryHost) async -> PlaybackSessionStatus {
        let episodeID = episode?.id
        let check = await host.checkSession()
        if check.refreshedToken, let episodeID, episode?.id == episodeID { episode?.refreshed = true }
        return check.status
    }

    private func giveUp(_ error: PlaybackCoordinatorError, _ host: PlaybackRecoveryHost) {
        episode = nil
        host.giveUp(error)
    }
}
