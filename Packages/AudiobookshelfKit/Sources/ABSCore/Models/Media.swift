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
}

/// A podcast's media. Minified items carry `numEpisodes` instead of `episodes`.
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
}
