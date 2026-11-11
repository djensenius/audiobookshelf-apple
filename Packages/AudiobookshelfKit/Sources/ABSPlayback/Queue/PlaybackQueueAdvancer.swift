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
/// remain (iOS can suspend the app once audio stops): when an item loads, once more in its last
/// ``nearEndWindow`` seconds, and again when the queue changes, when ``progressDidChange(for:)``
/// concerns the next item or the current podcast, or on ``connectionDidChange()``. Each
/// preparation replaces the one in flight.
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
    private var refreshedNearEnd = false
    private var revision = 0
    private var task: Task<Void, Never>?

    /// The next item is prepared again once this close to the end, in seconds.
    public static let nearEndWindow: Double = 30

    /// - Parameter episodes: Where podcast episodes come from; `nil` turns off the podcast fallback.
    public init(queue: PlaybackQueue, episodes: (any PodcastEpisodeSource)?) {
        self.queue = queue
        self.episodes = episodes
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

    /// Undoes ``attach(to:)``, cancelling any preparation and any advance in flight.
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
        reset()
    }

    /// Progress changed for `key` (synced, or from another device): prepares again when it is the
    /// next item, or an episode of the current podcast (finishing one changes which is next).
    public func progressDidChange(for key: MediaKey) {
        guard let current, key.serverConnectionID == queue.serverConnectionID else { return }
        let samePodcast =
            current.episodeId != nil && key.episodeId != nil && key.libraryItemId == current.libraryItemId
        guard samePodcast || key == candidate?.key || key == firstQueued(after: current) else { return }
        recompute(refetchListing: samePodcast)
    }

    /// The network path or the connection's reachability changed: checks the streaming policy
    /// and fetches the next item's progress again.
    public func connectionDidChange() {
        guard current != nil else { return }
        recompute()
    }

    // MARK: NextItemProvider

    func preparedNext(after key: MediaKey) -> PreparedNextItem? {
        guard key == current, let prepared, prepared.key == candidate?.key else { return nil }
        return prepared
    }

    func prepareNext(after key: MediaKey) async -> PreparedNextItem? {
        guard key == current else { return nil }
        if prepared == nil, task == nil { recompute() }
        while prepared == nil, let running = task {
            await running.value
            if task == running { break }
        }
        return preparedNext(after: key)
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
        case .itemChanged:
            reset()
        case .sessionStarted(_, let key):
            queue.remove(key)
        case .loaded:
            current = coordinator?.mediaKey
            refreshedNearEnd = false
            recompute(refetchListing: true)
        case .tick(let time):
            guard current != nil, !refreshedNearEnd, let duration = coordinator?.duration, duration > 0,
                duration - time <= Self.nearEndWindow
            else { return }
            refreshedNearEnd = true
            // The earlier preparation stays usable until this one replaces it.
            recompute(refetchListing: true, keepPrepared: true)
        case .ended:
            if let current, current.episodeId != nil { endedEpisodes.insert(current) }
        case .playbackStarted, .paused, .didSeek, .failed, .sessionWillClose:
            break
        }
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
        refreshedNearEnd = false
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
            return
        }
        candidate = next
        if prepared?.key != next.key { prepared = nil }
        let item = await coordinator.prepareStart(for: next.key)
        guard self.revision == revision else { return }
        prepared = item
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
            listing = try await episodes.listing(podcastItemID: key.libraryItemId)
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
