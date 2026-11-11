import ABSAPI
import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

private typealias F = GroupFixtures

@MainActor
@Suite struct CollectionDetailModelTests {
    @Test func loadsNameDescriptionAndRowsInOrder() async throws {
        let service = FakeGroupsService(collectionHandler: { id in
            F.collection(id, name: "Sci-Fi", description: "Space.", books: [F.book("b2"), F.book("b1"), F.book("b2")])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())
        #expect(model.phase == .idle)

        await model.loadIfNeeded()

        #expect(model.phase == .loaded)
        let detail = try #require(model.detail)
        #expect(detail.id == "c1")
        #expect(detail.name == "Sci-Fi")
        #expect(detail.description == "Space.")
        // The repeated book keeps its first row.
        #expect(detail.members.map(\.id) == ["b2", "b1"])
        #expect(detail.members.map(\.summary.title) == ["Title b2", "Title b1"])
        #expect(detail.members.allSatisfy { $0.summary.kind == .book && $0.target.episodeID == nil })
        #expect(detail.covers.map(\.entityID) == ["b2", "b1"])
    }

    @Test func emptyCollectionHasNothingToPlay() async throws {
        let service = FakeGroupsService(collectionHandler: { id in F.collection(id, description: "  ", books: []) })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.isEmpty)
        #expect(model.detail?.description == nil)
        #expect(model.playTargets.isEmpty)
        #expect(model.nextToPlay == nil)
    }

    @Test func playsOnlyBooksThatArePresentValidAndHaveTracks() async throws {
        let service = FakeGroupsService(collectionHandler: { id in
            F.collection(
                id,
                books: [
                    F.book("missing", isMissing: true), F.book("ok1"), F.book("invalid", isInvalid: true),
                    F.book("ebook", tracks: 0), F.book("ok2"),
                ])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.detail?.members.count == 5)
        #expect(model.playTargets == [GroupPlayTarget(itemID: "ok1"), GroupPlayTarget(itemID: "ok2")])
        #expect(model.nextToPlay == GroupPlayTarget(itemID: "ok1"))
    }

    @Test func nextToPlayFollowsProgress() async throws {
        let cache = ProgressCache()
        let service = FakeGroupsService(collectionHandler: { id in
            F.collection(id, books: [F.book("a"), F.book("b"), F.book("c")])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: cache)
        await model.load()
        let (a, b, c) = (GroupPlayTarget(itemID: "a"), GroupPlayTarget(itemID: "b"), GroupPlayTarget(itemID: "c"))

        cache.apply(F.progress(a, finished: true, at: 1))
        cache.apply(F.progress(b, finished: false, at: 1))
        #expect(model.nextToPlay == b)
        #expect(model.detail.map { model.progress(of: $0.members[0]) }??.isFinished == true)

        cache.apply(F.progress(b, finished: true, at: 2))
        #expect(model.nextToPlay == c)

        cache.apply(F.progress(c, finished: true, at: 2))
        #expect(model.nextToPlay == nil)

        cache.apply(F.progress(a, finished: false, at: 3))
        #expect(model.nextToPlay == a)
    }

    @Test func nextToPlayInvalidatesOnlyForTheCurrentTarget() async throws {
        let cache = ProgressCache()
        let service = FakeGroupsService(collectionHandler: { id in
            F.collection(id, books: [F.book("a"), F.book("b"), F.book("c")])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: cache)
        await model.load()
        let changed = Locked(false)

        let next = withObservationTracking {
            model.nextToPlay
        } onChange: {
            changed.value = true
        }
        #expect(next == GroupPlayTarget(itemID: "a"))

        cache.apply(F.progress(GroupPlayTarget(itemID: "c"), finished: true, at: 1))
        #expect(!changed.value)
        cache.apply(F.progress(GroupPlayTarget(itemID: "a"), finished: true, at: 1))
        #expect(changed.value)
        #expect(model.nextToPlay == GroupPlayTarget(itemID: "b"))
    }

    @Test func aSuccessfulReloadClearsNotFound() async throws {
        let answer = Locked<Result<LibraryCollection, APIError>>(.failure(.notFound))
        let service = FakeGroupsService(collectionHandler: { _ in try answer.value.get() })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())
        await model.load()
        #expect(model.phase == .notFound)

        answer.value = .success(F.collection("c1", books: [F.book("a")]))
        await model.load()

        #expect(model.phase == .loaded)
        #expect(!model.isNotFound)
        #expect(model.error == nil)
    }

    @Test func aCancelledLoadLeavesNoError() async throws {
        let service = FakeGroupsService(collectionHandler: { _ in throw CancellationError() })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.error == nil)
        #expect(model.phase == .idle)
        #expect(!model.isLoading)
    }

    @Test func loadIfNeededLoadsOnce() async throws {
        let calls = Locked(0)
        let service = FakeGroupsService(collectionHandler: { id in
            calls.value += 1
            return F.collection(id, books: [])
        })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        #expect(calls.value == 1)
        #expect(model.phase == .loaded)
    }

    @Test func notFoundDropsTheGroup() async throws {
        let answer = Locked<Result<LibraryCollection, APIError>>(.success(F.collection("c1", books: [F.book("a")])))
        let service = FakeGroupsService(collectionHandler: { _ in try answer.value.get() })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())
        await model.load()
        #expect(model.phase == .loaded)

        answer.value = .failure(.notFound)
        await model.load()

        #expect(model.phase == .notFound)
        #expect(model.isNotFound)
        #expect(model.detail == nil)
        #expect(model.playTargets.isEmpty)
    }

