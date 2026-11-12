import Foundation

/// Any JSON value, kept as the server sent it so it can be sent back unchanged.
public enum RawJSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RawJSONValue])
    case object([String: RawJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RawJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The member `key` of an object; `nil` for other values.
    public subscript(key: String) -> RawJSONValue? {
        if case .object(let members) = self { members[key] } else { nil }
    }

    /// The text of a string, trimmed; `nil` when it isn't a string or is blank.
    var text: String? {
        guard case .string(let value) = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One episode of a podcast's RSS feed as the server parsed it (server `podcastUtils.extractEpisodeData`),
/// for choosing episodes to download to the server.
///
/// The whole object is kept in ``raw`` and encoded back unchanged, because
/// `POST /api/podcasts/:id/download-episodes` takes the episodes as the feed lookup returned them
/// (legacy `PodcastEpisodesFeedModal.vue`); the other properties are read from it for display.
public struct RSSFeedEpisode: Sendable, Hashable, Codable {
    /// The episode object as received.
    public let raw: RawJSONValue
    /// `enclosure.url`, trimmed, which the server downloads and the library's episodes keep.
    public let enclosureURL: String
    public let title: String
    public let subtitle: String?
    /// The feed's `itunes:episode`, as text.
    public let episode: String?
    /// Milliseconds since 1970, when the feed's `pubDate` parsed.
    public let publishedAt: Int?

    /// Reads an episode from `raw`; `nil` without an enclosure URL, which the server can't download.
    public init?(raw: RawJSONValue) {
        guard let url = raw["enclosure"]?["url"]?.text else { return nil }
        self.raw = raw
        enclosureURL = url
        title = raw["title"]?.text ?? ""
        subtitle = raw["subtitle"]?.text
        episode = raw["episode"]?.text
        if case .number(let value) = raw["publishedAt"], value.isFinite {
            publishedAt = Int(exactly: value.rounded())
        } else {
            publishedAt = nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try RawJSONValue(from: decoder)
        guard let episode = RSSFeedEpisode(raw: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No enclosure URL"))
        }
        self = episode
    }

    public func encode(to encoder: any Encoder) throws {
        try raw.encode(to: encoder)
    }
}

/// `POST /api/podcasts/feed`, read only for the episodes (`podcast.episodes`). Episodes without an
/// enclosure URL are skipped; a missing list reads as empty.
public struct RSSFeedEpisodesResponse: Sendable, Hashable, Decodable {
    public let episodes: [RSSFeedEpisode]

    public init(episodes: [RSSFeedEpisode]) {
        self.episodes = episodes
    }

    public init(from decoder: any Decoder) throws {
        let raw = try RawJSONValue(from: decoder)
        guard case .array(let values) = raw["podcast"]?["episodes"] else {
            episodes = []
            return
        }
        episodes = values.compactMap(RSSFeedEpisode.init(raw:))
    }
}
