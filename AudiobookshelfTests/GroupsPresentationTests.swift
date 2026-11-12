import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Synchronization
import Testing

@testable import Audiobookshelf

private struct Failure: Error {}

/// A library client that serves the groups below, and fails the group requests while `fails` is set.
private final class FakeGroupsClient: LibraryService, GroupsService {
    let fails = Mutex(false)
    let collections: [LibraryCollection]
    let playlists: [Playlist]

    init(collections: [LibraryCollection] = [classics, emptyCollection], playlists: [Playlist] = [commute]) {
        self.collections = collections
        self.playlists = playlists
    }

    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw Failure() }

    func collectionsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<LibraryCollection> {
        try check()
        return PagedResults(results: collections, total: collections.count, limit: limit, page: page)
    }

    func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist> {
        try check()
        return PagedResults(results: playlists, total: playlists.count, limit: limit, page: page)
    }

    func collectionDetail(id: String) async throws -> LibraryCollection {
        try check()
        guard let collection = collections.first(where: { $0.id == id }) else { throw APIError.notFound }
        return collection
    }

    func playlistDetail(id: String) async throws -> Playlist {
        try check()
        guard let playlist = playlists.first(where: { $0.id == id }) else { throw APIError.notFound }
        return playlist
    }

    private func check() throws {
        if fails.withLock({ $0 }) { throw Failure() }
    }
}

/// An episode of the sample podcast with an audio file, so it can be played.
private let playableEpisode = PodcastEpisode(
    id: "ep_1", title: "Episode 1: The Red-Headed League", audioFile: AudioFile(ino: "ino_1"), duration: 2_100)
private let sherlockTitle = "The Adventures of Sherlock Holmes"
private let silentEpisode = PodcastEpisode(id: "ep_2", title: "Episode 2: A Scandal in Bohemia")

private let classics = LibraryCollection(
    id: "col_classics", libraryId: "lib_a", name: "Classics", description: "Old books.",
    books: [SampleLibrary.prideAndPrejudice, SampleLibrary.frankenstein])
private let emptyCollection = LibraryCollection(id: "col_empty", libraryId: "lib_a", name: "Empty", books: [])
/// A missing book, an episode without audio, a book and a playable episode.
private let commute = Playlist(
    id: "pl_commute", libraryId: "lib_a", name: "Commute",
    items: [
        PlaylistItem(libraryItemId: SampleLibrary.missing.id, libraryItem: SampleLibrary.missing),
        PlaylistItem(
            libraryItemId: SampleLibrary.podcast.id, episodeId: silentEpisode.id, episode: silentEpisode,
            libraryItem: SampleLibrary.podcast),
        PlaylistItem(libraryItemId: SampleLibrary.sherlock.id, libraryItem: SampleLibrary.sherlock),
        PlaylistItem(
            libraryItemId: SampleLibrary.podcast.id, episodeId: playableEpisode.id, episode: playableEpisode,
            libraryItem: SampleLibrary.podcast),
    ])

private let account = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(), userID: "user-1")

