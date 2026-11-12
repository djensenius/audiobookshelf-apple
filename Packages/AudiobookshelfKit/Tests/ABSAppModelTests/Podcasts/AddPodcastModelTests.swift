import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A directory search a ``FakeAddPodcastService`` received.
struct DirectorySearch: Sendable, Equatable {
    let term: String
    let country: String?
}

/// An ``AddPodcastService`` whose searches and feed lookups wait for the test to answer them, and whose creates
/// return `createdID` or throw `createError`.
struct FakeAddPodcastService: AddPodcastService {
    let searches = GatedCalls<DirectorySearch, [PodcastDirectoryResult]>()
    let feeds = GatedCalls<String, PodcastFeed>()
    let creates = GatedCalls<NewPodcastRequest, LibraryItem>()

    func searchPodcastDirectory(term: String, country: String?) async throws -> [PodcastDirectoryResult] {
        try await searches.call(DirectorySearch(term: term, country: country))
    }

    func podcastFeed(rssFeed: String) async throws -> PodcastFeed {
        try await feeds.call(rssFeed)
    }

    func createPodcast(_ request: NewPodcastRequest) async throws -> LibraryItem {
        try await creates.call(request)
    }
}

func directoryResult(_ title: String, feedURL: String? = "https://feeds.example.com/show.xml")
    -> PodcastDirectoryResult
{
    PodcastDirectoryResult(
        itunesID: "1", itunesArtistID: "2", title: title, artistName: "Artist", description: "<p>Directory</p>",
        releaseDate: "2026-01-01", genres: ["Fiction"], cover: "https://images.example.com/c.jpg", trackCount: 3,
        feedURL: feedURL, pageURL: "https://podcasts.example.com/id1", explicit: true)
}

func podcastFeed(_ title: String = "Feed Title", feedURL: String? = "https://feeds.example.com/new.xml") -> PodcastFeed
{
    PodcastFeed(
        metadata: PodcastFeedMetadata(
            title: title, author: "Feed Author", description: "<p>Feed</p>", descriptionPlain: "Feed",
            image: "https://feeds.example.com/i.jpg", categories: ["Arts"], feedURL: feedURL, language: "en",
            explicit: "no", type: "serial"),
        episodes: [PodcastFeedEpisode(title: "One")], numEpisodes: 1)
}

let podcastFolders = [
    LibraryFolder(id: "f1", fullPath: "/podcasts/"), LibraryFolder(id: "f2", fullPath: "/mnt/more"),
]

@MainActor
@Suite struct AddPodcastModelTests {
    let service = FakeAddPodcastService()

    func makeModel(region: String? = "ca") -> AddPodcastModel {
        let library = Library(
            id: "lib", name: "Podcasts", folders: podcastFolders, mediaType: .podcast,
            settings: LibrarySettings(podcastSearchRegion: region))
        return AddPodcastModel(service: service, library: library)
    }

    @Test func submitSearchesTheTrimmedTermInTheLibrarysRegion() async throws {
        let model = makeModel()
        var calls = service.searches.calls.makeAsyncIterator()

        model.query = "  mystery  "
        model.submit()
        #expect(model.isSearching)
        let call = try #require(await calls.next())
        #expect(call.request == DirectorySearch(term: "mystery", country: "ca"))
        call.reply.resume(returning: [directoryResult("A"), directoryResult("B")])
        await model.task?.value

        #expect(!model.isSearching)
        #expect(model.results.map(\.title) == ["A", "B"])
        #expect(model.searchedTerm == "mystery")
        #expect(model.folders == podcastFolders && model.libraryID == "lib")
    }

    @Test func aBlankQueryDoesNothing() {
        let model = makeModel()
        model.query = "   "
        model.submit()
        #expect(model.task == nil && !model.isSearching && model.searchedTerm == nil)
    }

