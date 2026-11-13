import ABSCore
import ABSPlayback
import Foundation

/// Where "Play next" and "Add to queue" put an item in the play queue.
public enum QueuePlacement: Sendable, Hashable, CaseIterable {
    /// First, so it plays after the current item.
    case next
    /// Last.
    case end
}

extension QueueItem {
    /// The queue entry for a book, or for `episode` of a podcast, with the title, subtitle and
    /// duration its card shows (``ItemSummary/init(item:episode:)``) and the item's cover.
    ///
    /// `nil` for what can't be played: a podcast without an episode, a collapsed series, an item
    /// missing on the server, or a book without audio.
    public init?(item: LibraryItem, episode: PodcastEpisode? = nil) {
        let summary = ItemSummary(item: item, episode: episode)
        guard summary.kind == .book || summary.kind == .episode, !summary.isMissing, summary.hasAudio else {
            return nil
        }
        self.init(
            libraryItemID: summary.itemID, episodeID: summary.episodeID, title: summary.title,
            subtitle: summary.subtitle, coverPath: item.media?.coverPath, duration: summary.duration)
    }
}

extension PlaybackQueueControl {
    /// Whether `item` is the media the player has loaded. It can't be queued: the queue advances
    /// past the current media (``PlaybackQueueAdvancer``), so it would never play from the queue.
    public func isCurrent(_ item: QueueItem) -> Bool {
        currentMediaKey == item.key(serverConnectionID: serverConnectionID)
    }

    /// Queues `item` at `placement`; an item already queued moves there.
    ///
    /// - Returns: `false`, queueing nothing, when `item` is the current media (``isCurrent(_:)``).
    @discardableResult
    public func add(_ item: QueueItem, at placement: QueuePlacement) -> Bool {
        guard !isCurrent(item) else { return false }
        switch placement {
        case .next: playNext(item)
        case .end: addToEnd(item)
        }
        return true
    }
}
