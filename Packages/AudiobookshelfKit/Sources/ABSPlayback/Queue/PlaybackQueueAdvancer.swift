import ABSCore
import ABSData
import Foundation

private let logger = Log.playback

/// Auto-advance (P2-13): when an item ends, plays the first queued item; with an empty queue,
/// after a podcast episode, the podcast's next unfinished episode
/// (``PodcastEpisodeListing/nextUnfinished(after:)``), never one that already ended here. Queued
/// items play even if finished. A queued item leaves the queue once a session for it starts,
/// however it was started; restoring it at launch doesn't count.
///
/// The next item is prepared before the end, so that after it only `/play` and loading the stream
/// remain (iOS can suspend the app once audio stops): when an item loads; once on entering its
/// last chapter and once in its last ``nearEndWindow`` seconds (re-armed by a resume, which
/// refreshes at once inside them, and by a seek out of them); and again when the queue changes,
/// when ``progressDidChange(for:)`` concerns the next item or the current podcast, or on
/// ``connectionDidChange()``. Each preparation replaces the one in flight. Only when no
/// preparation younger than ``maximumPreparationAge`` is ready at the end is anything fetched
/// after it, under the coordinator's background activity.
///
/// The coordinator holds the advancer weakly: the owner keeps it alive while attached.
@MainActor
public final class PlaybackQueueAdvancer: NextItemProvider {
    public let queue: PlaybackQueue
    private let episodes: (any PodcastEpisodeSource)?
    private weak var coordinator: PlaybackCoordinator?
    private var observerToken: PlaybackObserverToken?

    /// The loaded item whose successor is prepared.
    private var current: MediaKey?
    private var candidate: (key: MediaKey, isQueued: Bool)?
    private var prepared: PreparedNextItem?
    private var listing: (podcastItemID: String, listing: PodcastEpisodeListing)?
    /// Episodes that ended while attached, whose finish may not have reached the server yet.
    private var endedEpisodes: Set<MediaKey> = []
    /// When the last preparation finished, with or without a next item.
    private var preparedAt: TimeInterval = 0
    /// Near-end refreshes done since the load, a resume or a seek out of them.
    private var refreshed: Set<NearEndTrigger> = []
    /// A pause happened, so the next start re-arms the near-end refreshes.
    private var rearmOnStart = false
    /// The queued item an advance is starting, until its session starts.
    private var advancingFromQueue: MediaKey?
    private var revision = 0
    private var task: Task<Void, Never>?
    private let uptime: @Sendable () -> TimeInterval

    private enum NearEndTrigger { case finalChapter, window }

    /// The next item is prepared again once this close to the end, in seconds.
    public static let nearEndWindow: Double = 30
    /// An older preparation is redone at the end, in seconds.
    public static let maximumPreparationAge: TimeInterval = 600

    /// - Parameters:
    ///   - episodes: Where podcast episodes come from; `nil` turns off the podcast fallback.
    ///   - uptime: Monotonic seconds, for the age of a preparation.
    public init(
        queue: PlaybackQueue, episodes: (any PodcastEpisodeSource)?,
        uptime: @escaping @Sendable () -> TimeInterval = ProgressSyncClock.live.uptime
    ) {
        self.queue = queue
        self.episodes = episodes
        self.uptime = uptime
    }

    /// Becomes `coordinator`'s next-item provider and follows its playback. Attach to one
    /// coordinator at a time.
    public func attach(to coordinator: PlaybackCoordinator) {
        guard self.coordinator == nil else { return }
        self.coordinator = coordinator
        coordinator.nextItemProvider = self
        observerToken = coordinator.addObserver { [weak self] in self?.handle($0) }
        queue.onItemsChange = { [weak self] in self?.queueDidChange() }
        if coordinator.phase == .loaded, let key = coordinator.mediaKey {
            current = key
            recompute(refetchListing: true)
        }
    }

