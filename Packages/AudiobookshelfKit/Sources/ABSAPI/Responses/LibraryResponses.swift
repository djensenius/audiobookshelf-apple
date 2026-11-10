import ABSCore
import Foundation

/// `GET /api/libraries`. Libraries that fail to decode are skipped.
public struct LibrariesResponse: Decodable, Sendable, Hashable {
    public let libraries: [Library]

    public init(libraries: [Library]) {
        self.libraries = libraries
    }

    enum CodingKeys: String, CodingKey {
        case libraries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraries = try container.decodeLossyArrayIfPresent(Library.self, forKey: .libraries) ?? []
    }
}

/// `GET /api/libraries/:id?include=filterdata`.
public struct LibraryWithFilterData: Decodable, Sendable, Hashable {
    public let library: Library
    public let filterData: LibraryFilterData
    /// Items that are missing or invalid.
    public let issues: Int
    public let numUserPlaylists: Int

    public init(library: Library, filterData: LibraryFilterData, issues: Int = 0, numUserPlaylists: Int = 0) {
        self.library = library
        self.filterData = filterData
        self.issues = issues
        self.numUserPlaylists = numUserPlaylists
    }

    enum CodingKeys: String, CodingKey {
        case library, filterdata, issues, numUserPlaylists
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        library = try container.decode(Library.self, forKey: .library)
        filterData = try container.decodeIfPresent(LibraryFilterData.self, forKey: .filterdata) ?? LibraryFilterData()
        issues = try container.decodeIfPresent(Int.self, forKey: .issues) ?? 0
        numUserPlaylists = try container.decodeIfPresent(Int.self, forKey: .numUserPlaylists) ?? 0
    }
}

/// The values a library can be filtered by. Authors and series carry only `id` and `name`.
public struct LibraryFilterData: Decodable, Sendable, Hashable {
    public let authors: [Author]
    public let series: [Series]
    public let genres: [String]
    public let tags: [String]
    public let narrators: [String]
    public let languages: [String]
    public let publishers: [String]
    public let publishedDecades: [String]
    public let numIssues: Int
    /// Epoch milliseconds.
    public let loadedAt: Int?

    public init(
        authors: [Author] = [], series: [Series] = [], genres: [String] = [], tags: [String] = [],
        narrators: [String] = [], languages: [String] = [], publishers: [String] = [],
        publishedDecades: [String] = [], numIssues: Int = 0, loadedAt: Int? = nil
    ) {
        self.authors = authors
        self.series = series
        self.genres = genres
        self.tags = tags
        self.narrators = narrators
        self.languages = languages
        self.publishers = publishers
        self.publishedDecades = publishedDecades
        self.numIssues = numIssues
        self.loadedAt = loadedAt
    }

    enum CodingKeys: String, CodingKey {
        case authors, series, genres, tags, narrators, languages, publishers, publishedDecades, numIssues, loadedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authors = try container.decodeLossyArrayIfPresent(Author.self, forKey: .authors) ?? []
        series = try container.decodeLossyArrayIfPresent(Series.self, forKey: .series) ?? []
        genres = try container.decodeLossyArrayIfPresent(String.self, forKey: .genres) ?? []
        tags = try container.decodeLossyArrayIfPresent(String.self, forKey: .tags) ?? []
        narrators = try container.decodeLossyArrayIfPresent(String.self, forKey: .narrators) ?? []
        languages = try container.decodeLossyArrayIfPresent(String.self, forKey: .languages) ?? []
        publishers = try container.decodeLossyArrayIfPresent(String.self, forKey: .publishers) ?? []
        publishedDecades = try container.decodeLossyArrayIfPresent(String.self, forKey: .publishedDecades) ?? []
        numIssues = try container.decodeIfPresent(Int.self, forKey: .numIssues) ?? 0
        loadedAt = try container.decodeIfPresent(Int.self, forKey: .loadedAt)
    }
}

/// `GET /api/libraries/:id/authors` without paging. Authors that fail to decode are skipped.
public struct AuthorsResponse: Decodable, Sendable, Hashable {
    public let authors: [Author]

    public init(authors: [Author]) {
        self.authors = authors
    }

    enum CodingKeys: String, CodingKey {
        case authors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authors = try container.decodeLossyArrayIfPresent(Author.self, forKey: .authors) ?? []
    }
}

/// `GET /api/libraries/:id/recent-episodes`. The server sends no total.
public struct RecentEpisodesPage: Decodable, Sendable, Hashable {
    public let episodes: [RecentEpisode]
    public let limit: Int
    public let page: Int

    public init(episodes: [RecentEpisode], limit: Int, page: Int) {
        self.episodes = episodes
        self.limit = limit
        self.page = page
    }

    enum CodingKeys: String, CodingKey {
        case episodes, limit, page
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try container.decodeLossyArrayIfPresent(RecentEpisode.self, forKey: .episodes) ?? []
        limit = try container.decodeLenientIntIfPresent(forKey: .limit) ?? 0
        page = try container.decodeLenientIntIfPresent(forKey: .page) ?? 0
    }
}

/// An episode from the recent episodes list, with its podcast (without episodes).
public struct RecentEpisode: Decodable, Sendable, Hashable, Identifiable {
    public let episode: PodcastEpisode
    public let podcast: Podcast?
    public let libraryId: String?

    public init(episode: PodcastEpisode, podcast: Podcast? = nil, libraryId: String? = nil) {
        self.episode = episode
        self.podcast = podcast
        self.libraryId = libraryId
    }

    public var id: String { episode.id }

    enum CodingKeys: String, CodingKey {
        case podcast, libraryId
    }

    public init(from decoder: any Decoder) throws {
        episode = try PodcastEpisode(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        podcast = try container.decodeIfPresent(Podcast.self, forKey: .podcast)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId)
    }
}
