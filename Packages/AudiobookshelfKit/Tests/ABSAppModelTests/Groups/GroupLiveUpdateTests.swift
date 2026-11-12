import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Testing

@testable import ABSAppModel

private typealias F = GroupFixtures

private let accountA = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)
private let accountB = LibraryConnectionKey(connectionID: identityB.connectionID, userID: identityB.userID)

private func collection(_ id: String, name: String? = nil, books: [LibraryItem] = []) -> LibraryCollection {
    F.collection(id, name: name, books: books)
}

private func playlist(_ id: String, name: String? = nil, owner: String = identityA.userID) -> Playlist {
    Playlist(id: id, libraryId: "lib", userId: owner, name: name ?? id)
}

/// A collections list of library `lib` whose pages come from `server`, which the test changes; `requests` logs
/// the pages asked for, and a page fails while `fails` is true.
@MainActor
private func collectionList(
    server: Locked<[LibraryCollection]>, requests: Locked<[Int]>, pageSize: Int = 20,
    fails: Locked<Bool> = Locked(false)
) async -> ItemListModel<String, GroupSummary> {
    let service = FakeGroupsService(collectionsHandler: { _, page, limit in
        requests.value.append(page)
        if fails.value { throw TestError.offline }
        let all = server.value
        let rows = Array(all.dropFirst(page * limit).prefix(limit))
        return PagedResults(results: rows, total: all.count, limit: limit, page: page)
    })
    let list = ItemListModel.collections(
        service: service, libraryID: "lib", pageSize: pageSize, connectionKey: accountA)
    await list.loadNextPage()?.value
    return list
}

@MainActor
private func playlistList(_ playlists: [Playlist], requests: Locked<[Int]>) async -> ItemListModel<
    String, GroupSummary
> {
    let service = FakeGroupsService(playlistsHandler: { _, page, limit in
        requests.value.append(page)
        return PagedResults(results: playlists, total: playlists.count, limit: limit, page: page)
    })
    let list = ItemListModel.playlists(service: service, libraryID: "lib", connectionKey: accountA)
    await list.loadNextPage()?.value
    return list
}

@MainActor
@Suite struct GroupListLiveUpdateTests {
    @Test func anAdditionReloadsTheList() async throws {
        let server = Locked([collection("c1"), collection("c2")])
        let requests = Locked<[Int]>([])
        let list = await collectionList(server: server, requests: requests)

        server.value.insert(collection("c0"), at: 0)
        list.apply(.collection(.added(collection("c0"), libraryID: "lib")), kind: .collection)
        await list.loadNextPage()?.value

        #expect(list.items.map(\.id) == ["c0", "c1", "c2"])
        #expect(list.total == 3)
        #expect(requests.value == [0, 0])
    }

    @Test func anUpdateReplacesTheLoadedGroup() async throws {
        let requests = Locked<[Int]>([])
        let list = await collectionList(server: Locked([collection("c1"), collection("c2")]), requests: requests)

        let renamed = collection("c2", name: "Renamed", books: [F.book("b1")])
        list.apply(.collection(.updated(renamed, libraryID: "lib")), kind: .collection)
        // A group the list hasn't loaded stays out.
        list.apply(.collection(.updated(collection("c9"), libraryID: "lib")), kind: .collection)

        #expect(list.items.map(\.id) == ["c1", "c2"])
        #expect(list.items[1] == GroupSummary(collection: renamed))
        #expect(requests.value == [0])
    }

    @Test func aRemovalDropsTheGroup() async throws {
        let requests = Locked<[Int]>([])
        let list = await collectionList(
            server: Locked([collection("c1"), collection("c2"), collection("c3")]), requests: requests)

        list.apply(.collection(.removed(id: "c1", libraryID: "lib")), kind: .collection)
        list.apply(.collection(.removed(id: "c9", libraryID: "lib")), kind: .collection)

        #expect(list.items.map(\.id) == ["c2", "c3"])
        #expect(list.total == 2)
        // The list had reached its end, so nothing reloads.
        #expect(requests.value == [0])
        // The later groups moved up, and are still found by ID.
        list.apply(.collection(.updated(collection("c3", name: "Last"), libraryID: "lib")), kind: .collection)
        #expect(list.items.map(\.name) == ["c2", "Last"])
    }

    @Test func aRemovalBeforeTheEndReloadsSoNoGroupIsSkipped() async throws {
        let server = Locked((1...4).map { collection("c\($0)") })
        let requests = Locked<[Int]>([])
        let list = await collectionList(server: server, requests: requests, pageSize: 2)
        #expect(!list.reachedEnd)

        server.value.removeFirst()
        list.apply(.collection(.removed(id: "c1", libraryID: "lib")), kind: .collection)
        #expect(list.items.map(\.id) == ["c2"])
        #expect(list.total == 3)
        await list.loadNextPage()?.value

        // c3 moved into the first page; the next page would have skipped it.
        #expect(list.items.map(\.id) == ["c2", "c3"])
        #expect(requests.value == [0, 0])
    }