    /// Undoes ``attach(to:)``, cancelling any preparation and any advance still preparing (one
    /// whose start has begun finishes as an ordinary play).
    public func detach(from coordinator: PlaybackCoordinator) {
        guard self.coordinator === coordinator else { return }
        if let observerToken { coordinator.removeObserver(observerToken) }
        observerToken = nil
        queue.onItemsChange = nil
        if coordinator.nextItemProvider === self {
            coordinator.nextItemProvider = nil
            coordinator.cancelAutoAdvance()
        }
        self.coordinator = nil
        endedEpisodes = []
        advancingFromQueue = nil
        reset()
    }

    /// Progress changed for `key` (synced, or from another device): prepares again when it is the
    /// next item, or an episode of the current podcast (finishing one changes which is next).
    /// The current item's own progress changes nothing. An episode that ended here and changed
    /// since is no longer assumed finished.
    public func progressDidChange(for key: MediaKey) {
        guard key != current, key.serverConnectionID == queue.serverConnectionID else { return }
        // Even with nothing loaded: playing again later must not skip it.
        endedEpisodes.remove(key)
        guard let current else { return }
        let samePodcast =
            current.episodeId != nil && key.episodeId != nil && key.libraryItemId == current.libraryItemId
        guard samePodcast || key == candidate?.key || key == firstQueued(after: current) else { return }
        recompute(refetchListing: samePodcast)
    }

    /// The network path or the connection's reachability changed: checks the streaming policy
    /// and fetches the podcast's episodes and the next item's progress again, since either may
    /// have changed elsewhere while this device was offline.
    public func connectionDidChange() {
        guard current != nil else { return }
        recompute(refetchListing: true)
    }

    // MARK: NextItemProvider

    /// `nil` too when the preparation is too old to trust (progress or the network may have changed).
    func preparedNext(after key: MediaKey) -> PreparedNextItem? {
        guard key == current, let prepared, prepared.key == candidate?.key,
            uptime() - preparedAt <= Self.maximumPreparationAge
        else { return nil }
        return prepared
    }

    func prepareNext(after key: MediaKey) async -> PreparedNextItem? {
        guard key == current else { return nil }
        // A preparation too old to use, or an old finding of none, means an old listing too.
        if preparedNext(after: key) == nil, task == nil {
            recompute(refetchListing: prepared != nil || uptime() - preparedAt > Self.maximumPreparationAge)
        }
        while preparedNext(after: key) == nil, let running = task {
            await running.value
            if task == running { break }
        }
        return preparedNext(after: key)
    }

    func isStillNext(_ key: MediaKey) -> Bool {
        key != advancingFromQueue
            || queue.items.contains { $0.key(serverConnectionID: queue.serverConnectionID) == key }
    }

    /// Waits for the preparation in flight (tests).
    func waitForPreparation() async {
        while let running = task {
            await running.value
            if task == running { break }
        }
    }

    // MARK: Following playback

    private func handle(_ event: PlaybackCoordinatorEvent) {
        switch event {
        case .itemChanged(let key):
            let advancing = candidate?.isQueued == true && key == candidate?.key ? key : nil
            reset()
            advancingFromQueue = advancing
        case .sessionStarted(_, let key):
            advancingFromQueue = nil
            queue.remove(key)
        case .loaded:
            current = coordinator?.mediaKey
            rearmOnStart = false
            // Loading inside a trigger prepares anyway.
            refreshed = nearEndTriggers(at: coordinator?.currentTime ?? 0)
            recompute(refetchListing: true)
        case .playbackStarted:
            guard rearmOnStart else { return }
            rearmOnStart = false
            refreshed = []
            refreshIfNearEnd(at: coordinator?.currentTime ?? 0)
        case .paused:
            rearmOnStart = true
        case .didSeek(let time):
            refreshed.formIntersection(nearEndTriggers(at: time))
        case .tick(let time):
            refreshIfNearEnd(at: time)
        case .ended:
            if let current, current.episodeId != nil { endedEpisodes.insert(current) }
        case .failed, .sessionWillClose:
            break
        }
    }

