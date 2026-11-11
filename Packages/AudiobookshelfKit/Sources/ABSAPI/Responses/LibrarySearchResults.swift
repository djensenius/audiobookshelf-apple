import ABSCore
import Foundation

/// `GET /api/libraries/:id/search`. Book libraries fill `books`, `series`, `authors`, and
/// `narrators`; podcast libraries fill `podcasts` and `episodes`. Matches that fail to decode
/// are skipped and missing groups are empty.
public struct LibrarySearchResults: Decodable, Sendable, Hashable {
    /// Expanded library items.
    public let books: [LibraryItem]
    /// Expanded library items without episodes.
    public let podcasts: [LibraryItem]
    /// Podcast library items whose `recentEpisode` is the matching episode.
    public let episodes: [LibraryItem]
    public let series: [SeriesMatch]
    public let authors: [Author]
    public let narrators: [NameMatch]
    public let tags: [NameMatch]
    public let genres: [NameMatch]

    public init(
        books: [LibraryItem] = [], podcasts: [LibraryItem] = [], episodes: [LibraryItem] = [],
        series: [SeriesMatch] = [], authors: [Author] = [], narrators: [NameMatch] = [], tags: [NameMatch] = [],
        genres: [NameMatch] = []
    ) {
        self.books = books
        self.podcasts = podcasts
        self.episodes = episodes
        self.series = series
        self.authors = authors
        self.narrators = narrators
        self.tags = tags
        self.genres = genres
    }

    /// A series and its nonexpanded books. Search members have empty author/series arrays
    /// and no per-series sequence; they are not the minified item-list shape.
    public struct SeriesMatch: Decodable, Sendable, Hashable, Identifiable {
        public let series: Series
        public let books: [LibraryItem]

        public init(series: Series, books: [LibraryItem]) {
            self.series = series
            self.books = books
        }

        public var id: String { series.id }

        enum CodingKeys: String, CodingKey {
            case series, books
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            series = try container.decode(Series.self, forKey: .series)
            books = try container.decodeLossyArrayIfPresent(LibraryItem.self, forKey: .books) ?? []
        }
    }

    /// A narrator, tag, or genre and how many items have it.
    public struct NameMatch: Decodable, Sendable, Hashable, Identifiable {
        public let name: String
        /// `numBooks` for narrators, `numItems` for tags and genres.
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }

        public var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, numBooks, numItems
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            count =
                try container.decodeIfPresent(Int.self, forKey: .numBooks)
                ?? container.decodeIfPresent(Int.self, forKey: .numItems) ?? 0
        }
    }

    /// The server wraps each item match as `{ "libraryItem": … }`.
    private struct ItemMatch: Decodable {
        let libraryItem: LibraryItem
    }

    enum CodingKeys: String, CodingKey {
        case book, podcast, episodes, series, authors, narrators, tags, genres
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func items(_ key: CodingKeys) throws -> [LibraryItem] {
            try container.decodeLossyArrayIfPresent(ItemMatch.self, forKey: key)?.map(\.libraryItem) ?? []
        }
        books = try items(.book)
        podcasts = try items(.podcast)
        episodes = try items(.episodes)
        series = try container.decodeLossyArrayIfPresent(SeriesMatch.self, forKey: .series) ?? []
        authors = try container.decodeLossyArrayIfPresent(Author.self, forKey: .authors) ?? []
        narrators = try container.decodeLossyArrayIfPresent(NameMatch.self, forKey: .narrators) ?? []
        tags = try container.decodeLossyArrayIfPresent(NameMatch.self, forKey: .tags) ?? []
        genres = try container.decodeLossyArrayIfPresent(NameMatch.self, forKey: .genres) ?? []
    }
}
