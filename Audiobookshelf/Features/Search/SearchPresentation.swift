import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What Search shows, decided from the environment and its ``SearchModel`` without SwiftUI.
enum SearchScreenState: Equatable {
    /// No library data: nobody is signed in, or the account's client can't search.
    case signedOut
    /// Signed in, but no library is selected yet.
    case noLibrary
    /// The model for the current account and library is about to be created.
    case loading
    /// Nothing typed, or typed text still waiting for the debounce before any search: the recent
    /// searches, or a prompt when there are none.
    case idle
    /// A search is running, with nothing to show.
    case searching
    /// The last search finished without results. Also kept while newer text waits for the
    /// debounce, so the screen doesn't flash.
    case noResults
    /// The search failed with nothing to show; Retry searches again.
    case failed
    /// The sections; `isSearching` while a newer search runs, `failed` when the last one failed
    /// and older results are shown.
    case results(isSearching: Bool, failed: Bool)

    /// What ``resolve(_:)`` decides from.
    struct Inputs: Equatable {
        /// The text as typed.
        var query = ""
        /// The trimmed query the results belong to.
        var searchedQuery: String?
        var isSearching = false
        var hasError = false
        var hasResults = false
    }

    static func resolve(_ inputs: Inputs) -> SearchScreenState {
        let term = inputs.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .idle }
        if inputs.hasResults { return .results(isSearching: inputs.isSearching, failed: inputs.hasError) }
        if inputs.isSearching { return .searching }
        if inputs.hasError { return .failed }
        // Until a request starts, keep what the last search showed.
        return inputs.searchedQuery == nil ? .idle : .noResults
    }

    /// The state of `model`.
    @MainActor
    static func resolve(_ model: SearchModel) -> SearchScreenState {
        resolve(
            Inputs(
                query: model.query, searchedQuery: model.searchedQuery, isSearching: model.isSearching,
                hasError: model.error != nil, hasResults: !model.results.isEmpty))
    }

    /// The state before a model exists: signed out without an account that can search, no
    /// library before the router selects one, else loading.
    static func placeholder(canSearch: Bool, libraryID: String?) -> SearchScreenState {
        guard canSearch else { return .signedOut }
        return libraryID == nil ? .noLibrary : .loading
    }
}

/// How Search presents its sections and rows (legacy `pages/search.vue` and its search cards).
enum SearchPresentation {
    /// The key of a section's header, the legacy page's.
    static func titleKey(of kind: SearchSectionKind) -> String {
        switch kind {
        case .books: "LabelBooks"
        case .podcasts: "LabelPodcasts"
        case .episodes: "HeaderEpisodes"
        case .series: "LabelSeries"
        case .authors: "LabelAuthors"
        case .narrators: "LabelNarrators"
        case .tags: "LabelTags"
        }
    }

    /// The key of the singular name of a section's rows, which VoiceOver speaks after the row.
    static func kindKey(of kind: SearchSectionKind) -> String {
        switch kind {
        case .books: "LabelSearchResultBook"
        case .podcasts: "LabelPodcast"
        case .episodes: "LabelEpisode"
        case .series: "LabelSeries"
        case .authors: "LabelAuthor"
        case .narrators: "LabelNarrator"
        case .tags: "LabelTag"
        }
    }

    /// The SF Symbol of a narrator or tag row, after the legacy cards' icons.
    static func systemImage(of kind: SearchSectionKind) -> String {
        switch kind {
        case .narrators: "person.wave.2"
        case .tags: "tag"
        case .books, .podcasts, .episodes, .series, .authors: "magnifyingglass"
        }
    }

    static func title(of row: SearchResultRow) -> String {
        switch row.content {
        case .item(let item): item.title
        case .series(let series): series.name
        case .author(let author): author.name
        case .name(let name, _): name
        }
    }

    /// The second line: an item's author or podcast, a series' or author's book count. Narrators
    /// and tags show only their name, like the legacy cards.
    static func subtitle(of row: SearchResultRow, locale: Locale? = nil) -> String? {
        switch row.content {
        case .item(let item): item.subtitle
        case .series(let series): bookCount(series.bookCount, locale: locale)
        case .author(let author): author.bookCount.flatMap { $0 > 0 ? bookCount($0, locale: locale) : nil }
        case .name: nil
        }
    }

    /// Title, subtitle and kind, as one VoiceOver label: "Emma, Jane Austen, Book".
    static func accessibilityLabel(of row: SearchResultRow, in kind: SearchSectionKind, locale: Locale? = nil)
        -> String
    {
        [title(of: row), subtitle(of: row, locale: locale), L10n.string(kindKey(of: kind), locale: locale)]
            .compactMap(\.self).joined(separator: ", ")
    }

    /// Pushes `route` on the Search tab's stack, the stack this screen is the root of, unless it
    /// is already on top (a double tap).
    @MainActor
    static func open(_ route: Route, in router: Router?) {
        guard let router, router[path: .search].last != route else { return }
        router[path: .search].append(route)
    }

    /// "1 book" or "3 books".
    static func bookCount(_ count: Int, locale: Locale? = nil) -> String {
        L10n.plural("SharedBookCount", count: count, locale: locale)
    }
}

/// The recent searches of each account and library, stored by `AppSettings` as JSON arrays of
/// strings. ``SearchModel`` saves them through ``persist(connectionKey:libraryID:)``.
@MainActor
struct SearchRecentsStore {
    let settings: AppSettings

    func recentSearches(connectionKey: LibraryConnectionKey, libraryID: String) -> [String] {
        guard
            let json = settings.recentSearchesJSON(
                serverID: connectionKey.serverID, userID: connectionKey.userID, libraryID: libraryID),
            let recents = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else { return [] }
        return recents
    }

    /// Saves `recentSearches`; an empty list removes the library's entry.
    func setRecentSearches(_ recentSearches: [String], connectionKey: LibraryConnectionKey, libraryID: String) {
        let json =
            recentSearches.isEmpty
            ? nil : (try? JSONEncoder().encode(recentSearches)).map { String(decoding: $0, as: UTF8.self) }
        settings.setRecentSearchesJSON(
            json, serverID: connectionKey.serverID, userID: connectionKey.userID, libraryID: libraryID)
    }

    /// The closure a library's ``SearchModel`` reads its recent searches with. Reads the
    /// observable settings, so views showing them update when they change.
    func load(connectionKey: LibraryConnectionKey, libraryID: String) -> SearchModel.LoadRecents {
        { recentSearches(connectionKey: connectionKey, libraryID: libraryID) }
    }

    /// The closure a library's ``SearchModel`` saves its recent searches with.
    func persist(connectionKey: LibraryConnectionKey, libraryID: String) -> SearchModel.PersistRecents {
        { recentSearches in
            setRecentSearches(recentSearches, connectionKey: connectionKey, libraryID: libraryID)
        }
    }
}
