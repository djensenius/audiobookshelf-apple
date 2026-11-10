import Foundation

/// A library item in any of the server's forms:
/// - full (`GET /api/items/:id`): `media` with files and `libraryFiles`;
/// - expanded (`?expanded=1`): also `size`, and media `tracks`, `duration`, `size`;
/// - minified (lists, shelves, `?minified=1`): `numFiles`, `size`, and media counts instead of files.
///
/// Personalized shelves may add `recentEpisode`, `numEpisodesIncomplete`, and `progressLastUpdate`;
/// series-filtered lists and the continue-series shelf add `series`, and lists requested with
/// `collapseseries=1` add `collapsedSeries`.
public struct LibraryItem: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let ino: String?
    public let oldLibraryItemId: String?
    public let libraryId: String
    public let folderId: String?
    public let path: String?
    public let relPath: String?
    public let isFile: Bool?
    /// Epoch milliseconds; may be fractional (file-system times).
    public let mtimeMs: Double?
    /// Epoch milliseconds; may be fractional (file-system times).
    public let ctimeMs: Double?
    /// Epoch milliseconds; may be fractional (file-system times).
    public let birthtimeMs: Double?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    /// Epoch milliseconds.
    public let lastScan: Int?
    public let scanVersion: String?
    public let isMissing: Bool
    public let isInvalid: Bool
    public let mediaType: MediaType
    /// `nil` when the media type is unknown to this client. Such items re-encode without `media`.
    public let media: LibraryItemMedia?
    public let libraryFiles: [LibraryFile]?
    public let numFiles: Int?
    /// Bytes.
    public let size: Int?
    public let recentEpisode: PodcastEpisode?
    public let numEpisodesIncomplete: Int?
    /// Epoch milliseconds.
    public let progressLastUpdate: Int?
    /// The series this item is listed under, with the item's `sequence`.
    public let series: Series?
    /// Set when this item stands in for a collapsed series.
    public let collapsedSeries: CollapsedSeries?

    public init(
        id: String, ino: String? = nil, oldLibraryItemId: String? = nil, libraryId: String, folderId: String? = nil,
        path: String? = nil, relPath: String? = nil, isFile: Bool? = nil, mtimeMs: Double? = nil,
        ctimeMs: Double? = nil,
        birthtimeMs: Double? = nil, addedAt: Int? = nil, updatedAt: Int? = nil, lastScan: Int? = nil,
        scanVersion: String? = nil, isMissing: Bool = false, isInvalid: Bool = false, mediaType: MediaType,
        media: LibraryItemMedia? = nil, libraryFiles: [LibraryFile]? = nil, numFiles: Int? = nil, size: Int? = nil,
        recentEpisode: PodcastEpisode? = nil, numEpisodesIncomplete: Int? = nil, progressLastUpdate: Int? = nil,
        series: Series? = nil, collapsedSeries: CollapsedSeries? = nil
    ) {
        self.id = id
        self.ino = ino
        self.oldLibraryItemId = oldLibraryItemId
        self.libraryId = libraryId
        self.folderId = folderId
        self.path = path
        self.relPath = relPath
        self.isFile = isFile
        self.mtimeMs = mtimeMs
        self.ctimeMs = ctimeMs
        self.birthtimeMs = birthtimeMs
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.lastScan = lastScan
        self.scanVersion = scanVersion
        self.isMissing = isMissing
        self.isInvalid = isInvalid
        self.mediaType = mediaType
        self.media = media
        self.libraryFiles = libraryFiles
        self.numFiles = numFiles
        self.size = size
        self.recentEpisode = recentEpisode
        self.numEpisodesIncomplete = numEpisodesIncomplete
        self.progressLastUpdate = progressLastUpdate
        self.series = series
        self.collapsedSeries = collapsedSeries
    }

    enum CodingKeys: String, CodingKey {
        case id, ino, oldLibraryItemId, libraryId, folderId, path, relPath, isFile
        case mtimeMs, ctimeMs, birthtimeMs, addedAt, updatedAt, lastScan, scanVersion
        case isMissing, isInvalid, mediaType, media, libraryFiles, numFiles, size
        case recentEpisode, numEpisodesIncomplete, progressLastUpdate, series, collapsedSeries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ino = try container.decodeIfPresent(String.self, forKey: .ino)
        oldLibraryItemId = try container.decodeIfPresent(String.self, forKey: .oldLibraryItemId)
        libraryId = try container.decode(String.self, forKey: .libraryId)
        folderId = try container.decodeIfPresent(String.self, forKey: .folderId)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        relPath = try container.decodeIfPresent(String.self, forKey: .relPath)
        isFile = try container.decodeIfPresent(Bool.self, forKey: .isFile)
        mtimeMs = try container.decodeIfPresent(Double.self, forKey: .mtimeMs)
        ctimeMs = try container.decodeIfPresent(Double.self, forKey: .ctimeMs)
        birthtimeMs = try container.decodeIfPresent(Double.self, forKey: .birthtimeMs)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        lastScan = try container.decodeIfPresent(Int.self, forKey: .lastScan)
        scanVersion = try container.decodeIfPresent(String.self, forKey: .scanVersion)
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        isInvalid = try container.decodeIfPresent(Bool.self, forKey: .isInvalid) ?? false
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        if container.contains(.media), try !container.decodeNil(forKey: .media) {
            media = try LibraryItemMedia(from: container.superDecoder(forKey: .media), mediaType: mediaType)
        } else {
            media = nil
        }
        libraryFiles = try container.decodeIfPresent([LibraryFile].self, forKey: .libraryFiles)
        numFiles = try container.decodeIfPresent(Int.self, forKey: .numFiles)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        recentEpisode = try container.decodeIfPresent(PodcastEpisode.self, forKey: .recentEpisode)
        numEpisodesIncomplete = try container.decodeIfPresent(Int.self, forKey: .numEpisodesIncomplete)
        progressLastUpdate = try container.decodeIfPresent(Int.self, forKey: .progressLastUpdate)
        series = try container.decodeIfPresent(Series.self, forKey: .series)
        collapsedSeries = try container.decodeIfPresent(CollapsedSeries.self, forKey: .collapsedSeries)
    }

    public var book: Book? {
        if case .book(let book) = media { book } else { nil }
    }

    public var podcast: Podcast? {
        if case .podcast(let podcast) = media { podcast } else { nil }
    }
}

