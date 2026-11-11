import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct PlayerDisplayInfoTests {
    private let key = FakePlaybackControl.key()

    private func record(
        key: MediaKey = FakePlaybackControl.key(), title: String? = "Restored", coverPath: String? = "/cover.jpg"
    ) -> LastPlayedRecord {
        LastPlayedRecord(
            serverConnectionID: key.serverConnectionID, libraryItemID: key.libraryItemId, episodeID: key.episodeId,
            position: 120, duration: 400, timestamp: Date(timeIntervalSince1970: 0), title: title,
            author: "Restored Author", coverPath: coverPath, chapterTitle: "Restored Chapter")
    }

    @Test func bookShowsDisplayAuthorAndCover() {
        let info = PlayerDisplayInfo(session: FakePlaybackControl.bookSession(), key: key)
        #expect(info.title == "Dune")
        #expect(info.author == "Frank Herbert")
        #expect(info.chapterTitle == nil)
        #expect(
            info.coverKey
                == ImageKey(
                    serverID: FakePlaybackControl.serverID, kind: .itemCover, entityID: "li_book",
                    updatedAt: 1_700_000_000_000))
    }

    @Test func podcastShowsTheShowAsAuthor() {
        let episodeKey = FakePlaybackControl.key(item: "li_pod", episode: "ep_1")
        let session = PlaybackSession(
            id: "sess", libraryItemId: "li_pod", episodeId: "ep_1", mediaType: .podcast,
            mediaMetadata: .podcast(PodcastMetadata(title: "The Show", author: "Host")), displayTitle: "Episode 1",
            displayAuthor: "Host", coverPath: "/pod.jpg")
        let info = PlayerDisplayInfo(session: session, key: episodeKey)
        #expect(info.title == "Episode 1")
        #expect(info.author == "The Show")
        #expect(info.coverKey?.entityID == "li_pod")
    }

    @Test func recordSeedsTextChapterAndCover() {
        let info = PlayerDisplayInfo(record: record())
        #expect(info.key == key)
        #expect(info.title == "Restored")
        #expect(info.author == "Restored Author")
        #expect(info.chapterTitle == "Restored Chapter")
        #expect(info.coverKey?.entityID == "li_book")
        #expect(info.coverKey?.updatedAt == nil)
    }

    @Test func coverFollowsCoverPath() throws {
        #expect(PlayerDisplayInfo(record: record(coverPath: nil)).coverKey == nil)
        #expect(PlayerDisplayInfo(record: record(coverPath: "")).coverKey == nil)
        let external = try #require(PlayerDisplayInfo(record: record(coverPath: "https://img.example/c.jpg")).coverKey)
        #expect(external.externalURL == URL(string: "https://img.example/c.jpg"))
        #expect(PlayerDisplayInfo(record: record()).coverKey?.externalURL == nil)
    }

    @Test func missingTextIsEmpty() {
        let session = PlaybackSession(id: "sess", libraryItemId: "li_book", mediaType: .book)
        let info = PlayerDisplayInfo(session: session, key: key)
        #expect(info.title.isEmpty)
        #expect(info.author.isEmpty)
        #expect(info.coverKey == nil)
        #expect(PlayerDisplayInfo(record: record(title: nil)).title.isEmpty)
    }

    @Test func resolveWithoutItemIsNil() {
        let previous = PlayerDisplayInfo(record: record())
        #expect(
            PlayerDisplayInfo.resolve(
                key: nil, session: FakePlaybackControl.bookSession(), restoredRecord: record(), retaining: previous)
                == nil)
        #expect(PlayerDisplayInfo.resolve(key: key, session: nil, restoredRecord: nil, retaining: nil) == nil)
    }

    @Test func resolvePrefersTheMatchingSessionAndKeepsTheChapterTitle() {
        var previous = PlayerDisplayInfo(record: record())
        previous.chapterTitle = "Seen"
        let info = PlayerDisplayInfo.resolve(
            key: key, session: FakePlaybackControl.bookSession(), restoredRecord: record(), retaining: previous)
        #expect(info?.title == "Dune")
        #expect(info?.chapterTitle == "Seen")
    }

    @Test func resolveKeepsTheLastTextWhenTheSessionDrops() {
        let live = PlayerDisplayInfo(session: FakePlaybackControl.bookSession(), key: key)
        // A failed load keeps the restored record; it must not overwrite the live text.
        let info = PlayerDisplayInfo.resolve(key: key, session: nil, restoredRecord: record(), retaining: live)
        #expect(info == live)
    }

    @Test func resolveIgnoresAnotherItemsSessionAndText() {
        let otherKey = FakePlaybackControl.key(item: "li_other")
        let other = PlayerDisplayInfo(session: FakePlaybackControl.bookSession(item: "li_other"), key: otherKey)
        let info = PlayerDisplayInfo.resolve(
            key: key, session: FakePlaybackControl.bookSession(item: "li_other"), restoredRecord: record(),
            retaining: other)
        #expect(info?.title == "Restored")
        #expect(info?.key == key)
        let episode = PlayerDisplayInfo.resolve(
            key: FakePlaybackControl.key(episode: "ep_2"), session: FakePlaybackControl.bookSession(),
            restoredRecord: nil, retaining: nil)
        #expect(episode == nil)
    }
}