/// A store connected to `client` with settings in a throwaway defaults suite, so a test never touches the app's.
@MainActor
private func withStore(
    _ client: FakeGroupsClient = FakeGroupsClient(), _ body: (LibraryStore, LibraryStoreServices) async throws -> Void
) async throws {
    let suiteName = "GroupsPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = LibraryStore(settings: AppSettings(defaults: defaults))
    await store.connect(client: client, connectionKey: account)
    try await body(store, try #require(store.makeServices()))
}

@MainActor
private func key(_ store: LibraryStore) throws -> BrowseModelKey {
    try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
}

private func finished(_ itemID: String, episodeID: String? = nil, _ isFinished: Bool = true) -> MediaProgress {
    MediaProgress(
        id: "mp_\(itemID)_\(episodeID ?? "")", libraryItemId: itemID, episodeId: episodeID,
        progress: isFinished ? 1 : 0.5, isFinished: isFinished)
}

@MainActor
@Suite struct GroupsPresentationTests {
    @Test func listsMapToCardsThatOpenTheirGroup() async throws {
        try await withStore { store, services in
            let list = GroupPresentation.makeList(.collection, key: try key(store), services: services)
            await list.loadNextPage()?.value
            #expect(BrowseScreenState.resolve(list: list) == .loaded(failed: false))
            #expect(list.items.map(\.name) == ["Classics", "Empty"])
            #expect(list.items.map(\.covers.count) == [2, 0])
            let english = Locale(identifier: "en")
            #expect(
                list.items.map { GroupPresentation.itemCount($0.itemCount, locale: english) } == ["2 items", "0 items"])
            #expect(GroupPresentation.cardAccessibilityLabel(list.items[0], locale: english) == "Classics, 2 items")
            #expect(GroupPresentation.route(.collection, id: "col_classics") == .collection(id: "col_classics"))

            let playlists = GroupPresentation.makeList(.playlist, key: try key(store), services: services)
            await playlists.loadNextPage()?.value
            #expect(playlists.items.map(\.kind) == [.playlist])
            #expect(GroupPresentation.itemCount(playlists.items[0].itemCount, locale: english) == "4 items")
            #expect(GroupPresentation.itemCount(1, locale: english) == "1 item")
            #expect(GroupPresentation.route(.playlist, id: "pl_commute") == .playlist(id: "pl_commute"))
            #expect(GroupPresentation.tab(.collection) == .collections)
            #expect(GroupPresentation.tab(.playlist) == .playlists)
        }
    }

    @Test func emptyAndFailedListsShowTheirMessages() async throws {
        try await withStore(FakeGroupsClient(collections: [], playlists: [])) { store, services in
            let playlists = GroupPresentation.makeList(.playlist, key: try key(store), services: services)
            await playlists.loadNextPage()?.value
            #expect(BrowseScreenState.resolve(list: playlists) == .empty)
            #expect(GroupPresentation.listMessages(.playlist).empty == "MessageNoUserPlaylists")
            #expect(GroupPresentation.listMessages(.collection).empty == "MessageNoCollections")
        }
        let client = FakeGroupsClient()
        client.fails.withLock { $0 = true }
        try await withStore(client) { store, services in
            let collections = GroupPresentation.makeList(.collection, key: try key(store), services: services)
            await collections.loadNextPage()?.value
            #expect(BrowseScreenState.resolve(list: collections) == .failed)
        }
    }

    @Test func playlistRowsMixBooksAndEpisodes() async throws {
        try await withStore { store, services in
            let model = PlaylistDetailModel(id: "pl_commute", service: services, cache: store.progress)
            await model.loadIfNeeded()
            let members = try #require(model.detail?.members)
            #expect(members.map(\.summary.kind) == [.book, .episode, .book, .episode])
            #expect(
                members.map(\.summary.title) == [
                    "A Missing Book", silentEpisode.title, sherlockTitle, playableEpisode.title,
                ])
            #expect(
                members.map { ItemCardActions.route(for: $0.summary) } == [
                    .item(id: SampleLibrary.missing.id), .episode(itemID: SampleLibrary.podcast.id, episodeID: "ep_2"),
                    .item(id: SampleLibrary.sherlock.id), .episode(itemID: SampleLibrary.podcast.id, episodeID: "ep_1"),
                ])
            #expect(members.map(\.summary.isMissing) == [true, false, false, false])
            #expect(GroupPresentation.membersHeaderKey(.playlist) == "HeaderPlaylistItems")
            #expect(GroupPresentation.membersHeaderKey(.collection) == "HeaderCollectionItems")
        }
    }

    @Test func cardsShowEachMembersOwnProgress() async throws {
        try await withStore { store, services in
            let model = PlaylistDetailModel(id: "pl_commute", service: services, cache: store.progress)
            await model.loadIfNeeded()
            store.progress.apply(finished(SampleLibrary.podcast.id, episodeID: "ep_1", false))
            store.progress.apply(finished(SampleLibrary.sherlock.id))
            let reader = BrowsePresentation.progressReader(store.progress)
            let progress = try #require(model.detail?.members).map {
                reader(itemID: $0.summary.itemID, episodeID: $0.summary.episodeID)
            }
            // The other episode of the same podcast has none of ep_1's progress.
            #expect(
                progress == [
                    nil, nil, ItemProgress(fraction: 1, isFinished: true), ItemProgress(fraction: 0.5),
                ])
        }
    }

    @Test func detailStatesFollowTheModel() async throws {
        let client = FakeGroupsClient()
        try await withStore(client) { store, services in
            let gone = CollectionDetailModel(id: "col_gone", service: services, cache: store.progress)
            #expect(GroupPresentation.state(of: gone, libraryID: "lib_a") == .loading)
            await gone.loadIfNeeded()
            #expect(GroupPresentation.state(of: gone, libraryID: "lib_a") == .notFound)
            #expect(GroupPresentation.detailMessages(.collection).notFound == "MessageCollectionDetailNotFound")

            let empty = CollectionDetailModel(id: "col_empty", service: services, cache: store.progress)
            await empty.loadIfNeeded()
            // The header still shows; the members say there are none.
            #expect(GroupPresentation.state(of: empty, libraryID: "lib_a") == .loaded(failed: false))
            #expect(empty.isEmpty)
            #expect(GroupPresentation.playAll(of: empty, canPlay: true) == nil)

            let playlist = PlaylistDetailModel(id: "pl_commute", service: services, cache: store.progress)
            client.fails.withLock { $0 = true }
            await playlist.loadIfNeeded()
            #expect(GroupPresentation.state(of: playlist, libraryID: "lib_a") == .failed)
            client.fails.withLock { $0 = false }
            await playlist.loadIfNeeded()
            client.fails.withLock { $0 = true }
            await playlist.load()
            #expect(GroupPresentation.state(of: playlist, libraryID: "lib_a") == .loaded(failed: true))
            #expect(playlist.detail?.name == "Commute")
        }
    }

    @Test func playAllPlaysTheFirstUnfinishedPlayableMember() async throws {
        try await withStore { store, services in
            let model = PlaylistDetailModel(id: "pl_commute", service: services, cache: store.progress)
            #expect(GroupPresentation.playAll(of: model, canPlay: true) == nil)
            await model.loadIfNeeded()

            // The missing book and the episode without audio are skipped.
            var playAll = try #require(GroupPresentation.playAll(of: model, canPlay: true))
            #expect(playAll.next?.target == GroupPlayTarget(itemID: SampleLibrary.sherlock.id))
            #expect(playAll.isEnabled)
            #expect(
                GroupPresentation.playAllAccessibilityLabel(playAll)
                    == "\(L10n.string("ButtonPlay")), \(sherlockTitle)")
            #expect(GroupPresentation.playAll(of: model, canPlay: false)?.isEnabled == false)

            store.progress.apply(finished(SampleLibrary.sherlock.id))
            playAll = try #require(GroupPresentation.playAll(of: model, canPlay: true))
            #expect(playAll.next?.target == GroupPlayTarget(itemID: SampleLibrary.podcast.id, episodeID: "ep_1"))
            let played = Mutex<[GroupPlayTarget]>([])
            let play = PlayItemAction { itemID, episodeID, startTime in
                #expect(startTime == nil)
                played.withLock { $0.append(GroupPlayTarget(itemID: itemID, episodeID: episodeID)) }
            }
            #expect(await GroupPresentation.performPlayAll(playAll, play: play) == nil)
            #expect(played.withLock { $0 } == [GroupPlayTarget(itemID: SampleLibrary.podcast.id, episodeID: "ep_1")])

            #expect(playAll.hintKey == nil)

            // Every playable member is finished: Play stays, disabled with a hint, as legacy's does nothing.
            store.progress.apply(finished(SampleLibrary.podcast.id, episodeID: "ep_1"))
            playAll = try #require(GroupPresentation.playAll(of: model, canPlay: true))
            #expect(playAll == GroupPlayAll(next: nil, isEnabled: false))
            #expect(playAll.hintKey == "MessageGroupAllFinished")
            #expect(GroupPresentation.playAllAccessibilityLabel(playAll) == L10n.string("ButtonPlay"))
            #expect(await GroupPresentation.performPlayAll(playAll, play: play) == nil)
            #expect(played.withLock { $0.count } == 1)
        }
    }

    @Test func groupWithNothingPlayableHasNoPlay() async throws {
        // Members, but only a missing book and an episode without audio.
        let unplayable = Playlist(
            id: "pl_unplayable", libraryId: "lib_a", name: "Unplayable",
            items: [commute.items[0], commute.items[1]])
        try await withStore(FakeGroupsClient(playlists: [unplayable])) { store, services in
            let model = PlaylistDetailModel(id: "pl_unplayable", service: services, cache: store.progress)
            await model.loadIfNeeded()
            #expect(model.detail?.members.count == 2)
            #expect(GroupPresentation.state(of: model, libraryID: "lib_a") == .loaded(failed: false))
            #expect(GroupPresentation.playAll(of: model, canPlay: true) == nil)
        }
    }

    @Test func anotherLibrarysGroupIsNotFound() async throws {
        // A deep link to a collection of another library than the scene's.
        let elsewhere = LibraryCollection(
            id: "col_elsewhere", libraryId: "lib_b", name: "Elsewhere", books: [SampleLibrary.emma])
        try await withStore(FakeGroupsClient(collections: [classics, elsewhere])) { store, services in
            let model = CollectionDetailModel(id: "col_elsewhere", service: services, cache: store.progress)
            await model.loadIfNeeded()
            #expect(GroupPresentation.state(of: model, libraryID: "lib_a") == .notFound)
            #expect(GroupPresentation.detail(of: model, libraryID: "lib_a") == nil)
            #expect(GroupPresentation.state(of: model, libraryID: "lib_b") == .loaded(failed: false))
            #expect(GroupPresentation.detail(of: model, libraryID: "lib_b")?.name == "Elsewhere")

            let classics = CollectionDetailModel(id: "col_classics", service: services, cache: store.progress)
            await classics.loadIfNeeded()
            #expect(GroupPresentation.detail(of: classics, libraryID: "lib_a")?.name == "Classics")
        }
    }

    @Test func screenKindsMatchTheirGroups() {
        #expect(CollectionGroupKind.summaryKind == .collection)
        #expect(PlaylistGroupKind.summaryKind == .playlist)
    }

    @Test func failedPlayAllReportsAndCancelledDoesNot() async throws {
        try await withStore { store, services in
            let model = CollectionDetailModel(id: "col_classics", service: services, cache: store.progress)
            await model.loadIfNeeded()
            let playAll = try #require(GroupPresentation.playAll(of: model, canPlay: true))
            #expect(playAll.next?.target.itemID == SampleLibrary.prideAndPrejudice.id)
            let failing = PlayItemAction { _, _, _ in throw Failure() }
            #expect(await GroupPresentation.performPlayAll(playAll, play: failing) == "MessagePlaybackStartFailed")
            let cancelled = PlayItemAction { _, _, _ in throw CancellationError() }
            #expect(await GroupPresentation.performPlayAll(playAll, play: cancelled) == nil)
        }
    }

    @Test func everyKeyIsInTheCatalog() {
        let kinds: [GroupSummary.Kind] = [.collection, .playlist]
        let keys =
            kinds.flatMap { kind -> [String] in
                let list = GroupPresentation.listMessages(kind)
                let detail = GroupPresentation.detailMessages(kind)
                return [
                    list.failed, list.empty, detail.failed, detail.empty, detail.notFound,
                    GroupPresentation.detailTitleKey(kind), GroupPresentation.membersHeaderKey(kind),
                    GroupPresentation.tab(kind).titleKey,
                ]
            } + ["LabelGroupOneItem", "LabelGroupItemCount", "ButtonPlay", "MessageGroupAllFinished"]
        for key in keys {
            #expect(L10n.string(key) != key, "\(key) isn't in the catalog")
        }
    }
}
