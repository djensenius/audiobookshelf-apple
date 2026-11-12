import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let openFeed = RssFeed(id: "feed-1", entityType: "libraryItem", entityId: "li-1", feedUrl: "/feed/li-1")

private func book(tracks: Int, audioFiles: Int = 0, feed: RssFeed? = nil) -> LibraryItem {
    let book = Book(
        id: "b-1", metadata: BookMetadata(title: "Book"),
        audioFiles: (0..<audioFiles).map { AudioFile(ino: "ino-\($0)") },
        tracks: (0..<tracks).map { AudioTrack(index: $0 + 1, duration: 60) })
    return LibraryItem(id: "li-1", libraryId: "lib-1", mediaType: .book, media: .book(book), rssFeed: feed)
}

private func podcast(pubDates: [String?]) -> LibraryItem {
    let episodes = pubDates.enumerated().map { PodcastEpisode(id: "ep-\($0.offset)", pubDate: $0.element) }
    let podcast = Podcast(id: "p-1", metadata: PodcastMetadata(title: "Podcast"), episodes: episodes)
    return LibraryItem(id: "li-1", libraryId: "lib-1", mediaType: .podcast, media: .podcast(podcast))
}

@Suite struct RssFeedItemEntryTests {
    @Test func nothingShowsUntilTheItemHasLoaded() {
        #expect(RssFeedItemEntry(item: nil) == nil)
    }

    @Test func aBookWithTracksGetsAnItemFeed() throws {
        let entry = try #require(RssFeedItemEntry(item: book(tracks: 2)))
        #expect(entry.target == RssFeedTarget(.item, id: "li-1"))
        #expect(!entry.isOpen)
        #expect(!entry.hasEpisodesWithoutPubDate)
    }

    /// Legacy: "Cannot open RSS feed with no episodes/tracks", but an open one still shows.
    @Test func anItemWithNothingToPublishShowsOnlyAnOpenFeed() throws {
        #expect(RssFeedItemEntry(item: book(tracks: 0)) == nil)
        #expect(RssFeedItemEntry(item: podcast(pubDates: [])) == nil)
        let entry = try #require(RssFeedItemEntry(item: book(tracks: 0, feed: openFeed)))
        #expect(entry.isOpen)
    }

    /// Legacy checks `media.tracks`: scanned files that are all excluded publish nothing.
    @Test func scannedFilesWithoutTracksPublishNothing() throws {
        #expect(RssFeedItemEntry(item: book(tracks: 0, audioFiles: 2)) == nil)
        let entry = try #require(RssFeedItemEntry(item: book(tracks: 0, audioFiles: 2, feed: openFeed)))
        #expect(entry.isOpen)
    }

    @Test(arguments: [
        (["Tue, 01 Oct 2024 08:00:00 GMT"] as [String?], false), (["Tue, 01 Oct 2024 08:00:00 GMT", nil], true),
        ([""], true),
    ])
    func podcastsWithUndatedEpisodesWarn(pubDates: [String?], warns: Bool) throws {
        let entry = try #require(RssFeedItemEntry(item: podcast(pubDates: pubDates)))
        #expect(entry.hasEpisodesWithoutPubDate == warns)
    }

    @Test func theFeedComesWithTheItem() throws {
        let json = #"""
            {"id":"li-1","libraryId":"lib-1","mediaType":"book",
            "rssFeed":{"id":"feed-1","entityType":"libraryItem","entityId":"li-1","feedUrl":"/feed/li-1",
            "meta":{"title":"Book","preventIndexing":true}}}
            """#
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        #expect(item.rssFeed?.id == "feed-1")
        #expect(item.rssFeed?.meta?.preventIndexing == true)
        #expect(RssFeedItemEntry(item: item)?.isOpen == true)
    }

    @Test func aFeedThisClientCantReadDoesntFailTheItem() throws {
        let json = #"{"id":"li-1","libraryId":"lib-1","mediaType":"book","rssFeed":{"id":7}}"#
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        #expect(item.rssFeed == nil)
    }
}
