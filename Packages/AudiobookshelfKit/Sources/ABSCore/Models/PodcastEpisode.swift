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
}

/// The RSS enclosure an episode was downloaded from.
public struct PodcastEpisodeEnclosure: Sendable, Hashable, Codable {
    public let url: String
    public let type: String?
    /// Bytes, as the feed's string.
    public let length: String?
}