    private func refreshIfNearEnd(at time: Double) {
        guard current != nil else { return }
        let due = nearEndTriggers(at: time).subtracting(refreshed)
        guard !due.isEmpty else { return }
        refreshed.formUnion(due)
        // The earlier preparation stays usable until this one replaces it.
        recompute(refetchListing: true, keepPrepared: true)
    }

    private func nearEndTriggers(at time: Double) -> Set<NearEndTrigger> {
        guard let timeline = coordinator?.timeline, timeline.duration > 0 else { return [] }
        var triggers: Set<NearEndTrigger> = []
        if timeline.duration - time <= Self.nearEndWindow { triggers.insert(.window) }
        if timeline.chapters.count > 1, timeline.currentChapterIndex(at: time) == timeline.chapters.count - 1 {
            triggers.insert(.finalChapter)
        }
        return triggers
    }

    private func queueDidChange() {
        guard let current else { return }
        if let head = firstQueued(after: current) {
            if candidate?.key == head, candidate?.isQueued == true { return }
        } else if let candidate, !candidate.isQueued {
            return
        }
        recompute()
    }

    private func reset() {
        task?.cancel()
        task = nil
        revision += 1
        current = nil
        candidate = nil
        prepared = nil
        listing = nil
        refreshed = []
        rearmOnStart = false
    }

    // MARK: Preparing

    private func recompute(refetchListing: Bool = false, keepPrepared: Bool = false) {
        task?.cancel()
        task = nil
        revision += 1
        if !keepPrepared {
            candidate = nil
            prepared = nil
        }
        if refetchListing { listing = nil }
        guard let current else { return }
        let revision = revision
        task = Task { [weak self] in await self?.prepare(after: current, revision: revision) }
    }

    private func prepare(after key: MediaKey, revision: Int) async {
        defer { if self.revision == revision { task = nil } }
        let next: (key: MediaKey, isQueued: Bool)?
        do {
            next = try await nextCandidate(after: key, revision: revision)
        } catch {
            // Keeps an earlier preparation, if this one was a refresh.
            logger.info("Next episode unavailable: \(String(describing: type(of: error)), privacy: .public)")
            return
        }
        guard self.revision == revision, !Task.isCancelled else { return }
        guard let next, let coordinator else {
            candidate = nil
            prepared = nil
            preparedAt = uptime()
            return
        }
        candidate = next
        if prepared?.key != next.key { prepared = nil }
        let item = await coordinator.prepareStart(for: next.key)
        guard self.revision == revision else { return }
        prepared = item
        preparedAt = uptime()
    }

    /// Throws when the podcast's episodes can't be loaded.
    private func nextCandidate(after key: MediaKey, revision: Int) async throws -> (key: MediaKey, isQueued: Bool)? {
        guard key.serverConnectionID == queue.serverConnectionID else { return nil }
        if let queued = firstQueued(after: key) { return (queued, true) }
        guard let episodeID = key.episodeId, let episodes else { return nil }
        var listing: PodcastEpisodeListing
        if let cached = self.listing, cached.podcastItemID == key.libraryItemId {
            listing = cached.listing
        } else {
            try Task.checkCancellation()
            let ended = endedEpisodes.filter { $0.libraryItemId == key.libraryItemId }.compactMap(\.episodeId)
            listing = try await episodes.listing(
                podcastItemID: key.libraryItemId, excluding: Set(ended).union([episodeID]))
            guard self.revision == revision else { return nil }
            self.listing = (key.libraryItemId, listing)
        }
        for ended in endedEpisodes where ended.libraryItemId == key.libraryItemId {
            if let id = ended.episodeId { listing.finishedEpisodeIDs.insert(id) }
        }
        guard let next = listing.nextUnfinished(after: episodeID) else { return nil }
        return (
            MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId, episodeId: next.id),
            false
        )
    }

    private func firstQueued(after key: MediaKey) -> MediaKey? {
        queue.items.lazy.map { $0.key(serverConnectionID: self.queue.serverConnectionID) }.first { $0 != key }
    }
}
