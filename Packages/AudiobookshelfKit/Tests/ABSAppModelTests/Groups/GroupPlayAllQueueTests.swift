import ABSAPI
import ABSCore
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

private typealias F = GroupFixtures

/// What play-all queues after the member it starts (#354).
@MainActor
@Suite struct GroupPlayAllQueueTests {
    @Test func queuesThePlayableUnfinishedBooksAfterTheStartInOrder() async throws {
        let cache = ProgressCache()
        let service = FakeGroupsService(collectionHandler: { id in
            F.collection(
                id,
                books: [
                    F.book("done"), F.book("a"), F.book("missing", isMissing: true), F.book("b"),
                    F.book("invalid", isInvalid: true), F.book("ebook", tracks: 0), F.book("finished"),
                    F.book("c", cover: nil),
                ])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: cache)
        await model.load()
        cache.apply(F.progress(GroupPlayTarget(itemID: "done"), finished: true, at: 1))
        cache.apply(F.progress(GroupPlayTarget(itemID: "finished"), finished: true, at: 1))
        let next = try #require(model.nextToPlay)
        #expect(next == GroupPlayTarget(itemID: "a"))

        let queued = model.queue(after: next)

        #expect(queued.map(\.id) == ["b|", "c|"])
        let b = try #require(queued.first)
        #expect(b.title == "Title b")
        #expect(b.episodeID == nil)
        #expect(b.coverPath == "/covers/x.jpg")
        #expect(b.duration == model.detail?.members[3].summary.duration)
        #expect(queued.last?.coverPath == nil)
    }

    @Test func queuesAPlaylistsEpisodesAsEpisodes() async throws {
        let cache = ProgressCache()
        let show = F.podcast("show")
        let service = FakeGroupsService(playlistHandler: { id in
            F.playlist(
                id,
                items: [
                    F.episodeEntry(show, F.episode("e1")), F.episodeEntry(show, F.episode("silent", hasAudio: false)),
                    F.bookEntry(F.book("b1")), F.episodeEntry(show, F.episode("e2")),
                    F.episodeEntry(show, F.episode("e3")),
                ])
        })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: cache)
        await model.load()
        cache.apply(F.progress(GroupPlayTarget(itemID: "show", episodeID: "e3"), finished: true, at: 1))

        let queued = model.queue(after: GroupPlayTarget(itemID: "show", episodeID: "e1"))

        #expect(queued.map(\.id) == ["b1|", "show|e2"])
        let episode = try #require(queued.last)
        #expect(episode.libraryItemID == "show")
        #expect(episode.episodeID == "e2")
        #expect(episode.title == "Episode e2")
        #expect(episode.coverPath == "/c.jpg")
    }

    @Test func queuesNothingAfterTheLastMemberOrANonMember() async throws {
        let service = FakeGroupsService(collectionHandler: { id in
            F.collection(id, books: [F.book("a"), F.book("b")])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())
        #expect(model.queue(after: GroupPlayTarget(itemID: "a")).isEmpty)
        await model.load()

        #expect(model.queue(after: GroupPlayTarget(itemID: "b")).isEmpty)
        #expect(model.queue(after: GroupPlayTarget(itemID: "elsewhere")).isEmpty)
    }
}