    @Test func aFailedRemovalRefreshRetriesFromTheFirstPage() async throws {
        let server = Locked((1...4).map { collection("c\($0)") })
        let requests = Locked<[Int]>([])
        let fails = Locked(false)
        let list = await collectionList(server: server, requests: requests, pageSize: 2, fails: fails)

        server.value.removeFirst()
        fails.value = true
        list.apply(.collection(.removed(id: "c1", libraryID: "lib")), kind: .collection)
        await list.loadNextPage()?.value
        #expect(list.error != nil)
        #expect(list.items.map(\.id) == ["c2"])

        // Retry: page 1 of the old offsets would return c4 and skip c3.
        fails.value = false
        await list.loadNextPage()?.value
        #expect(list.items.map(\.id) == ["c2", "c3"])
        await list.loadNextPage()?.value
        #expect(list.items.map(\.id) == ["c2", "c3", "c4"])
        #expect(list.reachedEnd)
        #expect(requests.value == [0, 0, 0, 1])
    }

    @Test func eachSuccessfulRefreshAdvancesTheRevision() async throws {
        let server = Locked((1...4).map { collection("c\($0)") })
        let fails = Locked(false)
        let list = await collectionList(server: server, requests: Locked([]), pageSize: 2, fails: fails)
        #expect(list.refreshRevision == 0)

        // An addition past the first page leaves its card IDs as they were; only the revision
        // tells the cards to report appearing again.
        server.value.append(collection("c5"))
        list.apply(.collection(.added(collection("c5"), libraryID: "lib")), kind: .collection)
        await list.loadNextPage()?.value
        #expect(list.items.map(\.id) == ["c1", "c2"])
        #expect(list.refreshRevision == 1)

        // Neither a failed refresh nor a later page counts.
        fails.value = true
        await list.refresh()?.value
        fails.value = false
        await list.loadNextPage()?.value
        #expect(list.refreshRevision == 1)

        await list.refresh()?.value
        #expect(list.refreshRevision == 2)
    }

    @Test func changesToAnotherLibraryOrKindAreIgnored() async throws {
        let requests = Locked<[Int]>([])
        let list = await collectionList(server: Locked([collection("c1")]), requests: requests)

        list.apply(.collection(.added(collection("c2"), libraryID: "other")), kind: .collection)
        list.apply(.collection(.removed(id: "c1", libraryID: "other")), kind: .collection)
        list.apply(.collection(.updated(collection("c1", name: "Other"), libraryID: "other")), kind: .collection)
        list.apply(.playlist(.removed(id: "c1", libraryID: "lib"), userID: identityA.userID), kind: .collection)
        list.apply(.author(.removed(id: "c1", libraryID: "lib")), kind: .collection)
        // A collection change reaching a playlists list.
        list.apply(.collection(.removed(id: "c1", libraryID: "lib")), kind: .playlist)

        #expect(list.items.map(\.id) == ["c1"])
        #expect(list.total == 1)
        #expect(requests.value == [0])
    }

    @Test func playlistsFollowOnlyTheUsersOwnChanges() async throws {
        let requests = Locked<[Int]>([])
        let list = await playlistList([playlist("p1"), playlist("p2")], requests: requests)
        let other = identityB.userID

        list.apply(.playlist(.added(playlist("p3", owner: other), libraryID: "lib"), userID: other), kind: .playlist)
        list.apply(
            .playlist(.updated(playlist("p1", name: "Theirs"), libraryID: "lib"), userID: other), kind: .playlist)
        list.apply(.playlist(.removed(id: "p2", libraryID: "lib"), userID: other), kind: .playlist)
        #expect(list.items.map(\.name) == ["p1", "p2"])
        #expect(requests.value == [0])

        list.apply(.playlist(.updated(playlist("p1", name: "Mine"), libraryID: "lib"), userID: "a"), kind: .playlist)
        list.apply(.playlist(.removed(id: "p2", libraryID: "lib"), userID: "a"), kind: .playlist)
        #expect(list.items.map(\.name) == ["Mine"])

        list.apply(.playlist(.added(playlist("p3"), libraryID: "lib"), userID: "a"), kind: .playlist)
        await list.loadNextPage()?.value
        #expect(requests.value == [0, 0])
    }

