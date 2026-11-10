import Foundation

/// What a ``MediaProgress`` row tracks.
public enum MediaItemType: Sendable, Hashable, Codable, RawRepresentable {
    case book
    case podcastEpisode
    /// A type this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "book": self = .book
        case "podcastEpisode": self = .podcastEpisode
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .book: "book"
        case .podcastEpisode: "podcastEpisode"
        case .unknown(let value): value
        }
    }
}

/// A user's progress on a book or podcast episode (server `MediaProgress.getOldMediaProgress`).
///
/// Times and durations are seconds; `lastUpdate`, `startedAt`, and `finishedAt` are epoch
/// milliseconds. The server sends `libraryItemId: null` when the row's `extraData` lacks it;
/// such rows can't be keyed, so they fail to decode and ``User`` drops them.
public struct MediaProgress: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var userId: String?
    public var libraryItemId: String
    public var episodeId: String?
    /// The book or podcast episode ID.
    public var mediaItemId: String?
    public var mediaItemType: MediaItemType?
    public var duration: Double
    /// `0...1`.
    public var progress: Double
    public var currentTime: Double
    public var isFinished: Bool
    public var hideFromContinueListening: Bool
    /// EPUB CFI or page reference, depending on the ebook format.
    public var ebookLocation: String?
    /// `0...1`.
    public var ebookProgress: Double?
    public var lastUpdate: Int?
    public var startedAt: Int?
    public var finishedAt: Int?

    public init(
        id: String, userId: String? = nil, libraryItemId: String, episodeId: String? = nil,
        mediaItemId: String? = nil, mediaItemType: MediaItemType? = nil, duration: Double = 0, progress: Double = 0,
        currentTime: Double = 0, isFinished: Bool = false, hideFromContinueListening: Bool = false,
        ebookLocation: String? = nil, ebookProgress: Double? = nil, lastUpdate: Int? = nil, startedAt: Int? = nil,
        finishedAt: Int? = nil
    ) {
        self.id = id
        self.userId = userId
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.mediaItemId = mediaItemId
        self.mediaItemType = mediaItemType
        self.duration = duration
        self.progress = progress
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.hideFromContinueListening = hideFromContinueListening
        self.ebookLocation = ebookLocation
        self.ebookProgress = ebookProgress
        self.lastUpdate = lastUpdate
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, libraryItemId, episodeId, mediaItemId, mediaItemType, duration, progress, currentTime
        case isFinished, hideFromContinueListening, ebookLocation, ebookProgress, lastUpdate, startedAt, finishedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        libraryItemId = try container.decode(String.self, forKey: .libraryItemId)
        episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
        mediaItemId = try container.decodeIfPresent(String.self, forKey: .mediaItemId)
        mediaItemType = try container.decodeIfPresent(MediaItemType.self, forKey: .mediaItemType)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        currentTime = try container.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        isFinished = try container.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        hideFromContinueListening =
            try container.decodeIfPresent(Bool.self, forKey: .hideFromContinueListening) ?? false
        ebookLocation = try container.decodeIfPresent(String.self, forKey: .ebookLocation)
        ebookProgress = try container.decodeIfPresent(Double.self, forKey: .ebookProgress)
        lastUpdate = try container.decodeIfPresent(Int.self, forKey: .lastUpdate)
        startedAt = try container.decodeIfPresent(Int.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Int.self, forKey: .finishedAt)
    }

    /// The key the legacy app used to match progress to an item: see ``key(libraryItemID:episodeID:)``.
    public var progressKey: String {
        Self.key(libraryItemID: libraryItemId, episodeID: episodeId)
    }

    /// `libraryItemID` for books, `libraryItemID-episodeID` for podcast episodes. An empty
    /// episode ID counts as none.
    public static func key(libraryItemID: String, episodeID: String?) -> String {
        guard let episodeID, !episodeID.isEmpty else { return libraryItemID }
        return "\(libraryItemID)-\(episodeID)"
    }
}
