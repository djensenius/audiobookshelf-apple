import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import SwiftUI

/// The bookshelf of one library: its items as cards or rows, a page at a time.
typealias LibraryItemsModel = LibraryBrowseModel<ItemSummary>

/// The Library screen's model with the key it was built for.
typealias LibraryModelHost = BrowseModelHost<LibraryItemsModel>

/// What the Library screen decides, kept out of the views so app tests cover it.
enum LibraryPresentation {
    /// The messages of a library of `mediaType`; a podcast library says it has no podcasts.
    static func messages(for mediaType: MediaType?) -> BrowseMessages {
        BrowseMessages(
            failed: "MessageLibraryItemsLoadFailed",
            empty: mediaType == .podcast ? "MessageNoPodcastsFound" : "MessageNoItemsFound",
            systemImage: "books.vertical")
    }

    /// The bookshelf of the key's library and account, of type `mediaType`, with the account's saved preferences for
    /// it. A preference the user changes is saved for the account the model was built for, never another one.
    /// `pinnedFilter` (a filter route's) is shown and queried instead of the saved filter, and never saved.
    @MainActor
    static func makeModel(
        key: BrowseModelKey, mediaType: MediaType, services: LibraryStoreServices, store: LibraryStore,
        pinnedFilter: LibraryViewPreferences.Filter? = nil
    ) -> LibraryItemsModel {
        let connection = key.connection
        return LibraryItemsModel(
            client: services, libraryID: key.libraryID, mediaType: mediaType,
            stored: store.viewPreferences(libraryID: key.libraryID), pinnedFilter: pinnedFilter,
            connectionKey: connection,
            persist: { [weak store] libraryID, preferences in
                store?.saveViewPreferences(preferences, libraryID: libraryID, connectionKey: connection)
            },
            map: { ItemSummary(item: $0) })
    }

    /// The host the screen's task keeps: `host` when built for `key` and `mediaType` (keeping what it loaded), else a
    /// new one. Until the library's type is known (its list hasn't loaded) there is no new model, as the type decides
    /// the sorts, filters and query; `host` stays only if it was built for `key`.
    @MainActor
    static func updated(
        _ host: LibraryModelHost?, for key: BrowseModelKey?, mediaType: MediaType?, store: LibraryStore?,
        pinnedFilter: LibraryViewPreferences.Filter? = nil
    ) -> LibraryModelHost? {
        guard let key, let store else { return nil }
        guard let mediaType else { return host?.key == key ? host : nil }
        if let host, host.key == key, host.model.mediaType == mediaType, host.model.pinnedFilter == pinnedFilter {
            return host
        }
        return LibraryModelHost(key: key, store: store) { services in
            makeModel(key: key, mediaType: mediaType, services: services, store: store, pinnedFilter: pinnedFilter)
        }
    }

    /// The screen's state for its model.
    @MainActor
    static func state(of model: LibraryItemsModel) -> BrowseScreenState {
        .resolve(list: model.list)
    }

    /// The item count in the title area ("12 books", "1 book"; "7 Podcasts" as the legacy toolbar writes it, with
    /// the translated label after the number); `nil` until a page told the total.
    static func countText(total: Int?, mediaType: MediaType, locale: Locale? = nil) -> String? {
        guard let total else { return nil }
        let number = total.formatted(.number.locale(locale ?? .current))
        if mediaType == .podcast {
            return "\(number) \(L10n.string(total == 1 ? "LabelPodcast" : "LabelPodcasts", locale: locale))"
        }
        return total == 1
            ? L10n.string("LabelSearchOneBook", locale: locale) : L10n.string("SharedBookCount", number, locale: locale)
    }

    /// How a list of `columns` columns pages: enough per page to fill a few rows, and the next page asked for two
    /// rows before the end, so a wide grid (12–16 columns on a Mac) neither waits at its last row nor needs
    /// several requests to fill the screen. One column keeps the defaults (20, prefetching 5 from the end).
    static func paging(columns: Int) -> LibraryPaging {
        let columns = max(1, columns)
        return LibraryPaging(pageSize: max(20, 4 * columns), prefetchThreshold: max(5, 2 * columns))
    }

