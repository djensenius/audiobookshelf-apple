import ABSAPI
import ABSCore

/// The RSS feed entry of a book or podcast (legacy `ItemMoreMenuModal.vue` `showRSSFeedOption`):
/// shown once the item has loaded, when it has a feed open or tracks or episodes to put in one.
/// Who may see it is the caller's check (``RssFeedModel/canManageFeeds(_:)``).
public struct RssFeedItemEntry: Sendable, Hashable {
    public let target: RssFeedTarget
    /// The item had a feed open when it was fetched (`include=rssfeed`).
    public let isOpen: Bool
    /// A podcast episode has no publication date (legacy `hasEpisodesWithoutPubDate`).
    public let hasEpisodesWithoutPubDate: Bool

    /// `nil` when the item hasn't loaded, or has no feed open and nothing to put in one.
    public init?(item: LibraryItem?) {
        guard let item else { return nil }
        let episodes = item.podcast?.episodes ?? []
        let hasTracks = !(item.book?.tracks ?? []).isEmpty || !(item.book?.audioFiles ?? []).isEmpty
        guard item.rssFeed != nil || hasTracks || !episodes.isEmpty else { return nil }
        target = RssFeedTarget(.item, id: item.id)
        isOpen = item.rssFeed != nil
        // Legacy `!ep.pubDate`: a missing or empty date.
        hasEpisodesWithoutPubDate = episodes.contains { $0.pubDate?.isEmpty ?? true }
    }
}
