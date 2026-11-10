import Foundation

/// The kind of media a library or library item holds.
public enum MediaType: Sendable, Hashable, Codable, RawRepresentable {
    case book
    case podcast
    /// A media type this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "book": self = .book
        case "podcast": self = .podcast
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .book: "book"
        case .podcast: "podcast"
        case .unknown(let value): value
        }
    }
}

/// A library item's media, whose shape depends on the item's `mediaType`.
public enum LibraryItemMedia: Sendable, Hashable, Encodable {
    case book(Book)
    case podcast(Podcast)

    /// Decodes the payload for `mediaType`, or returns `nil` for an unknown media type.
    init?(from decoder: any Decoder, mediaType: MediaType) throws {
        switch mediaType {
        case .book: self = .book(try Book(from: decoder))
        case .podcast: self = .podcast(try Podcast(from: decoder))
        case .unknown: return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .book(let book): try book.encode(to: encoder)
        case .podcast(let podcast): try podcast.encode(to: encoder)
        }
    }

    public var coverPath: String? {
        switch self {
        case .book(let book): book.coverPath
        case .podcast(let podcast): podcast.coverPath
        }
    }
}

/// Metadata for a book or a podcast, whose shape depends on the owner's `mediaType`.
public enum MediaMetadata: Sendable, Hashable, Encodable {
    case book(BookMetadata)
    case podcast(PodcastMetadata)

    init?(from decoder: any Decoder, mediaType: MediaType) throws {
        switch mediaType {
        case .book: self = .book(try BookMetadata(from: decoder))
        case .podcast: self = .podcast(try PodcastMetadata(from: decoder))
        case .unknown: return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .book(let metadata): try metadata.encode(to: encoder)
        case .podcast(let metadata): try metadata.encode(to: encoder)
        }
    }

    public var title: String {
        switch self {
        case .book(let metadata): metadata.title
        case .podcast(let metadata): metadata.title
        }
    }
}

/// A book's media. Minified items carry counts (`numTracks`, …) instead of files;
/// expanded items carry `tracks`, `duration`, and `size`.
public struct Book: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let libraryItemId: String?
    public let metadata: BookMetadata
    public let coverPath: String?
    public let tags: [String]?
    public let audioFiles: [AudioFile]?
    public let chapters: [Chapter]?
    public let ebookFile: EbookFile?
    public let tracks: [AudioTrack]?
    /// Seconds.
    public let duration: Double?
    /// Bytes.
    public let size: Int?
    public let numTracks: Int?
    public let numAudioFiles: Int?
    public let numChapters: Int?
    /// Present on minified items that have an ebook.
    public let ebookFormat: EbookFormat?

    public init(
        id: String, libraryItemId: String? = nil, metadata: BookMetadata, coverPath: String? = nil,
        tags: [String]? = nil, audioFiles: [AudioFile]? = nil, chapters: [Chapter]? = nil, ebookFile: EbookFile? = nil,
        tracks: [AudioTrack]? = nil, duration: Double? = nil, size: Int? = nil, numTracks: Int? = nil,
        numAudioFiles: Int? = nil, numChapters: Int? = nil, ebookFormat: EbookFormat? = nil
    ) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.metadata = metadata
        self.coverPath = coverPath
        self.tags = tags
        self.audioFiles = audioFiles
        self.chapters = chapters
        self.ebookFile = ebookFile
        self.tracks = tracks
        self.duration = duration
        self.size = size
        self.numTracks = numTracks
        self.numAudioFiles = numAudioFiles
        self.numChapters = numChapters
        self.ebookFormat = ebookFormat
    }
}

/// Book metadata. Expanded and minified items add the flattened `authorName`,
/// `narratorName`, and `seriesName`; minified items omit `authors`, `narrators`, and `series`.
public struct BookMetadata: Sendable, Hashable, Codable {
    public let title: String
    public let titleIgnorePrefix: String?
    public let subtitle: String?
    public let authors: [Author]?
    public let narrators: [String]?
    public let series: [Series]?
    public let genres: [String]?
    public let publishedYear: String?
    public let publishedDate: String?
    public let publisher: String?
    public let description: String?
    public let descriptionPlain: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let explicit: Bool?
    public let abridged: Bool?
    public let authorName: String?
    public let authorNameLF: String?
    public let narratorName: String?
    public let seriesName: String?

