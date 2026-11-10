import ABSCore
import Foundation

/// A downloaded library item (`LocalLibraryItem`) with its files as a `Sendable` value.
public struct LocalLibraryItemDTO: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var serverConnectionID: UUID
    public var serverAddress: String
    public var serverUserId: String
    public var libraryItemId: String
    public var mediaType: MediaType
    public var title: String
    public var authorName: String?
    /// The item's directory, relative to the downloads root.
    public var relativeDirectory: String
    public var coverRelativePath: String?
    public var coverUpdatedAt: Date?
    public var addedAt: Date
    public var updatedAt: Date
    public var media: LocalMediaSnapshot
    /// Ordered by track index (untracked last), then relative path.
    public var files: [LocalFileDTO]

    public init(
        id: UUID,
        serverConnectionID: UUID,
        serverAddress: String,
        serverUserId: String,
        libraryItemId: String,
        mediaType: MediaType,
        title: String,
        authorName: String? = nil,
        relativeDirectory: String,
        coverRelativePath: String? = nil,
        coverUpdatedAt: Date? = nil,
        addedAt: Date,
        updatedAt: Date,
        media: LocalMediaSnapshot,
        files: [LocalFileDTO] = []
    ) {
        self.id = id
        self.serverConnectionID = serverConnectionID
        self.serverAddress = serverAddress
        self.serverUserId = serverUserId
        self.libraryItemId = libraryItemId
        self.mediaType = mediaType
        self.title = title
        self.authorName = authorName
        self.relativeDirectory = relativeDirectory
        self.coverRelativePath = coverRelativePath
        self.coverUpdatedAt = coverUpdatedAt
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.media = media
        self.files = files
    }
}

/// A downloaded file (`LocalFile`) as a `Sendable` value.
public struct LocalFileDTO: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: LocalFileKind
    /// The file's path, relative to the downloads root.
    public var relativePath: String
    public var filename: String
    public var mimeType: String
    public var size: Int64
    public var serverIno: String?
    public var trackIndex: Int?
    public var episodeId: String?

    public init(
        id: UUID = UUID(),
        kind: LocalFileKind,
        relativePath: String,
        filename: String,
        mimeType: String,
        size: Int64,
        serverIno: String? = nil,
        trackIndex: Int? = nil,
        episodeId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.serverIno = serverIno
        self.trackIndex = trackIndex
        self.episodeId = episodeId
    }
}

extension LocalLibraryItemDTO {
    init(_ item: LocalLibraryItem) {
        self.init(
            id: item.id,
            serverConnectionID: item.serverConnectionID,
            serverAddress: item.serverAddress,
            serverUserId: item.serverUserId,
            libraryItemId: item.libraryItemId,
            mediaType: item.mediaTypeValue,
            title: item.title,
            authorName: item.authorName,
            relativeDirectory: item.relativeDirectory,
            coverRelativePath: item.coverRelativePath,
            coverUpdatedAt: item.coverUpdatedAt,
            addedAt: item.addedAt,
            updatedAt: item.updatedAt,
            media: item.media,
            files: item.files.map(LocalFileDTO.init).sorted { lhs, rhs in
                let left = lhs.trackIndex ?? .max
                let right = rhs.trackIndex ?? .max
                return left != right ? left < right : lhs.relativePath < rhs.relativePath
            }
        )
    }
}

extension LocalFileDTO {
    init(_ file: LocalFile) {
        self.init(
            id: file.id,
            // Only `LocalItemStore` writes the raw value, always from a `LocalFileKind`.
            kind: file.kindValue ?? .audio,
            relativePath: file.relativePath,
            filename: file.filename,
            mimeType: file.mimeType,
            size: file.size,
            serverIno: file.serverIno,
            trackIndex: file.trackIndex,
            episodeId: file.episodeId
        )
    }
}
