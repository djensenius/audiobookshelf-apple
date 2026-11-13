import ABSCore
import AVFoundation
import Observation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "AudioEngine")

/// Plays a ``PlaybackTimeline`` with an `AVQueuePlayer`, one item per track.
///
/// - The queue is built from ``PlaybackTimeline/tracks`` starting at the current track; a seek into
///   another track rebuilds it from the target track (ADR 0007). Global ↔ track time always goes
///   through the timeline.
/// - Seeks are numbered. Only the latest seek writes ``currentTime``; an older completion reports
///   ``SeekResult/superseded`` and never overwrites the position. ``pendingSeekTarget`` keeps the
///   latest target until a seek to it completes, so recovery can aim at the user's intent.
/// - ``defaultRate`` is set on the player before every `play()` and re-applied after it and after
///   item changes, because AVPlayer can reset the rate (interruptions, route changes).
@MainActor
@Observable
public final class AudioEngine: AudioEngineProtocol {
    public private(set) var state: PlaybackState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var currentTrackIndex: Int?
    public private(set) var defaultRate: Float = 1
    /// Output volume, `0...1` (the sleep timer fade). A replacement player gets it too.
    public private(set) var volume: Float = 1
    public private(set) var isPlaybackRequested = false
    public private(set) var wasPlaybackRequestedAtFailure = false
    public private(set) var pendingSeekTarget: Double?
    public private(set) var isAudioSessionActive = false
    public private(set) var timeline: PlaybackTimeline?
    public var duration: Double { timeline?.duration ?? 0 }

    @ObservationIgnored public var onEvent: (@MainActor (AudioEngineEvent) -> Void)?
    /// Activated before playback and deactivated on ``stop()``. `nil` on macOS.
    @ObservationIgnored public var audioSession: (any AudioSessionActivating)?
    /// The session ``unload()`` kept active for the next item. If that item's activation fails it
    /// is released, so it doesn't keep other apps silent until a stop.
    @ObservationIgnored private var holdsUnloadedSession = false

    /// Replaced after `AVPlayer.status` becomes `.failed` (ADR 0007 recovery), so it is observed:
    /// views reading ``routingPlayer`` follow the replacement.
    private(set) var player: AVQueuePlayer
    /// The current player, for output routing only (for example `RoutePicker` on macOS). It
    /// changes when a failed player is replaced. Control playback through the engine.
    public var routingPlayer: AVPlayer { player }
    /// Creates players; replaced in tests.
    @ObservationIgnored private let makePlayer: @MainActor () -> AVQueuePlayer
    @ObservationIgnored private let timeObserverInterval: Double

    private struct QueuedItem {
        let item: AVPlayerItem
        let trackIndex: Int
        let statusObservation: NSKeyValueObservation
    }

    @ObservationIgnored private var source: AudioEngineSource?
    @ObservationIgnored private var assets: [Int: AVURLAsset] = [:]
    @ObservationIgnored private var queued: [ObjectIdentifier: QueuedItem] = [:]
    /// Fetches an item's error log before its failure is reported, so the failure carries the HTTP
    /// status (ADR 0007). Replaced in tests to delay the fetch.
    @ObservationIgnored var errorLogFetcher: @MainActor (AVPlayerItem) async -> [PlaybackFailure.ErrorLogEntry] = {
        await PlaybackFailure.errorLogEntries(of: $0)
    }
    /// An item failure waiting for its error log, for the queue of `generation`. While it is set the
    /// player stays paused, nothing starts playback and no time is published; a seek rebuilds the
    /// queue (invalidating it) and clearing the queue drops it.
    private struct PendingItemFailure {
        let trackIndex: Int
        let generation: Int
        let report: Task<Void, Never>
    }
    @ObservationIgnored private var pendingItemFailure: PendingItemFailure?
    /// Incremented whenever the queue is cleared, so a delayed failure for an old item is dropped.
    @ObservationIgnored private var queueGeneration = 0
    @ObservationIgnored private var readyWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    /// How long a seek (or load) waits for its item to leave `.unknown` before failing it.
    nonisolated static let readinessTimeout: Duration = .seconds(30)
    /// Waits out ``readinessTimeout``; replaced in tests. Cancelled once the item is ready.
    @ObservationIgnored var readinessWait: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var hasEnded = false
    @ObservationIgnored private var failure: AudioEngineError?
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationTokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?