    /// The paging for a screen `width` points wide (`nil` before it was measured) in `viewMode`: the grid's columns
    /// as ``ItemGrid`` fits them, or one column for the list.
    static func paging(width: CGFloat?, dynamicTypeSize: DynamicTypeSize, viewMode: LibraryViewMode) -> LibraryPaging {
        guard let width, viewMode == .grid else { return paging(columns: 1) }
        return paging(columns: ItemGridMetrics.columnCount(width: width, dynamicTypeSize: dynamicTypeSize))
    }
}

/// The page size and prefetch threshold of the Library screen's list.
struct LibraryPaging: Hashable {
    let pageSize: Int
    let prefetchThreshold: Int

    /// Applies to `model`'s list: the threshold now, the page size now or from its next first page.
    @MainActor
    func apply(to model: LibraryItemsModel) {
        model.list.setPaging(pageSize: pageSize, prefetchThreshold: prefetchThreshold)
    }
}

// MARK: - Sort, filter and view controls

/// A sort in the Library screen's sort menu.
struct LibrarySortOption: Hashable, Identifiable {
    let key: LibrarySortKey
    let titleKey: String
    /// The library is sorted by this key.
    let isSelected: Bool
    /// The direction arrow the selected key shows; `nil` for the others.
    let arrowSymbol: String?

    var id: LibrarySortKey { key }
}

/// A value of a filter group in the filter sheet: `id` is the filter value, `name` is shown.
struct LibraryFilterValue: Hashable, Identifiable {
    let id: String
    let name: String
}

extension LibraryPresentation {
    /// The sort menu of a library of `mediaType` (legacy `OrderModal.vue`), the selected key with its direction.
    static func sortOptions(for mediaType: MediaType, preferences: LibraryViewPreferences) -> [LibrarySortOption] {
        LibrarySortKey.keys(for: mediaType).map { key in
            let isSelected = key == preferences.sort
            return LibrarySortOption(
                key: key, titleKey: titleKey(for: key), isSelected: isSelected,
                arrowSymbol: isSelected ? arrowSymbol(descending: preferences.descending) : nil)
        }
    }

    static func arrowSymbol(descending: Bool) -> String {
        descending ? "arrow.down" : "arrow.up"
    }

    /// The legacy label of a sort (`OrderModal.vue`).
    static func titleKey(for sort: LibrarySortKey) -> String {
        switch sort {
        case .title: "LabelTitle"
        case .authorFirstLast: "LabelAuthorFirstLast"
        case .authorLastFirst: "LabelAuthorLastFirst"
        case .publishedYear: "LabelPublishYear"
        case .addedAt: "LabelAddedAt"
        case .size: "LabelSize"
        case .duration: "LabelDuration"
        case .fileCreated: "LabelFileBirthtime"
        case .fileModified: "LabelFileModified"
        case .progress: "LabelLibrarySortByProgress"
        case .progressStarted: "LabelLibrarySortByProgressStarted"
        case .progressFinished: "LabelLibrarySortByProgressFinished"
        case .random: "LabelRandomly"
        case .podcastAuthor: "LabelAuthor"
        case .episodeCount: "LabelNumberOfEpisodes"
        }
    }

    static func directionKey(descending: Bool) -> String {
        descending ? "LabelLibrarySortDescending" : "LabelLibrarySortAscending"
    }

    /// The legacy label of a filter group (`FilterModal.vue`).
    static func titleKey(for group: LibraryFilterGroup) -> String {
        switch group {
        case .genres: "LabelGenre"
        case .tags: "LabelTag"
        case .series: "LabelSeries"
        case .authors: "LabelAuthor"
        case .narrators: "LabelNarrator"
        case .languages: "LabelLanguage"
        case .progress: "LabelProgress"
        case .ebooks: "LabelEbooks"
        case .issues: "ButtonIssues"
        case .feedOpen: "LabelRSSFeedOpen"
        case .explicit: "LabelExplicit"
        }
    }

    static func titleKey(for progress: LibraryFilterModel.ProgressState) -> String {
        switch progress {
        case .finished: "LabelFinished"
        case .inProgress: "LabelInProgress"
        case .notStarted: "LabelNotStarted"
        case .notFinished: "LabelNotFinished"
        }
    }

