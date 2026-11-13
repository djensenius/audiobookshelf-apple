import ABSCore
import Foundation

/// A download in progress (`DownloadRecord`) and its parts as a `Sendable` value.
public struct DownloadRecordDTO: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The media key of the downloaded item or episode; the record's natural key.
    public var key: MediaKey
    public var mediaType: MediaType
    public var title: String
    public var state: DownloadState
    /// The destination directory, relative to the downloads root.
    public var relativeDirectory: String
    public var createdAt: Date
    public var updatedAt: Date
    public var media: LocalMediaSnapshot
    /// Ordered by track index, then filename.
    public var parts: [DownloadPartDTO]

    public init(
        id: UUID = UUID(),
        key: MediaKey,
        mediaType: MediaType,
        title: String,
        state: DownloadState = .queued,
        relativeDirectory: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        media: LocalMediaSnapshot,
        parts: [DownloadPartDTO] = []
    ) {
        self.id = id
        self.key = key
        self.mediaType = mediaType
        self.title = title
        self.state = state
        self.relativeDirectory = relativeDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.media = media
        self.parts = parts
    }

    /// Whether every part finished, so the download can become a local item.
    public var isComplete: Bool { !parts.isEmpty && parts.allSatisfy { $0.state == .completed } }

    /// Whether the download only fetches the item's cover again, for a local item that lost it
    /// (`DownloadManager`); completed, it only sets the local item's cover
    /// (`LocalItemStore.upsertFromDownload(_:coverUpdatedAt:now:)`).
    public var isCoverOnly: Bool { !parts.isEmpty && parts.allSatisfy { $0.kind == .cover } }
}

/// One file of a download (`DownloadPart`) as a `Sendable` value.
public struct DownloadPartDTO: Sendable, Equatable, Identifiable {
    /// Also the `URLSessionTask.taskDescription`.
    public var id: UUID
    public var kind: DownloadPartKind
    /// The API path to fetch, without host or token. It may end in a `?query` (a cover's
    /// `width`, `format` and `ts`), never a credential.
    public var serverPath: String
    public var filename: String
    public var mimeType: String
    public var serverIno: String?
    public var trackIndex: Int?
    public var episodeId: String?
    public var expectedBytes: Int64
    public var bytesWritten: Int64
    /// The destination, relative to the downloads root.
    public var destinationRelativePath: String
    public var state: DownloadPartState
    /// A lookup cache only.
    public var taskIdentifier: Int?
    /// Whether a sealed resume-data blob exists outside the store.
    public var hasResumeData: Bool
    public var retryCount: Int
    public var lastError: String?
    /// The stable code of ``lastError``'s failure, a `DownloadFailureCode` raw value
    /// (`failureCode` in ABSDownloads), for a localised message; `nil` while there's none.
    public var lastErrorCode: String?

    public init(
        id: UUID = UUID(),
        kind: DownloadPartKind,
        serverPath: String,
        filename: String,
        mimeType: String,
        serverIno: String? = nil,
        trackIndex: Int? = nil,
        episodeId: String? = nil,
        expectedBytes: Int64 = 0,
        bytesWritten: Int64 = 0,
        destinationRelativePath: String,
        state: DownloadPartState = .queued,
        taskIdentifier: Int? = nil,
        hasResumeData: Bool = false,
        retryCount: Int = 0,
        lastError: String? = nil,
        lastErrorCode: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.serverPath = serverPath
        self.filename = filename
        self.mimeType = mimeType
        self.serverIno = serverIno
        self.trackIndex = trackIndex
        self.episodeId = episodeId
        self.expectedBytes = expectedBytes
        self.bytesWritten = bytesWritten
        self.destinationRelativePath = destinationRelativePath
        self.state = state
        self.taskIdentifier = taskIdentifier
        self.hasResumeData = hasResumeData
        self.retryCount = retryCount
        self.lastError = lastError
        self.lastErrorCode = lastErrorCode
    }
}

// Only `DownloadStore` writes the raw enum values, always from the typed enums, so the fallbacks
// below are never taken for rows it wrote.

extension DownloadRecordDTO {
    init(_ record: DownloadRecord) {
        self.init(
            id: record.id,
            key: MediaKey(
                serverConnectionID: record.serverConnectionID,
                libraryItemId: record.libraryItemId,
                episodeId: record.episodeId
            ),
            mediaType: record.mediaTypeValue,
            title: record.title,
            state: record.stateValue ?? .failed,
            relativeDirectory: record.relativeDirectory,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            media: record.media,
            parts: record.parts.map(DownloadPartDTO.init).sorted(by: DownloadPartDTO.precedes)
        )
    }
}

extension DownloadPartDTO {
    init(_ part: DownloadPart) {
        self.init(
            id: part.id,
            kind: part.kindValue ?? .audio,
            serverPath: part.serverPath,
            filename: part.filename,
            mimeType: part.mimeType,
            serverIno: part.serverIno,
            trackIndex: part.trackIndex,
            episodeId: part.episodeId,
            expectedBytes: part.expectedBytes,
            bytesWritten: part.bytesWritten,
            destinationRelativePath: part.destinationRelativePath,
            state: part.stateValue ?? .failed,
            taskIdentifier: part.taskIdentifier,
            hasResumeData: part.hasResumeData,
            retryCount: part.retryCount,
            lastError: part.lastError,
            lastErrorCode: part.lastErrorCode
        )
    }

    /// Copies every field except `id` into `part`.
    func apply(to part: DownloadPart) {
        part.kind = kind.rawValue
        part.serverPath = serverPath
        part.filename = filename
        part.mimeType = mimeType
        part.serverIno = serverIno
        part.trackIndex = trackIndex
        part.episodeId = episodeId
        part.expectedBytes = expectedBytes
        part.bytesWritten = bytesWritten
        part.destinationRelativePath = destinationRelativePath
        part.state = state.rawValue
        part.taskIdentifier = taskIdentifier
        part.hasResumeData = hasResumeData
        part.retryCount = retryCount
        part.lastError = lastError
        part.lastErrorCode = lastErrorCode
    }

    func makeModel() -> DownloadPart {
        DownloadPart(
            id: id,
            kind: kind,
            serverPath: serverPath,
            filename: filename,
            mimeType: mimeType,
            serverIno: serverIno,
            trackIndex: trackIndex,
            episodeId: episodeId,
            expectedBytes: expectedBytes,
            bytesWritten: bytesWritten,
            destinationRelativePath: destinationRelativePath,
            state: state,
            taskIdentifier: taskIdentifier,
            hasResumeData: hasResumeData,
            retryCount: retryCount,
            lastError: lastError,
            lastErrorCode: lastErrorCode
        )
    }

    /// Relationship arrays are unordered; parts sort by track index (untracked last), then
    /// filename.
    static func precedes(_ lhs: DownloadPartDTO, _ rhs: DownloadPartDTO) -> Bool {
        let left = lhs.trackIndex ?? .max
        let right = rhs.trackIndex ?? .max
        return left != right ? left < right : lhs.filename < rhs.filename
    }
}