    @Test func aStaleSearchResponseIsDropped() async throws {
        let model = makeModel()
        var calls = service.searches.calls.makeAsyncIterator()

        model.query = "old"
        model.submit()
        let stale = try #require(model.task)
        let staleCall = try #require(await calls.next())
        model.query = "new"
        model.submit()
        #expect(stale.isCancelled)
        let freshCall = try #require(await calls.next())

        // The old request answers first; its results must not show, and the new search is still running.
        staleCall.reply.resume(returning: [directoryResult("Old")])
        await stale.value
        #expect(model.results.isEmpty && model.searchedTerm == nil)
        #expect(model.isSearching)

        freshCall.reply.resume(returning: [directoryResult("New")])
        await model.task?.value
        #expect(model.results.map(\.title) == ["New"])
        #expect(model.searchedTerm == "new" && !model.isSearching)
    }

    @Test func aLateStaleFailureDoesNotReplaceNewerResults() async throws {
        let model = makeModel()
        var calls = service.searches.calls.makeAsyncIterator()

        model.query = "old"
        model.submit()
        let stale = try #require(model.task)
        let staleCall = try #require(await calls.next())
        model.query = "new"
        model.submit()
        let freshCall = try #require(await calls.next())
        freshCall.reply.resume(returning: [directoryResult("New")])
        await model.task?.value
        staleCall.reply.resume(throwing: TestError.offline)
        await stale.value

        #expect(model.results.map(\.title) == ["New"])
        #expect(model.searchError == nil)
    }

    @Test func aFailedSearchClearsTheResults() async throws {
        let model = makeModel(region: nil)
        var calls = service.searches.calls.makeAsyncIterator()
        model.query = "first"
        model.submit()
        let first = try #require(await calls.next())
        #expect(first.request.country == nil)
        first.reply.resume(returning: [directoryResult("A")])
        await model.task?.value

        model.query = "second"
        model.submit()
        try #require(await calls.next()).reply.resume(throwing: TestError.offline)
        await model.task?.value
        #expect(model.results.isEmpty && model.searchedTerm == nil)
        #expect(model.searchError is TestError && !model.isSearching)
    }

    @Test func aFeedURLIsLookedUpAndOpensTheForm() async throws {
        let model = makeModel()
        var searches = service.searches.calls.makeAsyncIterator()
        var feeds = service.feeds.calls.makeAsyncIterator()
        model.query = "news"
        model.submit()
        try #require(await searches.next()).reply.resume(returning: [directoryResult("A")])
        await model.task?.value

        model.query = " HTTPS://feeds.example.com/pasted.xml "
        model.submit()
        // A lookup replaces the search's results, as in legacy.
        #expect(model.results.isEmpty && model.searchedTerm == nil)
        #expect(model.isLookingUpFeed && !model.isSearching)
        let call = try #require(await feeds.next())
        #expect(call.request == "HTTPS://feeds.example.com/pasted.xml")
        call.reply.resume(returning: podcastFeed(feedURL: nil))
        await model.task?.value

        #expect(!model.isLookingUpFeed && model.lookupError == nil)
        let draft = try #require(model.draft)
        #expect(draft.title == "Feed Title" && draft.feedURL == "HTTPS://feeds.example.com/pasted.xml")
        #expect(draft.libraryID == "lib" && draft.folders == podcastFolders)
    }

    @Test func selectingAResultLooksUpItsFeed() async throws {
        let model = makeModel()
        var feeds = service.feeds.calls.makeAsyncIterator()
        model.select(directoryResult("Directory Title"))
        let call = try #require(await feeds.next())
        #expect(call.request == "https://feeds.example.com/show.xml")
        call.reply.resume(returning: podcastFeed())
        await model.task?.value
        #expect(model.draft?.title == "Directory Title")
    }

    @Test(arguments: [nil, "", "  "])
    func aResultWithoutAFeedCantBeSelected(feedURL: String?) {
        let model = makeModel()
        model.select(directoryResult("A", feedURL: feedURL))
        #expect(model.lookupError == .noFeed)
        #expect(model.task == nil && model.draft == nil && !model.isLookingUpFeed)
        model.clearLookupError()
        #expect(model.lookupError == nil)
    }

    @Test func aFailedLookupSaysSo() async throws {
        let model = makeModel()
        var feeds = service.feeds.calls.makeAsyncIterator()
        model.select(directoryResult("A"))
        try #require(await feeds.next()).reply.resume(throwing: APIError.notFound)
        await model.task?.value
        #expect(model.lookupError == .feedFailed && model.draft == nil && !model.isLookingUpFeed)
    }

