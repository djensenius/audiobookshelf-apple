import ABSCore
import Foundation

/// One podcast from ``PodcastEndpoints/searchDirectory(term:country:)`` (server `iTunes.cleanPodcast`). Every field
/// is optional on the wire; a value of the wrong type decodes as `nil`, so one odd row doesn't fail the search.
public struct PodcastDirectoryResult: Decodable, Sendable, Hashable {
    /// The iTunes collection ID, as a string (the server sends a number).
    public let itunesID: String?
    public let itunesArtistID: String?
    public let title: String
    public let artistName: String?
    /// Sanitized HTML.
    public let description: String?
    public let descriptionPlain: String?
    public let releaseDate: String?
    public let genres: [String]
    /// The artwork's absolute URL.
    public let cover: String?
    public let trackCount: Int?
    /// `nil` for directory entries without a feed, which can't be added.
    public let feedURL: String?
    /// The podcast's iTunes page.
    public let pageURL: String?
    public let explicit: Bool

    public init(
        itunesID: String? = nil, itunesArtistID: String? = nil, title: String, artistName: String? = nil,
        description: String? = nil, descriptionPlain: String? = nil, releaseDate: String? = nil, genres: [String] = [],
        cover: String? = nil, trackCount: Int? = nil, feedURL: String? = nil, pageURL: String? = nil,
        explicit: Bool = false
    ) {
        self.itunesID = itunesID
        self.itunesArtistID = itunesArtistID
        self.title = title
        self.artistName = artistName
        self.description = description
        self.descriptionPlain = descriptionPlain
        self.releaseDate = releaseDate
        self.genres = genres
        self.cover = cover
        self.trackCount = trackCount
        self.feedURL = feedURL
        self.pageURL = pageURL
        self.explicit = explicit
    }

    enum CodingKeys: String, CodingKey {
        case title, artistName, description, descriptionPlain, releaseDate, genres, cover, trackCount, explicit
        case itunesID = "id"
        case itunesArtistID = "artistId"
        case feedURL = "feedUrl"
        case pageURL = "pageUrl"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itunesID = container.lenientIdentifier(forKey: .itunesID)
        itunesArtistID = container.lenientIdentifier(forKey: .itunesArtistID)
        title = container.lenientString(forKey: .title) ?? ""
        artistName = container.lenientString(forKey: .artistName)
        description = container.lenientString(forKey: .description)
        descriptionPlain = container.lenientString(forKey: .descriptionPlain)
        releaseDate = container.lenientString(forKey: .releaseDate)
        genres = container.lenientStrings(forKey: .genres)
        cover = container.lenientString(forKey: .cover)
        trackCount = (try? container.decodeIfPresent(Int.self, forKey: .trackCount)) ?? nil
        feedURL = container.lenientString(forKey: .feedURL)
        pageURL = container.lenientString(forKey: .pageURL)
        explicit = (try? container.decodeIfPresent(Bool.self, forKey: .explicit)) ?? false
    }
}

/// The response of ``PodcastEndpoints/feed(rssFeed:)``.
public struct PodcastFeedResponse: Decodable, Sendable, Hashable {
    public let podcast: PodcastFeed

    public init(podcast: PodcastFeed) {
        self.podcast = podcast
    }
}

/// A parsed RSS feed (server `podcastUtils` `RssPodcast`).
public struct PodcastFeed: Decodable, Sendable, Hashable {
    public let metadata: PodcastFeedMetadata
    /// Episodes that fail to decode are skipped.
    public let episodes: [PodcastFeedEpisode]
    /// The number of items in the feed, including any the server couldn't parse.
    public let numEpisodes: Int?

    public init(metadata: PodcastFeedMetadata, episodes: [PodcastFeedEpisode] = [], numEpisodes: Int? = nil) {
        self.metadata = metadata
        self.episodes = episodes
        self.numEpisodes = numEpisodes
    }

