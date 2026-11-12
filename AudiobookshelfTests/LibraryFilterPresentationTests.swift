import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

private struct Failure: Error {}

/// A book library `lib_a` and a podcast library `lib_p` with three items each, recording item requests.
private actor RecordingLibraryClient: LibraryService {
    private(set) var requests: [(libraryID: String, query: LibraryQuery)] = []

    func libraries() async throws -> [Library] {
        [
            Library(id: "lib_a", name: "Books", mediaType: .book),
            Library(id: "lib_p", name: "Podcasts", mediaType: .podcast),
        ]
    }

    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }

    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
        requests.append((libraryID, query))
        let items = (0..<3).map {
            ABSCore.LibraryItem(
                id: "\(libraryID)_\($0)", libraryId: libraryID, mediaType: .book, media: SampleLibrary.emma.media)
        }
        return PagedResults(results: items, total: items.count, limit: query.limit ?? 0, page: query.page ?? 0)
    }
}

private let account = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(), userID: "user-1")
private let english = Locale(identifier: "en_US")

/// A store connected to `client` with settings in a throwaway defaults suite, so a test never touches the app's.
@MainActor
private func withStore(
    _ client: RecordingLibraryClient, _ body: (LibraryStore) async throws -> Void
) async throws {
    let suiteName = "LibraryFilterPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = LibraryStore(settings: AppSettings(defaults: defaults))
    await store.connect(client: client, connectionKey: account)
    try await body(store)
}

/// The model `LibraryFilterView`'s task builds for the route in `libraryID`.
@MainActor
private func routeModel(
    _ store: LibraryStore, _ libraryID: String, kind: LibraryFilterKind, value: String
) throws -> LibraryItemsModel {
    let key = LibraryFilterPresentation.modelKey(store: store, libraryID: libraryID, kind: kind, value: value)
    let host = LibraryPresentation.updated(
        nil, for: key, mediaType: store.mediaType(libraryID: libraryID), store: store,
        pinnedFilter: LibraryFilterPresentation.filter(kind: kind, value: value))
    return try #require(host).model
}

@MainActor
@Suite struct LibraryFilterPresentationTests {
    @Test func titleForEachKind() {
        let titles: [LibraryFilterKind: String] = [
            .narrators: "Narrator: Stephen Fry", .tags: "Tag: Stephen Fry", .genres: "Genre: Stephen Fry",
        ]
        // A new kind needs a title here.
        #expect(Set(titles.keys) == Set(LibraryFilterKind.allCases))
        for kind in LibraryFilterKind.allCases {
            #expect(LibraryFilterPresentation.title(kind: kind, value: "Stephen Fry", locale: english) == titles[kind])
            let label = LibraryFilterPresentation.labelKey(for: kind)
            #expect(L10n.string(label) != label, "\(label) isn't in the catalog")
            // The pinned filter is the kind's server group.
            #expect(LibraryFilterPresentation.filter(kind: kind, value: "x").group.rawValue == kind.rawValue)
        }
        #expect(L10n.string("HeaderLibraryFilterRoute") != "HeaderLibraryFilterRoute")
    }

    @Test func routeQueriesItsFilterAndSavesSortButNeverTheFilter() async throws {
        let client = RecordingLibraryClient()
        try await withStore(client) { store in
            let saved = LibraryViewPreferences.Filter(group: .genres, value: "Romance")
            store.saveViewPreferences(
                LibraryViewPreferences(filter: saved), libraryID: "lib_a", connectionKey: account)
            let model = try routeModel(store, "lib_a", kind: .narrators, value: "Stephen Fry")
            #expect(!model.isFilterUnsupported)
            await model.load()?.value
            #expect(await client.requests.last?.query.filter == LibraryFilter(group: "narrators", value: "Stephen Fry"))
            #expect(model.items.count == 3)
            #expect(LibraryFilterPresentation.messages(for: model).empty == "MessageNoItemsFound")

            await model.update { $0.selectSort(.title) }?.value
            #expect(await client.requests.last?.query.filter == LibraryFilter(group: "narrators", value: "Stephen Fry"))
            let stored = try #require(store.viewPreferences(libraryID: "lib_a"))
            #expect(stored.sort == .title)
            #expect(stored.filter == saved)

            // The Library tab's own model still has its saved filter.
            let tabKey = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            let tab = try #require(LibraryPresentation.updated(nil, for: tabKey, mediaType: .book, store: store))
            #expect(tab.model.preferences.filter == saved)
            #expect(tab.model.pinnedFilter == nil)
        }
    }