    @Test func aStaleLookupDoesNotOpenTheForm() async throws {
        let model = makeModel()
        var feeds = service.feeds.calls.makeAsyncIterator()
        var searches = service.searches.calls.makeAsyncIterator()

        model.select(directoryResult("A"))
        let stale = try #require(model.task)
        let staleCall = try #require(await feeds.next())
        model.query = "other"
        model.submit()
        #expect(stale.isCancelled && !model.isLookingUpFeed && model.isSearching)
        staleCall.reply.resume(returning: podcastFeed())
        await stale.value
        #expect(model.draft == nil)

        try #require(await searches.next()).reply.resume(returning: [])
        await model.task?.value
        #expect(model.draft == nil && model.searchedTerm == "other" && model.results.isEmpty)
    }

    @Test(arguments: [
        ("http://a", true), ("https://a", true), ("HTTP:x", true), ("httpx", false), ("feeds.example.com", false),
        ("ftp://a", false),
    ])
    // Unlike legacy's case-sensitive `startsWith`, "HTTP:" counts too, so a pasted upper-case URL isn't searched for.
    func feedURLsAreDetectedCaseInsensitively(text: String, isFeed: Bool) {
        #expect(AddPodcastModel.isFeedURL(text) == isFeed)
    }

    @Test(arguments: [
        (UserType.root, false, true), (.admin, false, true), (.user, true, false), (.user, false, false),
        (.guest, true, false), (.unknown("owner"), true, false),
    ])
    func onlyAdminsMayAddPodcasts(type: UserType, upload: Bool, allowed: Bool) {
        let user = User(id: "u", username: "u", type: type, permissions: UserPermissions(upload: upload))
        #expect(user.canAddPodcasts == allowed)
    }

    @Test func onlyAnAdminOnAPodcastLibraryIsReady() {
        let admin = User(id: "u", username: "u", type: .admin)
        let podcasts = Library(id: "lib", name: "P", mediaType: .podcast)
        let books = Library(id: "books", name: "B", mediaType: .book)
        let connection = UUID()
        func resolve(_ user: User?, _ library: Library?, store: UUID? = connection) -> AddPodcastAccess {
            .resolve(user: user, connectionID: connection, storeConnectionID: store, library: library)
        }
        let key = AddPodcastAccess.Key(connectionID: connection, userID: "u", libraryID: "lib")
        #expect(resolve(admin, podcasts) == .ready(key))
        #expect(resolve(admin, books) == .notPodcastLibrary)
        #expect(resolve(User(id: "u", username: "u", type: .user), podcasts) == .notAllowed)
        #expect(resolve(nil, podcasts) == .waiting && resolve(admin, nil) == .waiting)
        #expect(resolve(admin, podcasts, store: UUID()) == .waiting)
    }

    @Test func aCreateIsOpenedOnlyForTheSameAccountAndLibrary() {
        let key = AddPodcastAccess.Key(connectionID: UUID(), userID: "u", libraryID: "lib")
        #expect(AddPodcastAccess.ready(key).canOpen(createdFor: key))
        let otherLibrary = AddPodcastAccess.Key(connectionID: key.connectionID, userID: "u", libraryID: "other")
        let otherServer = AddPodcastAccess.Key(connectionID: UUID(), userID: "u", libraryID: "lib")
        for access in [AddPodcastAccess.ready(otherLibrary), .ready(otherServer), .waiting, .notAllowed] {
            #expect(!access.canOpen(createdFor: key))
        }
    }

    @Test func aLibraryRefreshUpdatesFoldersAndRegion() async throws {
        let model = makeModel()
        var calls = service.searches.calls.makeAsyncIterator()
        let folders = [LibraryFolder(id: "f3", fullPath: "/new")]
        model.update(library: Library(id: "other", name: "X", folders: [], mediaType: .podcast))
        #expect(model.folders == podcastFolders)
        let settings = LibrarySettings(podcastSearchRegion: "gb")
        model.update(library: Library(id: "lib", name: "P", folders: folders, mediaType: .podcast, settings: settings))
        #expect(model.folders == folders)
        model.query = "q"
        model.submit()
        let call = try #require(await calls.next())
        #expect(call.request.country == "gb")
        call.reply.resume(returning: [])
    }
}