    @Test func theStoreDeliversChangesOnlyFromItsSession() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FakeLibraryService(), connectionKey: accountA)
            let list = await collectionList(
                server: Locked([collection("c1"), collection("c2")]), requests: Locked([]))
            store.observeLibraryChanges(connectionKey: accountA, owner: list) { [weak list] in
                list?.apply($0, kind: .collection)
            }
            let removal = LibraryChange.collection(.removed(id: "c1", libraryID: "lib"))

            store.applyLibraryChange(removal, connectionKey: accountB)
            #expect(list.items.map(\.id) == ["c1", "c2"])

            store.applyLibraryChange(removal, connectionKey: accountA)
            #expect(list.items.map(\.id) == ["c2"])
        }
    }
}

@MainActor
@Suite struct GroupDetailLiveUpdateTests {
    private func loadedCollection() async -> CollectionDetailModel {
        let service = FakeGroupsService(collectionHandler: { id in collection(id, books: [F.book("b1")]) })
        let model = CollectionDetailModel(id: "c1", service: service, cache: ProgressCache(), userID: "a")
        await model.load()
        return model
    }

    private func loadedPlaylist() async -> PlaylistDetailModel {
        let service = FakeGroupsService(playlistHandler: { id in playlist(id) })
        let model = PlaylistDetailModel(id: "p1", service: service, cache: ProgressCache(), userID: "a")
        await model.load()
        return model
    }

    @Test func aCollectionUpdateReplacesTheGroupAndARemovalShowsItAsNotFound() async throws {
        let model = await loadedCollection()
        let updated = collection("c1", name: "Renamed", books: [F.book("b2"), F.book("b3")])

        model.apply(.collection(.updated(updated, libraryID: "lib")))
        #expect(model.detail == GroupDetail(collection: updated))

        model.apply(.collection(.removed(id: "c1", libraryID: "lib")))
        #expect(model.phase == .notFound)
        #expect(model.detail == nil)
    }

    @Test func otherGroupsAndKindsAreIgnored() async throws {
        let model = await loadedCollection()
        let loaded = model.detail

        model.apply(.collection(.updated(collection("c2", name: "Other"), libraryID: "lib")))
        model.apply(.collection(.removed(id: "c2", libraryID: "lib")))
        model.apply(.playlist(.removed(id: "c1", libraryID: "lib"), userID: "a"))
        model.apply(.author(.removed(id: "c1", libraryID: "lib")))

        #expect(model.phase == .loaded)
        #expect(model.detail == loaded)
    }

    @Test func theSameIDInAnotherLibraryIsIgnored() async throws {
        let collectionModel = await loadedCollection()
        let loadedCollection = collectionModel.detail
        collectionModel.apply(.collection(.updated(collection("c1", name: "Other"), libraryID: "other")))
        collectionModel.apply(.collection(.removed(id: "c1", libraryID: "other")))
        #expect(collectionModel.phase == .loaded)
        #expect(collectionModel.detail == loadedCollection)

        let playlistModel = await loadedPlaylist()
        let loadedPlaylist = playlistModel.detail
        playlistModel.apply(.playlist(.updated(playlist("p1", name: "Other"), libraryID: "other"), userID: "a"))
        playlistModel.apply(.playlist(.removed(id: "p1", libraryID: "other"), userID: "a"))
        #expect(playlistModel.phase == .loaded)
        #expect(playlistModel.detail == loadedPlaylist)
    }

    @Test func aPlaylistFollowsOnlyItsOwnersChanges() async throws {
        let model = await loadedPlaylist()
        let loaded = model.detail
        let other = identityB.userID

        model.apply(.playlist(.updated(playlist("p1", name: "Theirs", owner: other), libraryID: "lib"), userID: other))
        model.apply(.playlist(.removed(id: "p1", libraryID: "lib"), userID: other))
        model.apply(.collection(.removed(id: "p1", libraryID: "lib")))
        #expect(model.detail == loaded)

        model.apply(.playlist(.updated(playlist("p1", name: "Mine"), libraryID: "lib"), userID: "a"))
        #expect(model.detail?.name == "Mine")

        model.apply(.playlist(.removed(id: "p1", libraryID: "lib"), userID: "a"))
        #expect(model.phase == .notFound)
    }

    @Test func changesBeforeTheFirstLoadAreIgnored() async throws {
        let model = PlaylistDetailModel(id: "p1", service: FakeGroupsService(), cache: ProgressCache(), userID: "a")

        model.apply(.playlist(.updated(playlist("p1"), libraryID: "lib"), userID: "a"))
        model.apply(.playlist(.removed(id: "p1", libraryID: "lib"), userID: "a"))

        #expect(model.phase == .idle)
    }
}