    public init(
        title: String, titleIgnorePrefix: String? = nil, subtitle: String? = nil, authors: [Author]? = nil,
        narrators: [String]? = nil, series: [Series]? = nil, genres: [String]? = nil, publishedYear: String? = nil,
        publishedDate: String? = nil, publisher: String? = nil, description: String? = nil,
        descriptionPlain: String? = nil, isbn: String? = nil, asin: String? = nil, language: String? = nil,
        explicit: Bool? = nil, abridged: Bool? = nil, authorName: String? = nil, authorNameLF: String? = nil,
        narratorName: String? = nil, seriesName: String? = nil
    ) {
        self.title = title
        self.titleIgnorePrefix = titleIgnorePrefix
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.genres = genres
        self.publishedYear = publishedYear
        self.publishedDate = publishedDate
        self.publisher = publisher
        self.description = description
        self.descriptionPlain = descriptionPlain
        self.isbn = isbn
        self.asin = asin
        self.language = language
        self.explicit = explicit
        self.abridged = abridged
        self.authorName = authorName
        self.authorNameLF = authorNameLF
        self.narratorName = narratorName
        self.seriesName = seriesName
    }
}

/// A podcast's media. Minified items carry `numEpisodes` instead of `episodes`.
/// Episodes that fail to decode are skipped.
public struct Podcast: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let libraryItemId: String?
    public let metadata: PodcastMetadata
    public let coverPath: String?
    public let tags: [String]?
    public let episodes: [PodcastEpisode]?
    public let numEpisodes: Int?
    public let autoDownloadEpisodes: Bool?
    public let autoDownloadSchedule: String?
    /// Epoch milliseconds.
    public let lastEpisodeCheck: Int?
    public let maxEpisodesToKeep: Int?
    public let maxNewEpisodesToDownload: Int?
    /// Bytes.
    public let size: Int?

    public init(
        id: String, libraryItemId: String? = nil, metadata: PodcastMetadata, coverPath: String? = nil,
        tags: [String]? = nil, episodes: [PodcastEpisode]? = nil, numEpisodes: Int? = nil,
        autoDownloadEpisodes: Bool? = nil, autoDownloadSchedule: String? = nil, lastEpisodeCheck: Int? = nil,
        maxEpisodesToKeep: Int? = nil, maxNewEpisodesToDownload: Int? = nil, size: Int? = nil
    ) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.metadata = metadata
        self.coverPath = coverPath
        self.tags = tags
        self.episodes = episodes
        self.numEpisodes = numEpisodes
        self.autoDownloadEpisodes = autoDownloadEpisodes
        self.autoDownloadSchedule = autoDownloadSchedule
        self.lastEpisodeCheck = lastEpisodeCheck
        self.maxEpisodesToKeep = maxEpisodesToKeep
        self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, metadata, coverPath, tags, episodes, numEpisodes, autoDownloadEpisodes
        case autoDownloadSchedule, lastEpisodeCheck, maxEpisodesToKeep, maxNewEpisodesToDownload, size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraryItemId = try container.decodeIfPresent(String.self, forKey: .libraryItemId)
        metadata = try container.decode(PodcastMetadata.self, forKey: .metadata)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        episodes = try container.decodeLossyArrayIfPresent(PodcastEpisode.self, forKey: .episodes)
        numEpisodes = try container.decodeIfPresent(Int.self, forKey: .numEpisodes)
        autoDownloadEpisodes = try container.decodeIfPresent(Bool.self, forKey: .autoDownloadEpisodes)
        autoDownloadSchedule = try container.decodeIfPresent(String.self, forKey: .autoDownloadSchedule)
        lastEpisodeCheck = try container.decodeIfPresent(Int.self, forKey: .lastEpisodeCheck)
        maxEpisodesToKeep = try container.decodeIfPresent(Int.self, forKey: .maxEpisodesToKeep)
        maxNewEpisodesToDownload = try container.decodeIfPresent(Int.self, forKey: .maxNewEpisodesToDownload)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
    }
}

public struct PodcastMetadata: Sendable, Hashable, Codable {
    public let title: String
    public let titleIgnorePrefix: String?
    public let author: String?
    public let description: String?
    public let releaseDate: String?
    public let genres: [String]?
    public let feedUrl: String?
    public let imageUrl: String?
    public let itunesPageUrl: String?
    public let itunesId: String?
    public let itunesArtistId: String?
    public let explicit: Bool?
    public let language: String?
    /// `episodic` or `serial`.
    public let type: String?

    public init(
        title: String, titleIgnorePrefix: String? = nil, author: String? = nil, description: String? = nil,
        releaseDate: String? = nil, genres: [String]? = nil, feedUrl: String? = nil, imageUrl: String? = nil,
        itunesPageUrl: String? = nil, itunesId: String? = nil, itunesArtistId: String? = nil, explicit: Bool? = nil,
        language: String? = nil, type: String? = nil
    ) {
        self.title = title
        self.titleIgnorePrefix = titleIgnorePrefix
        self.author = author
        self.description = description
        self.releaseDate = releaseDate
        self.genres = genres
        self.feedUrl = feedUrl
        self.imageUrl = imageUrl
        self.itunesPageUrl = itunesPageUrl
        self.itunesId = itunesId
        self.itunesArtistId = itunesArtistId
        self.explicit = explicit
        self.language = language
        self.type = type
    }
}
