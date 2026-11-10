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
    public private(set) var isPlaybackRequested = false
    public private(set) var pendingSeekTarget: Double?
    public private(set) var timeline: PlaybackTimeline?
    public var duration: Double { timeline?.duration ?? 0 }

    @ObservationIgnored public var onEvent: (@MainActor (AudioEngineEvent) -> Void)?
    /// Activated before playback and deactivated on ``stop()``. `nil` on macOS.
    @ObservationIgnored public var audioSession: (any AudioSessionActivating)?

    let player = AVQueuePlayer()

    private struct QueuedItem {
        let item: AVPlayerItem
        let trackIndex: Int
        let statusObservation: NSKeyValueObservation
    }

    @ObservationIgnored private var source: AudioEngineSource?
    @ObservationIgnored private var assets: [Int: AVURLAsset] = [:]
    @ObservationIgnored private var queued: [ObjectIdentifier: QueuedItem] = [:]
    @ObservationIgnored private var readyWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
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
    public init(audioSession: (any AudioSessionActivating)? = nil, timeObserverInterval: Double = 0.5) {
        self.audioSession = audioSession
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer(interval: timeObserverInterval)
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
        if isPlaybackRequested && !isSeeking { startPlayer() }
        refreshState()
    }

    /// Starts playback at ``defaultRate``. Does nothing without media, after a failure or once the
    /// media has ended (seek first).
    public func play() {
        guard timeline != nil, failure == nil, !hasEnded else { return }
        isPlaybackRequested = true
        // A load or seek in flight starts the player once it completes, so the new item does not
        // play from its start before the seek lands.
        if !isLoading && !isSeeking { startPlayer() }
        refreshState()
    }

    public func pause() {
        isPlaybackRequested = false
        player.pause()
        refreshState()
    }

    public func stop() {
        loadGeneration += 1
        reset()
        refreshState()
        audioSession?.deactivate()
    }

    public func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        defaultRate = rate
        player.defaultRate = rate
        if player.rate > 0 { player.rate = rate }
    }

    @discardableResult
    public func seek(to time: Double) async -> SeekResult {
        guard let source, let timeline, let position = timeline.position(at: time),
            let target = timeline.time(at: position)
        else { return .failed }
        seekGeneration += 1
        let generation = seekGeneration
        pendingSeekTarget = target
        isSeeking = true
        if player.currentItem == nil || position.trackIndex != currentTrackIndex {
            player.pause()
            rebuildQueue(from: position.trackIndex)
        }
        refreshState()

        guard let item = player.currentItem else { return finishSeek(.failed) }
        await waitUntilReady(item)
        guard generation == seekGeneration else { return .superseded }
        guard item.status == .readyToPlay else {
            fail(trackIndex: position.trackIndex, error: item.error)
            return finishSeek(.failed)
        }

        let finished = await seek(item, to: position.offset, tolerance: source.seekTolerance)
        guard generation == seekGeneration else { return .superseded }
        guard finished else { return finishSeek(.interrupted) }
        pendingSeekTarget = nil
        currentTime = target
        hasEnded = false
        return finishSeek(.completed)
    }

    // MARK: - Queue

    /// Sets the precise-timing key only when wanted. Passing an explicit `false` is not the same as
    /// leaving the key out: on macOS 27.2 it made local WAV items fail with -11800 / -17770.
    static func assetOptions(prefersPreciseTiming: Bool) -> [String: Any] {
        prefersPreciseTiming ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : [:]
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
        let asset =
            assets[trackIndex]
            ?? AVURLAsset(
                url: source.trackURLs[trackIndex],
                options: Self.assetOptions(prefersPreciseTiming: source.prefersPreciseTiming))
        assets[trackIndex] = asset
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let track = source.timeline.tracks[trackIndex]
        if track.forwardPlaybackEndTime < track.duration {
            item.forwardPlaybackEndTime = CMTime(seconds: track.forwardPlaybackEndTime, preferredTimescale: 1000)
        }
        return item
    }

    private func clearQueue() {
        player.removeAllItems()
        for entry in queued.values { entry.statusObservation.invalidate() }
        queued = [:]
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

    private func finishSeek(_ result: SeekResult) -> SeekResult {
        isSeeking = false
        if result != .failed, isPlaybackRequested, !isLoading, player.rate == 0 { startPlayer() }
        refreshState()
        return result
    }

    /// Returns once `item` is no longer `.unknown`, or it was removed from the queue.
    private func waitUntilReady(_ item: AVPlayerItem) async {
        let id = ObjectIdentifier(item)
        guard item.status == .unknown, queued[id] != nil else { return }
        await withCheckedContinuation { readyWaiters[id, default: []].append($0) }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters.values.flatMap(\.self)
        readyWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    private func seek(_ item: AVPlayerItem, to offset: Double, tolerance: Double) async -> Bool {
        let time = CMTime(seconds: offset, preferredTimescale: 1000)
        let tolerance = CMTime(seconds: tolerance, preferredTimescale: 1000)
        return await withCheckedContinuation { continuation in
            item.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    // MARK: - Playback

    private func startPlayer() {
        do {
            try audioSession?.activate()
        } catch {
            logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
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
            case .paused: newState = isPlaybackRequested && isSeeking ? .buffering : .paused
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

    private func fail(trackIndex: Int, error: (any Error)?) {
        guard failure == nil else { return }
        let error = AudioEngineError.itemFailed(
            trackIndex: trackIndex, description: error?.localizedDescription ?? "Unknown error")
        logger.error("Playback failed: \(String(describing: error), privacy: .public)")
        failure = error
        isPlaybackRequested = false
        player.pause()
        refreshState()
        onEvent?(.failed(error))
    }

    // MARK: - Observation

    private func observePlayer(interval: Double) {
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.currentItemChanged() }
            },
        ]
        let interval = CMTime(seconds: max(interval, 0.01), preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let object = notification.object else { return }
                let id = ObjectIdentifier(object as AnyObject)
                MainActor.assumeIsolated { self?.itemDidPlayToEnd(id) }
            },
            center.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let object = notification.object else { return }
                let id = ObjectIdentifier(object as AnyObject)
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                MainActor.assumeIsolated { self?.itemFailedToPlayToEnd(id, error: error) }
            },
        ]
    }

    private func tick() {
        guard !isSeeking, !hasEnded, failure == nil, let timeline, let item = player.currentItem,
            item.status == .readyToPlay, let entry = queued[ObjectIdentifier(item)]
        else { return }
        let offset = item.currentTime().seconds
        guard offset.isFinite, let time = timeline.time(trackIndex: entry.trackIndex, offset: offset) else { return }
        if time != currentTime { currentTime = time }
        onEvent?(.tick(time))
    }

    private func currentItemChanged() {
        guard let item = player.currentItem, let entry = queued[ObjectIdentifier(item)] else { return }
        setCurrentTrack(entry.trackIndex)
        if item.status == .failed { fail(trackIndex: entry.trackIndex, error: item.error) }
        if isPlaybackRequested, player.rate > 0, player.rate != defaultRate { player.rate = defaultRate }
    }

    private func itemStatusChanged(_ id: ObjectIdentifier) {
        guard let entry = queued[id], entry.item.status != .unknown else { return }
        for waiter in readyWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        if entry.item.status == .failed, entry.item === player.currentItem {
            fail(trackIndex: entry.trackIndex, error: entry.item.error)
        }
    }

    private func itemDidPlayToEnd(_ id: ObjectIdentifier) {
        guard let entry = queued[id], let timeline,
            entry.trackIndex == queued.values.map(\.trackIndex).max()
        else { return }
        let track = timeline.tracks[entry.trackIndex]
        hasEnded = true
        isPlaybackRequested = false
        currentTime = timeline.time(trackIndex: entry.trackIndex, offset: track.playbackDuration) ?? timeline.duration
        refreshState()
        onEvent?(.endOfMedia)
    }

    private func itemFailedToPlayToEnd(_ id: ObjectIdentifier, error: NSError?) {
        guard let entry = queued[id] else { return }
        fail(trackIndex: entry.trackIndex, error: error)
    }
}
