import ABSAPI
import ABSCore
import Foundation

/// A section of the search results, in the order the legacy `pages/search.vue` shows them.
public enum SearchSectionKind: String, Sendable, Hashable, CaseIterable {
    case books, podcasts, episodes, series, authors, narrators, tags
}

/// One search result and the screen it opens.
public struct SearchResultRow: Sendable, Hashable, Identifiable {
    /// What the row shows.
    public enum Content: Sendable, Hashable {
        /// A book, podcast or podcast episode.
        case item(ItemSummary)
        case series(SeriesSummary)
        case author(AuthorSummary)
        /// A narrator or tag and how many items have it.
        case name(String, count: Int)
    }

    public let content: Content
    public let route: Route

    public init(content: Content, route: Route) {
        self.content = content
        self.route = route
    }

    /// Unique within a section.
    public var id: String {
        switch content {
        case .item(let item): item.id
        case .series(let series): series.id
        case .author(let author): author.id
        case .name(let name, _): name
        }
    }
}

/// A non-empty section of ``SearchResultGroups``.
public struct SearchResultSection: Sendable, Hashable, Identifiable {
    public let kind: SearchSectionKind
    public let rows: [SearchResultRow]

    public var id: SearchSectionKind { kind }
}

/// The results of one search as display sections. Book libraries fill books, series, authors,
/// narrators and tags; podcast libraries fill podcasts, episodes and tags. Genres are not shown,
/// like in the legacy app.
///
/// Routing follows the legacy page: books and podcasts open the item, episodes the episode,
/// series the series, authors the author screen (legacy filtered the library by author instead),
/// and narrators and tags the library filtered to them.
public struct SearchResultGroups: Sendable, Hashable {
    /// The non-empty sections, in ``SearchSectionKind`` order.
    public let sections: [SearchResultSection]

    public static let empty = SearchResultGroups(sections: [])

    init(sections: [SearchResultSection]) {
        self.sections = sections
    }

    public init(_ results: LibrarySearchResults) {
        let groups: [(SearchSectionKind, [SearchResultRow])] = [
            (.books, results.books.map(Self.itemRow)),
            (.podcasts, results.podcasts.map(Self.itemRow)),
            (.episodes, results.episodes.compactMap(Self.episodeRow)),
            (.series, results.series.map(Self.seriesRow)),
            (
                .authors,
                results.authors.map {
                    SearchResultRow(content: .author(AuthorSummary(author: $0)), route: .author(id: $0.id))
                }
            ),
            (.narrators, results.narrators.map { Self.nameRow($0, kind: .narrators) }),
            (.tags, results.tags.map { Self.nameRow($0, kind: .tags) }),
        ]
        sections = groups.compactMap { kind, rows in
            rows.isEmpty ? nil : SearchResultSection(kind: kind, rows: rows)
        }
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// The rows of `kind`, empty when the section is missing.
    public func rows(_ kind: SearchSectionKind) -> [SearchResultRow] {
        sections.first { $0.kind == kind }?.rows ?? []
    }

    private static func itemRow(_ item: LibraryItem) -> SearchResultRow {
        SearchResultRow(content: .item(ItemSummary(item: item)), route: .item(id: item.id))
    }

    /// The server puts the matching episode in `recentEpisode`; a match without one is skipped.
    private static func episodeRow(_ item: LibraryItem) -> SearchResultRow? {
        guard let episode = item.recentEpisode else { return nil }
        return SearchResultRow(
            content: .item(ItemSummary(item: item, episode: episode)),
            route: .episode(itemID: item.id, episodeID: episode.id))
    }

    /// Search series carry their books beside the series, not in `Series.books`.
    private static func seriesRow(_ match: LibrarySearchResults.SeriesMatch) -> SearchResultRow {
        let summary = SeriesSummary(
            id: match.series.id, name: match.series.name, bookCount: match.books.count,
            totalDuration: match.series.totalDuration.flatMap { $0 > 0 ? $0 : nil },
            covers: match.books.compactMap { CoverRef(item: $0) })
        return SearchResultRow(content: .series(summary), route: .series(id: match.series.id))
    }

    private static func nameRow(_ match: LibrarySearchResults.NameMatch, kind: LibraryFilterKind) -> SearchResultRow {
        SearchResultRow(
            content: .name(match.name, count: match.count), route: .libraryFilter(kind: kind, value: match.name))
    }
}
