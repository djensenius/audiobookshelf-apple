import Foundation

/// The metadata needed to show and play downloaded media offline, stored as a `.codable`
/// attribute on `LocalLibraryItem` and `DownloadRecord`.
///
/// Owned by `ABSData` rather than built from `ABSCore` API models, so API changes can't break
/// stored blobs. Schema versions don't cover its contents (ADR 0003): only add optional
/// properties (decoded with `decodeIfPresent`), never rename or retype a key, and bump
/// ``snapshotVersion`` when the shape changes. It never holds local paths; files link to tracks
/// through `LocalFile.trackIndex` and `LocalFile.episodeId`.
public struct LocalMediaSnapshot: Codable, Sendable, Hashable {
    /// The snapshot version written by this build.
    /// Version 2 added ``coverUpdatedAt``.
    public static let currentVersion = 2

    public var snapshotVersion: Int
    public var metadata: Metadata
    public var chapters: [Chapter]
    public var audioTracks: [AudioTrack]
    public var ebookFile: EbookFile?
    /// For podcasts, the downloaded episodes.
    public var episodes: [Episode]
    /// The server's cover timestamp when the snapshot was taken; `nil` in version 1 snapshots.
    public var coverUpdatedAt: Date?

    public init(
        snapshotVersion: Int = LocalMediaSnapshot.currentVersion,
        metadata: Metadata,
        chapters: [Chapter] = [],
        audioTracks: [AudioTrack] = [],
        ebookFile: EbookFile? = nil,
        episodes: [Episode] = [],
        coverUpdatedAt: Date? = nil
    ) {
        self.snapshotVersion = snapshotVersion
        self.metadata = metadata
        self.chapters = chapters
        self.audioTracks = audioTracks
        self.ebookFile = ebookFile
        self.episodes = episodes
        self.coverUpdatedAt = coverUpdatedAt
    }

    public struct Metadata: Codable, Sendable, Hashable {
        public var title: String
        public var subtitle: String?
        public var authors: [String]
        public var narrators: [String]
        public var series: [Series]
        public var description: String?
        public var publishedYear: String?
        public var explicit: Bool
        public var abridged: Bool

        public init(
            title: String,
            subtitle: String? = nil,
            authors: [String] = [],
            narrators: [String] = [],
            series: [Series] = [],
            description: String? = nil,
            publishedYear: String? = nil,
            explicit: Bool = false,
            abridged: Bool = false
        ) {
            self.title = title
            self.subtitle = subtitle
            self.authors = authors
            self.narrators = narrators
            self.series = series
            self.description = description
            self.publishedYear = publishedYear
            self.explicit = explicit
            self.abridged = abridged
        }
    }

    public struct Series: Codable, Sendable, Hashable {
        public var name: String
        public var sequence: String?

        public init(name: String, sequence: String? = nil) {
            self.name = name
            self.sequence = sequence
        }
    }

    /// A chapter; `start` and `end` are media positions in seconds.
    public struct Chapter: Codable, Sendable, Hashable {
        public var id: Int
        public var start: Double
        public var end: Double
        public var title: String

        public init(id: Int, start: Double, end: Double, title: String) {
            self.id = id
            self.start = start
            self.end = end
            self.title = title
        }
    }

    /// An audio track; `duration` and `startOffset` are in seconds.
    public struct AudioTrack: Codable, Sendable, Hashable {
        public var index: Int
        public var title: String
        public var duration: Double
        public var startOffset: Double
        public var mimeType: String
        public var ino: String?

        public init(
            index: Int, title: String, duration: Double, startOffset: Double, mimeType: String, ino: String? = nil
        ) {
            self.index = index
            self.title = title
            self.duration = duration
            self.startOffset = startOffset
            self.mimeType = mimeType
            self.ino = ino
        }
    }

    public struct EbookFile: Codable, Sendable, Hashable {
        public var ino: String
        public var filename: String
        public var format: String

        public init(ino: String, filename: String, format: String) {
            self.ino = ino
            self.filename = filename
            self.format = format
        }
    }

    /// A downloaded podcast episode.
    public struct Episode: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var season: String?
        public var episode: String?
        public var publishedAt: Date?
        public var duration: Double?
        public var chapters: [Chapter]
        public var track: AudioTrack?

        public init(
            id: String,
            title: String,
            season: String? = nil,
            episode: String? = nil,
            publishedAt: Date? = nil,
            duration: Double? = nil,
            chapters: [Chapter] = [],
            track: AudioTrack? = nil
        ) {
            self.id = id
            self.title = title
            self.season = season
            self.episode = episode
            self.publishedAt = publishedAt
            self.duration = duration
            self.chapters = chapters
            self.track = track
        }
    }
}
