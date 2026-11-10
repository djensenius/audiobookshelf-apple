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

    public var id: String { ino }
}

/// A playable track. Offsets and durations are in seconds.
public struct AudioTrack: Sendable, Hashable, Codable, Identifiable {
    public let index: Int
    public let startOffset: Double?
    public let duration: Double
    public let title: String?
    /// Server-relative path, for example `/api/items/<id>/file/<ino>` or a session track URL.
    public let contentUrl: String?
    public let mimeType: String?
    public let codec: String?
    public let metadata: FileMetadata?

    public var id: Int { index }

    /// Seconds from the start of the media at which this track ends.
    public var endOffset: Double { (startOffset ?? 0) + duration }
}

/// A chapter. `start` and `end` are seconds from the start of the media.
public struct Chapter: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String
}
