import Foundation

public enum PodcastEpisodeType: Sendable, Hashable, Codable, RawRepresentable {
    case full
    case trailer
    case bonus
    /// A type this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "full": self = .full
        case "trailer": self = .trailer
        case "bonus": self = .bonus
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .full: "full"
        case .trailer: "trailer"
        case .bonus: "bonus"
        case .unknown(let value): value
        }
    }
}

/// A podcast episode. Expanded episodes add `audioTrack`, `duration`, and `size`.
public struct PodcastEpisode: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let libraryItemId: String?
    public let podcastId: String?
    public let index: Int?
    public let season: String?
    public let episode: String?
    public let episodeType: PodcastEpisodeType?
    public let title: String
    public let subtitle: String?
    public let description: String?
    public let enclosure: PodcastEpisodeEnclosure?
    public let guid: String?
    public let pubDate: String?
    public let chapters: [Chapter]?
    public let audioFile: AudioFile?
    public let audioTrack: AudioTrack?
    /// Epoch milliseconds.
    public let publishedAt: Int?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    /// Seconds.
    public let duration: Double?
    /// Bytes.
    public let size: Int?

    public init(
        id: String, libraryItemId: String? = nil, podcastId: String? = nil, index: Int? = nil, season: String? = nil,
        episode: String? = nil, episodeType: PodcastEpisodeType? = nil, title: String = "", subtitle: String? = nil,
        description: String? = nil, enclosure: PodcastEpisodeEnclosure? = nil, guid: String? = nil,
        pubDate: String? = nil, chapters: [Chapter]? = nil, audioFile: AudioFile? = nil,
        audioTrack: AudioTrack? = nil, publishedAt: Int? = nil, addedAt: Int? = nil, updatedAt: Int? = nil,
        duration: Double? = nil, size: Int? = nil
    ) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.podcastId = podcastId
        self.index = index
        self.season = season
        self.episode = episode
        self.episodeType = episodeType
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.enclosure = enclosure
        self.guid = guid
        self.pubDate = pubDate
        self.chapters = chapters
        self.audioFile = audioFile
        self.audioTrack = audioTrack
        self.publishedAt = publishedAt
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, podcastId, index, season, episode, episodeType, title, subtitle, description
        case enclosure, guid, pubDate, chapters, audioFile, audioTrack, publishedAt, addedAt, updatedAt
        case duration, size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraryItemId = try container.decodeIfPresent(String.self, forKey: .libraryItemId)
        podcastId = try container.decodeIfPresent(String.self, forKey: .podcastId)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        season = try container.decodeIfPresent(String.self, forKey: .season)
        episode = try container.decodeIfPresent(String.self, forKey: .episode)
        episodeType = try container.decodeIfPresent(PodcastEpisodeType.self, forKey: .episodeType)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        enclosure = try container.decodeIfPresent(PodcastEpisodeEnclosure.self, forKey: .enclosure)
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        pubDate = try container.decodeIfPresent(String.self, forKey: .pubDate)
        chapters = try container.decodeIfPresent([Chapter].self, forKey: .chapters)
        audioFile = try container.decodeIfPresent(AudioFile.self, forKey: .audioFile)
        audioTrack = try container.decodeIfPresent(AudioTrack.self, forKey: .audioTrack)
        publishedAt = try container.decodeIfPresent(Int.self, forKey: .publishedAt)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
    }
}

/// The RSS enclosure an episode was downloaded from.
public struct PodcastEpisodeEnclosure: Sendable, Hashable, Codable {
    public let url: String
    public let type: String?
    /// Bytes, as the feed's string.
    public let length: String?

    public init(url: String, type: String? = nil, length: String? = nil) {
        self.url = url
        self.type = type
        self.length = length
    }
}