    @Test func otherErrorsKeepTheLoadedGroup() async throws {
        let answer = Locked<Result<LibraryCollection, APIError>>(.failure(.timedOut))
        let service = FakeGroupsService(collectionHandler: { _ in try answer.value.get() })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())

        await model.load()
        #expect(model.phase == .failed)
        #expect(!model.isNotFound)

        answer.value = .success(F.collection("c1", books: [F.book("a")]))
        await model.load()
        answer.value = .failure(.timedOut)
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.error as? APIError == .timedOut)
        #expect(model.detail?.members.map(\.id) == ["a"])
    }

    @Test func aStaleResponseIsDropped() async throws {
        let gate = GatedCalls<String, LibraryCollection>()
        let service = FakeGroupsService(collectionHandler: { id in try await gate.call(id) })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache())
        var calls = gate.calls.makeAsyncIterator()

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        #expect(model.phase == .loading)
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())
        secondCall.reply.resume(returning: F.collection("c1", name: "New", books: []))
        await second.value
        firstCall.reply.resume(returning: F.collection("c1", name: "Old", books: []))
        await first.value

        #expect(model.detail?.name == "New")
    }
}

@MainActor
@Suite struct PlaylistDetailModelTests {
    @Test func mapsMixedBooksAndEpisodes() async throws {
        let show = F.podcast("show")
        let service = FakeGroupsService(playlistHandler: { id in
            F.playlist(
                id, name: "Mix",
                items: [F.bookEntry(F.book("b1")), F.episodeEntry(show, F.episode("e1")), F.bookEntry(F.book("b2"))])
        })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: ProgressCache())

        await model.load()