/// A series shown as a single item in a list requested with `collapseseries=1`.
public struct CollapsedSeries: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let nameIgnorePrefix: String?
    /// The sequence of the item standing in for the series, when the list is filtered by series.
    public let sequence: String?
    public let numBooks: Int?
    public let libraryItemIds: [String]?

    public init(
        id: String, name: String, nameIgnorePrefix: String? = nil, sequence: String? = nil, numBooks: Int? = nil,
        libraryItemIds: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.nameIgnorePrefix = nameIgnorePrefix
        self.sequence = sequence
        self.numBooks = numBooks
        self.libraryItemIds = libraryItemIds
    }
}

/// A file in a library item's folder.
public struct LibraryFile: Sendable, Hashable, Codable, Identifiable {
    public let ino: String
    public let metadata: FileMetadata?
    public let isSupplementary: Bool?
    /// For example `audio`, `ebook`, `image`, or `metadata`.
    public let fileType: String?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?

    public init(
        ino: String, metadata: FileMetadata? = nil, isSupplementary: Bool? = nil, fileType: String? = nil,
        addedAt: Int? = nil, updatedAt: Int? = nil
    ) {
        self.ino = ino
        self.metadata = metadata
        self.isSupplementary = isSupplementary
        self.fileType = fileType
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public var id: String { ino }
}

/// File-system metadata for a file on the server.
public struct FileMetadata: Sendable, Hashable, Codable, Identifiable {
    public let filename: String
    public let ext: String?
    public let path: String
    public let relPath: String?
    /// Bytes.
    public let size: Int?
    /// Epoch milliseconds; may be fractional (file-system times).
    public let mtimeMs: Double?
    /// Epoch milliseconds; may be fractional (file-system times).
    public let ctimeMs: Double?
    /// Epoch milliseconds; may be fractional (file-system times).
    public let birthtimeMs: Double?

    public init(
        filename: String, ext: String? = nil, path: String, relPath: String? = nil, size: Int? = nil,
        mtimeMs: Double? = nil, ctimeMs: Double? = nil, birthtimeMs: Double? = nil
    ) {
        self.filename = filename
        self.ext = ext
        self.path = path
        self.relPath = relPath
        self.size = size
        self.mtimeMs = mtimeMs
        self.ctimeMs = ctimeMs
        self.birthtimeMs = birthtimeMs
    }

    public var id: String { path }
}