    /// - Parameters:
    ///   - audioSession: Activated around playback; pass `AudioSessionController` on iOS.
    ///   - timeObserverInterval: Seconds between periodic time updates.
    public convenience init(audioSession: (any AudioSessionActivating)? = nil, timeObserverInterval: Double = 0.5) {
        self.init(
            audioSession: audioSession, timeObserverInterval: timeObserverInterval, makePlayer: { AVQueuePlayer() })
    }

    init(
        audioSession: (any AudioSessionActivating)?, timeObserverInterval: Double,
        makePlayer: @escaping @MainActor () -> AVQueuePlayer
    ) {
        self.audioSession = audioSession
        self.timeObserverInterval = timeObserverInterval
        self.makePlayer = makePlayer
        player = makePlayer()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer()
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        resumeReadyWaiters()
    }

    // MARK: - Commands

    public func load(_ source: AudioEngineSource, at time: Double) async throws(AudioEngineError) {
        let trackCount = source.timeline.tracks.count
        guard source.timeline.tracks.contains(where: \.isPlayable) else { throw .emptyTimeline }
        guard source.trackURLs.count == trackCount else {
            throw .trackURLMismatch(expected: trackCount, actual: source.trackURLs.count)
        }
        reset()
        replacePlayerIfFailed()
        loadGeneration += 1
        let generation = loadGeneration
        self.source = source
        timeline = source.timeline
        isLoading = true
        refreshState()

        _ = await seek(to: time)
        guard generation == loadGeneration else { throw .superseded }
        isLoading = false
        if let failure {
            refreshState()
            throw failure
        }
        if isPlaybackRequested && !isSeeking && pendingSeekTarget == nil { startPlayer() }
        refreshState()
    }

    /// Starts playback at ``defaultRate``. Does nothing without media or after a failure. Once the
    /// media has ended, the request is kept and the next completed seek starts playback.
    public func play() {
        guard timeline != nil, failure == nil else { return }
        isPlaybackRequested = true
        if hasEnded {
            refreshState()
            return
        }
        // Play only once the position is where the user wants it (ADR 0007): a load or seek in
        // flight starts the player when it completes, and an interrupted seek is retried first.
        if isLoading || isSeeking {
            refreshState()
        } else if pendingSeekTarget != nil {
            // Retry the interrupted seek, unless a seek, load or stop or a pause happens first: the
            // retry must never overwrite a newer position.
            let generation = seekGeneration
            Task { [weak self] in
                guard let self, generation == seekGeneration, isPlaybackRequested,
                    let target = pendingSeekTarget
                else { return }
                await seek(to: target)
            }
            refreshState()
        } else {
            startPlayer()
        }
    }

    public func pause() {
        isPlaybackRequested = false
        player.pause()
        refreshState()
    }

    public func pauseForOutputLoss() {
        pause()
        onEvent?(.outputLost)
    }

    public func stop() {
        loadGeneration += 1
        reset()
        refreshState()
        isAudioSessionActive = false
        holdsUnloadedSession = false
        audioSession?.deactivate()
    }

    public func unload() {
        loadGeneration += 1
        reset()
        refreshState()
        holdsUnloadedSession = holdsUnloadedSession || isAudioSessionActive
        isAudioSessionActive = false
    }