    static func titleKey(for ebook: LibraryFilterModel.EbookKind) -> String {
        switch ebook {
        case .ebook: "LabelHasEbook"
        case .supplementary: "LabelHasSupplementaryEbook"
        }
    }

    static let viewModes: [LibraryViewMode] = [.grid, .list]

    static func titleKey(for viewMode: LibraryViewMode) -> String {
        viewMode == .grid ? "LabelLibraryGrid" : "LabelLibraryList"
    }

    static func symbol(for viewMode: LibraryViewMode) -> String {
        viewMode == .grid ? "square.grid.2x2" : "list.bullet"
    }

    /// Collapse series is offered for book libraries only (an unknown type counts as books, as the preferences do).
    static func showsCollapseSeries(for mediaType: MediaType) -> Bool {
        mediaType != .podcast
    }

    /// Collapse Series is off while filtering by series, where the server ignores it.
    static func isCollapseSeriesDisabled(_ preferences: LibraryViewPreferences) -> Bool {
        preferences.filter?.group == .series
    }

    /// Whether the screen loads the filter choices before the sheet opens: the filter in use is an author or series
    /// (other than "No series"), whose name only the choices have, so VoiceOver can read it.
    static func loadsFilterChoicesEarly(for filter: LibraryViewPreferences.Filter?) -> Bool {
        guard let filter, let value = filter.value else { return false }
        switch filter.group {
        case .authors: return true
        case .series: return value != LibraryFilterModel.Choice.noSeries.id
        default: return false
        }
    }

    /// The values `group` offers, localized for progress and ebooks, with "No series" first in series; `nil` while the
    /// library's filter data is needed and not loaded. Groups that take no value have none.
    static func filterValues(
        for group: LibraryFilterGroup, choices: LibraryFilterModel.Choices?, locale: Locale? = nil
    ) -> [LibraryFilterValue]? {
        func named(_ list: [LibraryFilterModel.Choice]) -> [LibraryFilterValue] {
            list.map {
                LibraryFilterValue(
                    id: $0.id, name: $0 == .noSeries ? L10n.string("MessageNoSeries", locale: locale) : $0.name)
            }
        }
        switch group {
        case .progress:
            return LibraryFilterModel.ProgressState.allCases.map {
                LibraryFilterValue(id: $0.rawValue, name: L10n.string(titleKey(for: $0), locale: locale))
            }
        case .ebooks:
            return LibraryFilterModel.EbookKind.allCases.map {
                LibraryFilterValue(id: $0.rawValue, name: L10n.string(titleKey(for: $0), locale: locale))
            }
        case .issues, .feedOpen, .explicit:
            return []
        case .genres: return choices.map { named($0.genres) }
        case .tags: return choices.map { named($0.tags) }
        case .series: return choices.map { named($0.series) }
        case .authors: return choices.map { named($0.authors) }
        case .narrators: return choices.map { named($0.narrators) }
        case .languages: return choices.map { named($0.languages) }
        }
    }

    /// What the filter button tells VoiceOver: "All", the group ("Explicit"), or the group and value's name
    /// ("Genre, Fantasy"). A series or author whose name isn't loaded shows the group alone; "No series" and the
    /// progress and ebook values need no filter data.
    static func filterSummary(
        _ filter: LibraryViewPreferences.Filter?, choices: LibraryFilterModel.Choices?, locale: Locale? = nil
    ) -> String {
        guard let filter else { return L10n.string("LabelAll", locale: locale) }
        let group = L10n.string(titleKey(for: filter.group), locale: locale)
        guard let value = filter.value else { return group }
        // "No series" needs no filter data, like the fixed progress and ebook values.
        if filter.group == .series, value == LibraryFilterModel.Choice.noSeries.id {
            return [group, L10n.string("MessageNoSeries", locale: locale)].joined(separator: ", ")
        }
        let name =
            filterValues(for: filter.group, choices: choices, locale: locale)?.first { $0.id == value }?.name
            ?? ([.series, .authors].contains(filter.group) ? nil : value)
        return [group, name].compactMap(\.self).joined(separator: ", ")
    }

    /// Chooses `key` (legacy `OrderModal.vue`): the selected key flips the direction, another one sets it.
    @MainActor
    static func selectSort(_ key: LibrarySortKey, in model: LibraryItemsModel) {
        model.update { $0.selectSort(key) }
    }
}
