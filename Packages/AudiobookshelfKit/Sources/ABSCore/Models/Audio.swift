import Foundation

/// An audio file in a library item, as scanned by the server.
public struct AudioFile: Sendable, Hashable, Codable, Identifiable {
    public let index: Int?
    public let ino: String
    public let metadata: FileMetadata?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    public let trackNumFromMeta: Int?
    public let discNumFromMeta: Int?
    public let trackNumFromFilename: Int?
    public let discNumFromFilename: Int?
    public let manuallyVerified: Bool?
    public let exclude: Bool?
    public let error: String?
    public let format: String?
    /// Seconds.
    public let duration: Double?
    public let bitRate: Int?
    public let language: String?
    public let codec: String?
    public let channels: Int?
    public let channelLayout: String?
    public let chapters: [Chapter]?
    public let embeddedCoverArt: String?
    public let mimeType: String?

    public init(
        index: Int? = nil, ino: String, metadata: FileMetadata? = nil, addedAt: Int? = nil, updatedAt: Int? = nil,
        trackNumFromMeta: Int? = nil, discNumFromMeta: Int? = nil, trackNumFromFilename: Int? = nil,
        discNumFromFilename: Int? = nil, manuallyVerified: Bool? = nil, exclude: Bool? = nil, error: String? = nil,
        format: String? = nil, duration: Double? = nil, bitRate: Int? = nil, language: String? = nil,
        codec: String? = nil, channels: Int? = nil, channelLayout: String? = nil, chapters: [Chapter]? = nil,
        embeddedCoverArt: String? = nil, mimeType: String? = nil
    ) {
        self.index = index
        self.ino = ino
        self.metadata = metadata
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.trackNumFromMeta = trackNumFromMeta
        self.discNumFromMeta = discNumFromMeta
        self.trackNumFromFilename = trackNumFromFilename
        self.discNumFromFilename = discNumFromFilename
        self.manuallyVerified = manuallyVerified
        self.exclude = exclude
        self.error = error
        self.format = format
        self.duration = duration
        self.bitRate = bitRate
        self.language = language
        self.codec = codec
        self.channels = channels
        self.channelLayout = channelLayout
        self.chapters = chapters
        self.embeddedCoverArt = embeddedCoverArt
        self.mimeType = mimeType
    }

    public var id: String { ino }
}

/// A playable track. Offsets and durations are in seconds.
public struct AudioTrack: Sendable, Hashable, Codable, Identifiable {
    /// 1-based. Servers 2.26.0–2.26.2 may send `null` for podcast episode tracks.
    public let index: Int?
    public let startOffset: Double?
    public let duration: Double
    public let title: String?
    /// Server-relative path, for example `/api/items/<id>/file/<ino>` or a session track URL.
    public let contentUrl: String?
    public let mimeType: String?
    public let codec: String?
    public let metadata: FileMetadata?

    public init(
        index: Int? = nil, startOffset: Double? = nil, duration: Double, title: String? = nil,
        contentUrl: String? = nil,
        mimeType: String? = nil, codec: String? = nil, metadata: FileMetadata? = nil
    ) {
        self.index = index
        self.startOffset = startOffset
        self.duration = duration
        self.title = title
        self.contentUrl = contentUrl
        self.mimeType = mimeType
        self.codec = codec
        self.metadata = metadata
    }

    /// `"<index>-<startOffset>"`, with `0` for missing values. Tracks in one media item have distinct
    /// start offsets, so this stays unique when `index` is `null`.
    public var id: String { "\(index ?? 0)-\(startOffset ?? 0)" }

    /// Seconds from the start of the media at which this track ends.
    public var endOffset: Double { (startOffset ?? 0) + duration }
}

/// A chapter. `start` and `end` are seconds from the start of the media.
public struct Chapter: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String

    public init(id: Int, start: Double, end: Double, title: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    }
}