    public func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        defaultRate = rate
        player.defaultRate = rate
        if player.rate > 0 { player.rate = rate }
    }

    /// Sets ``volume``, clamped to `0...1`, on the current player. Ignores non-finite values.
    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        self.volume = min(max(volume, 0), 1)
        player.volume = self.volume
    }

    /// Seeks to `time`. An interrupted seek is retried once; if it is interrupted again, the player
    /// stays paused with ``pendingSeekTarget`` set and recovery (P2-06a) takes over. After a
    /// ``PlaybackState/failed(_:)`` state, a seek is the retry: it rebuilds the queue from fresh
    /// assets and clears the failure.
    @discardableResult
    public func seek(to time: Double) async -> SeekResult {
        guard let timeline, let position = timeline.position(at: time), let target = timeline.time(at: position)
        else { return .failed }
        seekGeneration += 1
        let generation = seekGeneration
        pendingSeekTarget = target
        isSeeking = true
        // A seek leaves the end: the position is the seek's target now, even if the seek is
        // interrupted, so a remembered play() retries it rather than waiting at the end.
        hasEnded = false
        // After a failure, or while one is being reported, rebuild: the queue may have dropped the
        // failed item, and the report must not outlive a newer seek.
        if failure != nil || pendingItemFailure != nil {
            failure = nil
            clearQueue()
            replacePlayerIfFailed()
        }

        var result = await performSeek(to: position, target: target, generation: generation)
        if result == .interrupted {
            result = await performSeek(to: position, target: target, generation: generation)
        }
        guard result != .superseded else { return .superseded }
        isSeeking = false
        switch result {
        case .completed:
            if isPlaybackRequested, !isLoading, player.rate == 0 { startPlayer() }
        case .interrupted:
            player.pause()
        case .failed, .superseded:
            break
        }
        refreshState()
        return result
    }

    private func performSeek(
        to position: PlaybackTimeline.TrackPosition, target: Double, generation: Int
    ) async -> SeekResult {
        guard let source else { return .failed }
        // Use the item actually playing, not `currentTrackIndex`: that is updated after a hop, so it
        // can lag just after the queue advanced.
        if playingTrackIndex != position.trackIndex {
            player.pause()
            rebuildQueue(from: position.trackIndex)
        }
        refreshState()

        guard let item = player.currentItem else { return .failed }
        await waitUntilReady(item)
        guard generation == seekGeneration else { return .superseded }
        guard failure == nil else { return .failed }
        // A failed item may already have been dropped from the queue, so check it first.
        guard item.status != .failed else {
            await reportItemFailure(trackIndex: position.trackIndex, item: item)?.value
            guard generation == seekGeneration else { return .superseded }
            return .failed
        }
        guard item === player.currentItem, item.status == .readyToPlay else { return .interrupted }

        let finished = await itemSeeker(
            item, CMTime(seconds: position.offset, preferredTimescale: 1000),
            CMTime(seconds: source.seekTolerance, preferredTimescale: 1000))
        guard generation == seekGeneration else { return .superseded }
        guard finished, item === player.currentItem else { return .interrupted }
        pendingSeekTarget = nil
        currentTime = target
        hasEnded = false
        return .completed
    }

    private var playingTrackIndex: Int? {
        player.currentItem.flatMap { queued[ObjectIdentifier($0)]?.trackIndex }
    }

    // MARK: - Queue

    /// Sets the precise-timing key only when wanted. Passing an explicit `false` is not the same as
    /// leaving the key out: on macOS 27.2 it made local WAV items fail with -11800 / -17770.
    /// `mimeType` overrides the type for URLs without a usable extension (ADR 0007 §2), and
    /// `networkAccess` adds the transport's cellular / expensive / constrained flags.
    static func assetOptions(
        prefersPreciseTiming: Bool, mimeType: String? = nil, networkAccess: NetworkAccess? = nil
    ) -> [String: Any] {
        var options: [String: Any] = networkAccess?.urlAssetOptions ?? [:]
        if prefersPreciseTiming { options[AVURLAssetPreferPreciseDurationAndTimingKey] = true }
        if let mimeType, !mimeType.isEmpty { options[AVURLAssetOverrideMIMETypeKey] = mimeType }
        return options
    }

    private func rebuildQueue(from start: Int) {
        guard let source else { return }
        clearQueue()
        let tracks = source.timeline.tracks
        // Only playable tracks are queued; `queued` maps each item back to its timeline track index.
        for index in start..<tracks.count where tracks[index].isPlayable {
            let item = makeItem(trackIndex: index, source: source)
            let id = ObjectIdentifier(item)
            let observation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged(id) }
            }
            queued[id] = QueuedItem(item: item, trackIndex: index, statusObservation: observation)
            player.insert(item, after: nil)
        }
        setCurrentTrack(start)
    }

    private func makeItem(trackIndex: Int, source: AudioEngineSource) -> AVPlayerItem {
        let asset = assets[trackIndex] ?? makeAsset(trackIndex: trackIndex, source: source)
        assets[trackIndex] = asset
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let track = source.timeline.tracks[trackIndex]
        if track.forwardPlaybackEndTime < track.duration {
            item.forwardPlaybackEndTime = CMTime(seconds: track.forwardPlaybackEndTime, preferredTimescale: 1000)
        }
        return item
    }

    /// A local `file:` track loads directly even with a header transport: the transport only
    /// serves `http(s)`, so it would reject the file (a fixture or downloaded track).
    private func makeAsset(trackIndex: Int, source: AudioEngineSource) -> AVURLAsset {
        let url = source.trackURLs[trackIndex]
        let mimeType = source.mimeType(trackIndex: trackIndex)
        let options = Self.assetOptions(
            prefersPreciseTiming: source.prefersPreciseTiming, mimeType: mimeType, networkAccess: source.networkAccess)
        guard let transport = source.headerTransport, !url.isFileURL else {
            return AVURLAsset(url: url, options: options)
        }
        return transport.makeAsset(url: url, options: options, mimeType: mimeType, networkAccess: source.networkAccess)
    }

    private func clearQueue() {
        player.removeAllItems()
        for entry in queued.values {
            entry.statusObservation.invalidate()
            // A failed asset stays failed. A prefetched item can fail without being reported (it
            // is reported when the queue reaches it), so evict here too: the rebuild that follows
            // gets a fresh asset.
            if entry.item.status == .failed, assets[entry.trackIndex] === entry.item.asset {
                assets[entry.trackIndex] = nil
            }
        }
        queued = [:]
        queueGeneration += 1
        pendingItemFailure = nil
        resumeReadyWaiters()
    }

    private func reset() {
        seekGeneration += 1
        isSeeking = false
        pendingSeekTarget = nil
        player.pause()
        clearQueue()
        source = nil
        timeline = nil
        assets = [:]
        currentTrackIndex = nil
        currentTime = 0
        hasEnded = false
        failure = nil
        isLoading = false
        isPlaybackRequested = false
    }

    // MARK: - Seeking

    /// Returns once `item` is no longer `.unknown`, it was removed from the queue, or it failed for
    /// staying `.unknown` past ``readinessTimeout``.
    private func waitUntilReady(_ item: AVPlayerItem) async {
        let id = ObjectIdentifier(item)
        guard item.status == .unknown, queued[id] != nil else { return }
        let deadline = Task { [weak self, readinessWait] in
            await readinessWait(Self.readinessTimeout)
            guard !Task.isCancelled else { return }
            self?.readinessTimedOut(id)
        }
        defer { deadline.cancel() }
        await withCheckedContinuation { readyWaiters[id, default: []].append($0) }
    }

    /// An item still `.unknown` at its deadline (a server that never answers) fails like a stall
    /// with no error, so recovery counts the attempt; its asset is evicted so a retry makes a new
    /// one, and its waiters resume (their seek then fails).
    private func readinessTimedOut(_ id: ObjectIdentifier) {
        guard let entry = queued[id], entry.item.status == .unknown, readyWaiters[id] != nil else { return }
        assets[entry.trackIndex] = nil
        fail(.itemFailed(trackIndex: entry.trackIndex, .readinessTimedOut))
        for waiter in readyWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters.values.flatMap(\.self)
        readyWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    /// Seeks an item (`time`, then `tolerance` before and after). Replaced in tests to simulate
    /// cancelled seeks.
    @ObservationIgnored var itemSeeker: @MainActor (AVPlayerItem, CMTime, CMTime) async -> Bool = {
        item, time, tolerance in
        await withCheckedContinuation { continuation in
            item.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    // MARK: - Playback

    private func startPlayer() {
        // A failure being reported holds playback; the request stays and a later seek starts it.
        guard pendingItemFailure == nil else {
            refreshState()
            return
        }
        do {
            try audioSession?.activate()
        } catch {
            // Without an active session iOS would not play; report it and stay paused (the player
            // may already be playing, for example on a repeated play()). The media is still usable,
            // so this is not a sticky failure: the next play() activates again.
            logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            isAudioSessionActive = false
            isPlaybackRequested = false
            player.pause()
            refreshState()
            if holdsUnloadedSession {
                holdsUnloadedSession = false
                audioSession?.deactivate()
            }
            onEvent?(.failed(.audioSessionActivationFailed(description: error.localizedDescription)))
            return
        }
        holdsUnloadedSession = false
        if !isAudioSessionActive { isAudioSessionActive = true }
        player.defaultRate = defaultRate
        player.play()
        if player.rate != defaultRate { player.rate = defaultRate }
        refreshState()
    }

    private func refreshState() {
        let newState: PlaybackState
        if timeline == nil {
            newState = .idle
        } else if let failure {
            newState = .failed(failure)
        } else if isLoading {
            newState = .loading
        } else if hasEnded {
            newState = .ended
        } else {
            switch player.timeControlStatus {
            case .playing: newState = .playing
            case .waitingToPlayAtSpecifiedRate: newState = .buffering
            // A seek in flight, or one that was interrupted and awaits recovery, holds playback.
            case .paused:
                newState =
                    isPlaybackRequested && (isSeeking || pendingSeekTarget != nil || pendingItemFailure != nil)
                    ? .buffering : .paused
            @unknown default: newState = .paused
            }
        }
        if newState != state { state = newState }
    }

    private func setCurrentTrack(_ index: Int) {
        guard index != currentTrackIndex else { return }
        currentTrackIndex = index
        onEvent?(.trackChanged(index))
    }

    /// Reports an item failure once the item's error log is fetched (`error` defaults to
    /// `item.error`), and returns the pending report. The player pauses at once, so it does not play
    /// past the failed track. If the queue is cleared (a seek, load, stop or player replacement)
    /// before the log arrives, the failure is dropped. While a report is pending, it is returned.
    @discardableResult
    private func reportItemFailure(
        trackIndex: Int, item: AVPlayerItem, error: (any Error)? = nil
    ) -> Task<Void, Never>? {
        if let pendingItemFailure { return pendingItemFailure.report }
        guard failure == nil else { return nil }
        let generation = queueGeneration
        let id = ObjectIdentifier(item)
        player.pause()
        // A failed asset stays failed; evict it now so a rebuild during the fetch makes a new one.
        assets[trackIndex] = nil
        let report = Task { [weak self] in
            guard let self else { return }
            let log = await errorLogFetcher(item)
            guard pendingItemFailure?.generation == generation, generation == queueGeneration else { return }
            pendingItemFailure = nil
            guard queued[id]?.item === item, failure == nil else {
                refreshState()
                return
            }
            fail(.itemFailed(trackIndex: trackIndex, PlaybackFailure(error: error ?? item.error, errorLog: log)))
        }
        pendingItemFailure = PendingItemFailure(trackIndex: trackIndex, generation: generation, report: report)
        refreshState()
        return report
    }

    private func fail(_ error: AudioEngineError) {
        guard failure == nil else { return }
        logger.error("Playback failed: \(String(describing: error), privacy: .public)")
        failure = error
        wasPlaybackRequestedAtFailure = isPlaybackRequested
        isPlaybackRequested = false
        player.pause()
        refreshState()
        onEvent?(.failed(error))
    }

    // MARK: - Observation

    private func playerStatusChanged() {
        guard player.status == .failed else { return }
        fail(.playerFailed(PlaybackFailure(error: player.error)))
        // Items of a failed player may never become ready; let a waiting seek finish.
        resumeReadyWaiters()
    }

    /// A failed `AVPlayer` stays failed, so recovery (a seek or load after the failure) needs a new
    /// one with the same observers and settings (ADR 0007).
    private func replacePlayerIfFailed() {
        guard player.status == .failed else { return }
        clearQueue()
        let old = player
        stopObservingPlayer()
        let replacement = makePlayer()
        replacement.actionAtItemEnd = old.actionAtItemEnd
        replacement.automaticallyWaitsToMinimizeStalling = old.automaticallyWaitsToMinimizeStalling
        replacement.volume = volume
        replacement.isMuted = old.isMuted
        replacement.sourceClock = old.sourceClock
        replacement.defaultRate = defaultRate
        player = replacement
        observePlayer()
        logger.info("Replaced the failed player")
    }

    private func stopObservingPlayer() {
        for observation in playerObservations { observation.invalidate() }
        playerObservations = []
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }

    private func observePlayer() {
        playerObservations = [
            player.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.playerStatusChanged() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.currentItemChanged() }
            },
        ]
        let interval = CMTime(seconds: max(timeObserverInterval, 0.01), preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NotificationCenter.default
        let reasonKey = AVPlayer.rateDidChangeReasonKey
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let object = notification.object else { return }
                let id = ObjectIdentifier(object as AnyObject)
                MainActor.assumeIsolated { self?.itemDidPlayToEnd(id) }
            },
            center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) {
                [weak self] notification in
                let reason = notification.userInfo?[reasonKey] as? AVPlayer.RateDidChangeReason
                MainActor.assumeIsolated { self?.rateDidChange(reason: reason) }
            },
            center.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let object = notification.object else { return }
                let id = ObjectIdentifier(object as AnyObject)
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                MainActor.assumeIsolated { self?.itemFailedToPlayToEnd(id, error: error) }
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let object = notification.object else { return }
                let id = ObjectIdentifier(object as AnyObject)
                MainActor.assumeIsolated { self?.itemStalled(id) }
            },
        ]
    }

    private func tick() {
        // While a seek runs or its target is still pending, the item is not at the requested
        // position, so its time must not be published.
        guard !isSeeking, pendingSeekTarget == nil, !hasEnded, failure == nil, pendingItemFailure == nil,
            let timeline,
            let item = player.currentItem,
            item.status == .readyToPlay, let entry = queued[ObjectIdentifier(item)]
        else { return }
        if entry.trackIndex != currentTrackIndex {
            // The queue advanced before the `currentItem` KVO hop ran.
            currentItemChanged()
            // A skipped failed track keeps the last confirmed position.
            guard failure == nil, pendingItemFailure == nil else { return }
        }
        let offset = item.currentTime().seconds
        guard offset.isFinite, let time = timeline.time(trackIndex: entry.trackIndex, offset: offset) else { return }
        if time != currentTime { currentTime = time }
        onEvent?(.tick(time))
    }

    /// The system stopped the player (for example a route loss or backgrounding): treat it as a
    /// pause. Audio session interruptions are left to ``AudioInterruptionHandler``, which needs to
    /// see that playback was requested in order to resume it.
    private func rateDidChange(reason: AVPlayer.RateDidChangeReason?) {
        guard let reason, reason != .setRateCalled, reason != .audioSessionInterrupted, player.rate == 0,
            isPlaybackRequested
        else { return }
        isPlaybackRequested = false
        refreshState()
    }

    private func currentItemChanged() {
        let item = player.currentItem
        let entry = item.flatMap { queued[ObjectIdentifier($0)] }
        // AVQueuePlayer silently drops a failed item and moves on; for an audiobook that would skip
        // a track, so fail on the first skipped one instead.
        if failure == nil, pendingItemFailure == nil, let previous = currentTrackIndex,
            let skipped = queued.values
                // `>=`: the previously current item may have failed and been dropped before its
                // status change was handled.
                .filter({ $0.item.status == .failed && $0.trackIndex >= previous })
                .filter({ $0.trackIndex < entry?.trackIndex ?? Int.max })
                .min(by: { $0.trackIndex < $1.trackIndex })
        {
            reportItemFailure(trackIndex: skipped.trackIndex, item: skipped.item)
            return
        }
        guard let item, let entry else { return }
        setCurrentTrack(entry.trackIndex)
        if item.status == .failed { reportItemFailure(trackIndex: entry.trackIndex, item: item) }
        if isPlaybackRequested, player.rate > 0, player.rate != defaultRate { player.rate = defaultRate }
    }

    private func itemStatusChanged(_ id: ObjectIdentifier) {
        guard let entry = queued[id], entry.item.status != .unknown else { return }
        for waiter in readyWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        if entry.item.status == .failed, entry.item === player.currentItem {
            reportItemFailure(trackIndex: entry.trackIndex, item: entry.item)
        }
    }

    private func itemDidPlayToEnd(_ id: ObjectIdentifier) {
        // A reported or pending failure means playback did not reach the end. During a seek (or
        // while its target is pending) the seek decides the position, not an end it overtook.
        guard failure == nil, pendingItemFailure == nil, !isSeeking, pendingSeekTarget == nil,
            let entry = queued[id], let timeline,
            entry.trackIndex == queued.values.map(\.trackIndex).max()
        else { return }
        // So does a failed track the queue skipped without the engine noticing yet.
        if let skipped = queued.values.filter({ $0.item.status == .failed }).min(by: { $0.trackIndex < $1.trackIndex })
        {
            reportItemFailure(trackIndex: skipped.trackIndex, item: skipped.item)
            return
        }
        let track = timeline.tracks[entry.trackIndex]
        hasEnded = true
        isPlaybackRequested = false
        currentTime = timeline.time(trackIndex: entry.trackIndex, offset: track.playbackDuration) ?? timeline.duration
        refreshState()
        onEvent?(.endOfMedia)
    }

    private func itemFailedToPlayToEnd(_ id: ObjectIdentifier, error: NSError?) {
        guard let entry = queued[id] else { return }
        reportItemFailure(trackIndex: entry.trackIndex, item: entry.item, error: error)
    }

    /// The playing item ran out of media with no error. A failure, or a seek (which owns the
    /// item until it lands), takes precedence; so does a pause.
    private func itemStalled(_ id: ObjectIdentifier) {
        guard let entry = queued[id], entry.item === player.currentItem, failure == nil, pendingItemFailure == nil,
            !hasEnded, !isSeeking, pendingSeekTarget == nil, isPlaybackRequested
        else { return }
        // The `timeControlStatus` KVO hop may not have run yet: a tick queued behind this must not
        // read as playback that resumed.
        refreshState()
        onEvent?(.stalled)
    }
}
