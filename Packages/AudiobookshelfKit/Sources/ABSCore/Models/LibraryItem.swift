import Foundation

/// A library item in any of the server's forms:
/// - full (`GET /api/items/:id`): `media` with files and `libraryFiles`;
/// - expanded (`?expanded=1`): also `size`, and media `tracks`, `duration`, `size`;
/// - minified (lists, shelves, `?minified=1`): `numFiles`, `size`, and media counts instead of files.
///
/// Personalized shelves may add `recentEpisode`, `numEpisodesIncomplete`, and `progressLastUpdate`.
public struct LibraryItem: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let ino: String?
    public let oldLibraryItemId: String?
    public let libraryId: String
    public let folderId: String?
    public let path: String?
    public let relPath: String?
    public let isFile: Bool?
    /// Epoch milliseconds.
    public let mtimeMs: Int?
    /// Epoch milliseconds.
    public let ctimeMs: Int?
    /// Epoch milliseconds.
    public let birthtimeMs: Int?
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
    /// `nil` when the media type is unknown to this client.
    public let media: LibraryItemMedia?
    public let libraryFiles: [LibraryFile]?
    public let numFiles: Int?
    /// Bytes.
    public let size: Int?
    public let recentEpisode: PodcastEpisode?
    public let numEpisodesIncomplete: Int?
    /// Epoch milliseconds.
    public let progressLastUpdate: Int?

    enum CodingKeys: String, CodingKey {
        case id, ino, oldLibraryItemId, libraryId, folderId, path, relPath, isFile
        case mtimeMs, ctimeMs, birthtimeMs, addedAt, updatedAt, lastScan, scanVersion
        case isMissing, isInvalid, mediaType, media, libraryFiles, numFiles, size
        case recentEpisode, numEpisodesIncomplete, progressLastUpdate
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
        mtimeMs = try container.decodeIfPresent(Int.self, forKey: .mtimeMs)
        ctimeMs = try container.decodeIfPresent(Int.self, forKey: .ctimeMs)
        birthtimeMs = try container.decodeIfPresent(Int.self, forKey: .birthtimeMs)
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
    }

    public var book: Book? {
        if case .book(let book) = media { book } else { nil }
    }

    public var podcast: Podcast? {
        if case .podcast(let podcast) = media { podcast } else { nil }
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
    /// Epoch milliseconds.
    public let mtimeMs: Int?
    /// Epoch milliseconds.
    public let ctimeMs: Int?
    /// Epoch milliseconds.
    public let birthtimeMs: Int?

    public var id: String { path }
}