    /// Negative control: without the pin's unsupported check, the podcast library would be listed unfiltered.
    @Test func narratorRouteInAPodcastLibraryIsUnsupportedNotTheWholeLibrary() async throws {
        let client = RecordingLibraryClient()
        try await withStore(client) { store in
            let model = try routeModel(store, "lib_p", kind: .narrators, value: "Stephen Fry")
            #expect(model.isFilterUnsupported)
            await model.load()?.value
            #expect(await client.requests.isEmpty)
            #expect(model.items.isEmpty)
            #expect(LibraryPresentation.state(of: model) == .empty)
            #expect(LibraryFilterPresentation.messages(for: model).empty == "MessageNoItemsFound")

            // Podcasts do filter by tag.
            let tags = try routeModel(store, "lib_p", kind: .tags, value: "Comedy")
            #expect(!tags.isFilterUnsupported)
            await tags.load()?.value
            #expect(await client.requests.last?.query.filter == LibraryFilter(group: "tags", value: "Comedy"))
            #expect(LibraryFilterPresentation.messages(for: tags).empty == "MessageNoPodcastsFound")
        }
    }

    /// The Library tab's model and a route's model for the same library and account, built as the screens build
    /// them, take each other's sort and view changes and never wipe each other's fields; the route never saves its pin.
    @Test func theTabAndARouteShareSortAndViewButNotTheFilter() async throws {
        let client = RecordingLibraryClient()
        try await withStore(client) { store in
            let saved = LibraryViewPreferences.Filter(group: .genres, value: "Romance")
            store.saveViewPreferences(LibraryViewPreferences(filter: saved), libraryID: "lib_a", connectionKey: account)
            let tabKey = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            let tab = try #require(LibraryPresentation.updated(nil, for: tabKey, mediaType: .book, store: store)).model
            let route = try routeModel(store, "lib_a", kind: .narrators, value: "Stephen Fry")
            let pin = LibraryFilterPresentation.filter(kind: .narrators, value: "Stephen Fry")
            await tab.load()?.value
            await route.load()?.value

            // A sort chosen on the route reloads the tab with it and the tab's saved filter.
            await route.update { $0.selectSort(.title) }?.value
            #expect(tab.preferences == LibraryViewPreferences(sort: .title, descending: false, filter: saved))
            #expect(tab.list.query.query.sort == LibrarySortKey.title.rawValue)
            #expect(tab.list.query.query.filter == LibraryFilter(group: "genres", value: "Romance"))

            // The tab's view mode shows on the route, which keeps its pin and the sort it chose.
            #expect(tab.update { $0.viewMode = .list } == nil)
            #expect(
                route.preferences
                    == LibraryViewPreferences(sort: .title, descending: false, filter: pin, viewMode: .list))
            #expect(
                store.viewPreferences(libraryID: "lib_a")
                    == LibraryViewPreferences(sort: .title, descending: false, filter: saved, viewMode: .list))

            // The tab's filter is saved and taken by neither the route's query nor its pin.
            await tab.update { $0.filter = nil }?.value
            #expect(route.preferences.filter == pin)
            #expect(store.viewPreferences(libraryID: "lib_a")?.filter == nil)

            // Another library is untouched.
            #expect(store.viewPreferences(libraryID: "lib_p") == nil)
        }
    }

    @Test func eachRouteHasItsOwnModelAndPlacement() async throws {
        try await withStore(RecordingLibraryClient()) { store in
            let fry = LibraryFilterPresentation.modelKey(
                store: store, libraryID: "lib_a", kind: .narrators, value: "Stephen Fry")
            let other = LibraryFilterPresentation.modelKey(
                store: store, libraryID: "lib_a", kind: .tags, value: "Stephen Fry")
            #expect(fry != nil && fry != other)
            #expect(fry != BrowseModelKey(store: store, libraryID: "lib_a"))
        }
        // A saved scene's legacy narrator route opens this screen too, and owns ⌘R while on top.
        #expect(
            LibraryFilterPresentation.placement(
                kind: .narrators, value: "Stephen Fry", topRoute: .narrator(name: "Stephen Fry"))
                == .pushed(.narrator(name: "Stephen Fry")))
        #expect(
            LibraryFilterPresentation.placement(kind: .narrators, value: "Stephen Fry", topRoute: nil)
                == .pushed(.libraryFilter(kind: .narrators, value: "Stephen Fry")))
        #expect(
            LibraryFilterPresentation.placement(kind: .tags, value: "A", topRoute: .narrator(name: "A"))
                == .pushed(.libraryFilter(kind: .tags, value: "A")))
    }
}
