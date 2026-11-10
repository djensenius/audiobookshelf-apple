import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "PlaybackQueue")

/// Picks what plays when an item reaches its end; set as
/// ``PlaybackCoordinator/nextItemProvider``.
@MainActor
public protocol NextItemProvider: AnyObject {
    /// The media to play after `key` ended, or `nil` to stay at the end. The coordinator ignores
    /// the answer if anything else happened to playback while it waited.
    func nextItem(after key: MediaKey) async -> MediaKey?
}

/// Auto-advance (P2-13): after an item ends, plays the first queued item; with an empty queue,
/// after a podcast episode, plays the podcast's next unfinished episode (see
/// ``PodcastEpisodeListing/nextUnfinished(after:)``). A queued item leaves the queue once a
/// session for it starts, however it was started; restoring it at launch doesn't count.
@MainActor
public final class PlaybackQueueAdvancer: NextItemProvider {
    public let queue: PlaybackQueue
    private let episodes: (any PodcastEpisodeSource)?
    private var observerToken: PlaybackObserverToken?

    /// - Parameter episodes: Where podcast episodes come from; `nil` turns off the podcast fallback.
    public init(queue: PlaybackQueue, episodes: (any PodcastEpisodeSource)?) {
        self.queue = queue
        self.episodes = episodes
    }

    /// Becomes `coordinator`'s ``PlaybackCoordinator/nextItemProvider`` and removes items from the
    /// queue as their sessions start. Attach to one coordinator at a time.
    public func attach(to coordinator: PlaybackCoordinator) {
        guard observerToken == nil else { return }
        coordinator.nextItemProvider = self
        observerToken = coordinator.addObserver { [weak queue] event in
            if case .sessionStarted(_, let key) = event { queue?.remove(key) }
        }
    }

    /// Undoes ``attach(to:)``: stops following `coordinator`, and stops being its
    /// ``PlaybackCoordinator/nextItemProvider`` unless another provider replaced this one.
    public func detach(from coordinator: PlaybackCoordinator) {
        if let observerToken { coordinator.removeObserver(observerToken) }
        observerToken = nil
        if coordinator.nextItemProvider === self { coordinator.nextItemProvider = nil }
    }

    public func nextItem(after key: MediaKey) async -> MediaKey? {
        guard key.serverConnectionID == queue.serverConnectionID else { return nil }
        if let queued = firstQueued(after: key) { return queued }
        guard let episodeID = key.episodeId, let episodes else { return nil }
        let listing: PodcastEpisodeListing
        do {
            listing = try await episodes.listing(podcastItemID: key.libraryItemId)
        } catch {
            logger.info("Next episode unavailable: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        // Something queued while the episodes loaded still comes first.
        if let queued = firstQueued(after: key) { return queued }
        guard let next = listing.nextUnfinished(after: episodeID) else { return nil }
        return MediaKey(
            serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId, episodeId: next.id)
    }

    private func firstQueued(after key: MediaKey) -> MediaKey? {
        queue.items.lazy.map { $0.key(serverConnectionID: self.queue.serverConnectionID) }.first { $0 != key }
    }
}