        let members = try #require(model.detail?.members)
        #expect(members.map(\.id) == ["b1", "show-e1", "b2"])
        #expect(members.map(\.summary.kind) == [.book, .episode, .book])
        #expect(members[1].summary.title == "Episode e1")
        #expect(members[1].summary.subtitle == "Show show")
        #expect(members[1].target == GroupPlayTarget(itemID: "show", episodeID: "e1"))
        #expect(model.detail?.covers.map(\.entityID) == ["b1", "show", "b2"])
        #expect(model.playTargets.count == 3)
    }

    @Test func playsOnlyPresentBooksWithTracksAndEpisodesWithAudioFiles() async throws {
        let show = F.podcast("show")
        let gone = F.podcast("gone", isMissing: true)
        let service = FakeGroupsService(playlistHandler: { id in
            F.playlist(
                id,
                items: [
                    F.episodeEntry(show, F.episode("noaudio", hasAudio: false)),
                    F.episodeEntry(gone, F.episode("e0")),
                    F.bookEntry(F.book("ebook", tracks: 0)),
                    PlaylistItem(libraryItemId: "show", episodeId: "unexpanded", libraryItem: show),
                    PlaylistItem(libraryItemId: "lost"),
                    PlaylistItem(libraryItemId: "show"),
                    F.episodeEntry(show, F.episode("e1")),
                    F.bookEntry(F.book("b1")),
                ])
        })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: ProgressCache())

        await model.load()

        let members = try #require(model.detail?.members)
        #expect(members.count == 8)
        // A view greying rows by the summary's flags agrees with play-all.
        #expect(members.allSatisfy { $0.isPlayable == (!$0.summary.isMissing && $0.summary.hasAudio) })
        #expect(members[0].summary.isMissing == false)
        #expect(members[0].summary.hasAudio == false)
        #expect(members[3].summary.isMissing)
        #expect(members[3].summary.subtitle == "Show show")
        #expect(members[3].summary.cover?.entityID == "show")
        #expect(
            model.playTargets == [GroupPlayTarget(itemID: "show", episodeID: "e1"), GroupPlayTarget(itemID: "b1")])
    }

    @Test func nextToPlayMixesEpisodeAndBookProgress() async throws {
        let cache = ProgressCache()
        let show = F.podcast("show")
        let service = FakeGroupsService(playlistHandler: { id in
            F.playlist(
                id,
                items: [
                    F.episodeEntry(show, F.episode("e1")), F.bookEntry(F.book("b1")),
                    F.episodeEntry(show, F.episode("e2")),
                ])
        })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: cache)
        await model.load()
        let e1 = GroupPlayTarget(itemID: "show", episodeID: "e1")
        let e2 = GroupPlayTarget(itemID: "show", episodeID: "e2")
        let b1 = GroupPlayTarget(itemID: "b1")
        #expect(model.nextToPlay == e1)

        // Progress on the podcast as a whole isn't the episode's.
        cache.apply(F.progress(GroupPlayTarget(itemID: "show"), finished: true, at: 1))
        #expect(model.nextToPlay == e1)

        cache.apply(F.progress(e1, finished: true, at: 1))
        #expect(model.nextToPlay == b1)
        cache.apply(F.progress(b1, finished: true, at: 1))
        #expect(model.nextToPlay == e2)
        cache.apply(F.progress(e2, finished: true, at: 1))
        #expect(model.nextToPlay == nil)
    }

    @Test func malformedMembersKeepTheirRows() async throws {
        // The second member's episode and the third member's item fail to decode; the fourth
        // has no `libraryItemId` and is skipped.
        let json = """
            {"id":"p1","libraryId":"lib","name":"Mixed","items":[\
            {"libraryItemId":"b1","libraryItem":{"id":"b1","libraryId":"lib","mediaType":"book",\
            "media":{"id":"m1","metadata":{"title":"One"},"tracks":[{"duration":5}]}}},\
            {"libraryItemId":"show","episodeId":"e1","episode":{"title":5},"libraryItem":{"id":"show",\
            "libraryId":"lib","mediaType":"podcast","media":{"id":"m2","metadata":{"title":"Show"}}}},\
            {"libraryItemId":"b2","libraryItem":{"id":false}},\
            {"episodeId":"orphan"}]}
            """
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
        let service = FakeGroupsService(playlistHandler: { _ in playlist })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: ProgressCache())

        await model.load()

        let members = try #require(model.detail?.members)
        #expect(members.map(\.id) == ["b1", "show-e1", "b2"])
        #expect(members.map(\.isPlayable) == [true, false, false])
        #expect(members[1].summary.kind == .episode)
        #expect(members[1].summary.subtitle == "Show")
        #expect(members.map(\.summary.isMissing) == [false, true, true])
        #expect(members.map(\.summary.hasAudio) == [true, false, false])
        #expect(members[1].summary.title == "show-e1")
        #expect(members[1].summary.cover?.entityID == nil)
        #expect(members[2].summary.title == "b2")
        #expect(model.nextToPlay == GroupPlayTarget(itemID: "b1"))
    }

    @Test func notFoundSurfacesForTheViewToPop() async throws {
        let service = FakeGroupsService(playlistHandler: { _ in throw APIError.notFound })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: ProgressCache())

        await model.loadIfNeeded()

        #expect(model.phase == .notFound)
        #expect(model.error as? APIError == .notFound)
    }
}