    enum CodingKeys: String, CodingKey {
        case metadata, episodes, numEpisodes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(PodcastFeedMetadata.self, forKey: .metadata)
        episodes = try container.decodeLossyArrayIfPresent(PodcastFeedEpisode.self, forKey: .episodes) ?? []
        numEpisodes = (try? container.decodeIfPresent(Int.self, forKey: .numEpisodes)) ?? nil
    }
}

/// A feed's channel metadata. The server copies RSS values as they are, so each field is `nil` when missing or not
/// a string.
public struct PodcastFeedMetadata: Decodable, Sendable, Hashable {
    public let title: String?
    public let author: String?
    /// Sanitized HTML.
    public let description: String?
    public let descriptionPlain: String?
    /// The channel's image URL.
    public let image: String?
    /// iTunes categories, subcategories as `Parent:Child`.
    public let categories: [String]
    /// The URL the server fetched, or the feed's `itunes:new-feed-url`.
    public let feedURL: String?
    public let language: String?
    /// `itunes:explicit` as written, such as `yes`, `true`, `no` or `clean`; see ``isExplicit``.
    public let explicit: String?
    /// `itunes:type`: `episodic` or `serial`.
    public let type: String?

    public init(
        title: String? = nil, author: String? = nil, description: String? = nil, descriptionPlain: String? = nil,
        image: String? = nil, categories: [String] = [], feedURL: String? = nil, language: String? = nil,
        explicit: String? = nil, type: String? = nil
    ) {
        self.title = title
        self.author = author
        self.description = description
        self.descriptionPlain = descriptionPlain
        self.image = image
        self.categories = categories
        self.feedURL = feedURL
        self.language = language
        self.explicit = explicit
        self.type = type
    }

    /// Whether ``explicit`` marks the podcast explicit (`yes`, `true` or `explicit`, ignoring case).
    public var isExplicit: Bool {
        guard let explicit else { return false }
        return ["yes", "true", "explicit"].contains(explicit.trimmingCharacters(in: .whitespaces).lowercased())
    }

    enum CodingKeys: String, CodingKey {
        case title, author, description, descriptionPlain, image, categories, language, explicit, type
        case feedURL = "feedUrl"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenientString(forKey: .title)
        author = container.lenientString(forKey: .author)
        description = container.lenientString(forKey: .description)
        descriptionPlain = container.lenientString(forKey: .descriptionPlain)
        image = container.lenientString(forKey: .image)
        categories = container.lenientStrings(forKey: .categories)
        feedURL = container.lenientString(forKey: .feedURL)
        language = container.lenientString(forKey: .language)
        explicit = container.lenientString(forKey: .explicit)
        type = container.lenientString(forKey: .type)
    }
}

/// One episode of a parsed feed; only what the add-podcast screens show.
public struct PodcastFeedEpisode: Decodable, Sendable, Hashable {
    public let title: String?
    /// The audio file's URL.
    public let enclosureURL: String?

    public init(title: String? = nil, enclosureURL: String? = nil) {
        self.title = title
        self.enclosureURL = enclosureURL
    }

    enum CodingKeys: String, CodingKey {
        case title, enclosure
    }

    enum EnclosureKeys: String, CodingKey {
        case url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenientString(forKey: .title)
        let enclosure = try? container.nestedContainer(keyedBy: EnclosureKeys.self, forKey: .enclosure)
        enclosureURL = enclosure?.lenientString(forKey: .url)
    }
}

extension KeyedDecodingContainer {
    /// The string at `key`; `nil` when it's missing, `null` or not a string.
    fileprivate func lenientString(forKey key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    /// The strings at `key`, skipping values that aren't strings; empty when it isn't an array.
    fileprivate func lenientStrings(forKey key: Key) -> [String] {
        ((try? decodeIfPresent(LossyArray<String>.self, forKey: key)) ?? nil)?.elements ?? []
    }

    /// A string, or a whole number written as a string (iTunes IDs are numbers).
    fileprivate func lenientIdentifier(forKey key: Key) -> String? {
        if let number = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return String(number) }
        return lenientString(forKey: key)
    }
}
