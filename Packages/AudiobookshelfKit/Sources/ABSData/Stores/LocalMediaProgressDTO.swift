import ABSCore
import Foundation

/// Progress for one media item (`LocalMediaProgress`) as a `Sendable` value.
public struct LocalMediaProgressDTO: Sendable, Equatable, Identifiable {
    public var key: MediaKey
    public var localLibraryItemID: UUID?
    public var duration: Double
    public var progress: Double
    public var currentTime: Double
    public var isFinished: Bool
    public var ebookLocation: String?
    public var ebookProgress: Double?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The latest change, for display and ordering only.
    public var lastUpdate: Date
    public var audioDirty: Bool
    public var finishedDirty: Bool
    public var ebookDirty: Bool
    public var audioEditedAt: Date?
    public var finishedEditedAt: Date?
    public var ebookEditedAt: Date?
    public var serverBaseline: ProgressBaseline?
    public var unacknowledgedSends: [ProgressSend]
    public var audioHistoryTruncated: Bool
    public var finishedHistoryTruncated: Bool
    public var ebookHistoryTruncated: Bool
    public var needsServerSync: Bool
    public var lastSyncAttemptAt: Date?
    public var lastSyncError: String?

    public var id: MediaKey { key }

    /// The dirty groups.
    public var dirtyGroups: ProgressGroups {
        var groups: ProgressGroups = []
        if audioDirty { groups.insert(.audio) }
        if finishedDirty { groups.insert(.finished) }
        if ebookDirty { groups.insert(.ebook) }
        return groups
    }

    /// The values a PATCH would send now: only the dirty groups, each with its edit time.
    public var dirtyValues: ProgressSend { ProgressSyncState(self).dirtyValues }

    /// When the audio position was saved, for comparing it with progress from elsewhere: its edit
    /// time while unsent, else the later of that and the server baseline's `lastUpdate` (a merge
    /// keeps the old edit time). `nil` when the row holds no audio position, such as an ebook-only
    /// row, whose `currentTime` is only the default 0. `lastUpdate` is not that: ebook edits move it.
    public var audioSavedAt: Date? { ProgressSyncState(self).savedAt(.audio) }

    /// When `isFinished` was saved, dated like ``audioSavedAt``; `nil` when it never was.
    public var finishedSavedAt: Date? { ProgressSyncState(self).savedAt(.finished) }
}

extension LocalMediaProgressDTO {
    init(_ row: LocalMediaProgress) {
        key = MediaKey(
            serverConnectionID: row.serverConnectionID, libraryItemId: row.libraryItemId, episodeId: row.episodeId)
        localLibraryItemID = row.localLibraryItemID
        duration = row.duration
        progress = row.progress
        currentTime = row.currentTime
        isFinished = row.isFinished
        ebookLocation = row.ebookLocation
        ebookProgress = row.ebookProgress
        startedAt = row.startedAt
        finishedAt = row.finishedAt
        lastUpdate = row.lastUpdate
        audioDirty = row.audioDirty
        finishedDirty = row.finishedDirty
        ebookDirty = row.ebookDirty
        audioEditedAt = row.audioEditedAt
        finishedEditedAt = row.finishedEditedAt
        ebookEditedAt = row.ebookEditedAt
        serverBaseline = row.serverBaseline
        unacknowledgedSends = row.unacknowledgedSends
        audioHistoryTruncated = row.audioHistoryTruncated
        finishedHistoryTruncated = row.finishedHistoryTruncated
        ebookHistoryTruncated = row.ebookHistoryTruncated
        needsServerSync = row.needsServerSync
        lastSyncAttemptAt = row.lastSyncAttemptAt
        lastSyncError = row.lastSyncError
    }
}

extension ProgressSyncState {
    init(_ dto: LocalMediaProgressDTO) {
        self.init(lastUpdate: dto.lastUpdate)
        currentTime = dto.currentTime
        progress = dto.progress
        duration = dto.duration
        isFinished = dto.isFinished
        finishedAt = dto.finishedAt
        ebookLocation = dto.ebookLocation
        ebookProgress = dto.ebookProgress
        dirty = dto.dirtyGroups
        audioEditedAt = dto.audioEditedAt
        finishedEditedAt = dto.finishedEditedAt
        ebookEditedAt = dto.ebookEditedAt
        serverBaseline = dto.serverBaseline
        unacknowledgedSends = dto.unacknowledgedSends
        if dto.audioHistoryTruncated { truncated.insert(.audio) }
        if dto.finishedHistoryTruncated { truncated.insert(.finished) }
        if dto.ebookHistoryTruncated { truncated.insert(.ebook) }
    }

    init(_ row: LocalMediaProgress) {
        self.init(LocalMediaProgressDTO(row))
    }

    /// Writes the state back to `row`, keeping `needsServerSync` equal to "any group is dirty".
    func write(to row: LocalMediaProgress) {
        row.currentTime = currentTime
        row.progress = progress
        row.duration = duration
        row.isFinished = isFinished
        row.finishedAt = finishedAt
        row.ebookLocation = ebookLocation
        row.ebookProgress = ebookProgress
        row.lastUpdate = lastUpdate
        row.audioDirty = dirty.contains(.audio)
        row.finishedDirty = dirty.contains(.finished)
        row.ebookDirty = dirty.contains(.ebook)
        row.audioEditedAt = audioEditedAt
        row.finishedEditedAt = finishedEditedAt
        row.ebookEditedAt = ebookEditedAt
        row.serverBaseline = serverBaseline
        row.unacknowledgedSends = unacknowledgedSends
        row.audioHistoryTruncated = truncated.contains(.audio)
        row.finishedHistoryTruncated = truncated.contains(.finished)
        row.ebookHistoryTruncated = truncated.contains(.ebook)
        row.needsServerSync = !dirty.isEmpty
    }
}

/// A listening session waiting for upload (`PendingLocalSession`) as a `Sendable` value.
public struct PendingLocalSessionDTO: Sendable, Equatable, Identifiable {
    /// A client-generated UUID string, sent as the session id.
    public var id: String
    public var key: MediaKey
    public var userId: String
    public var mediaType: MediaType
    public var displayTitle: String
    public var displayAuthor: String?
    public var duration: Double
    public var playMethod: Int
    /// The media position when the session began.
    public var startTime: Double
    public var startedAt: Date
    public var updatedAt: Date
    public var timeListening: Double
    public var currentTime: Double
    public var isActive: Bool
    /// Read from the store; `LocalProgressStore.saveSession(_:)` ignores it.
    public var uploadAttempts: Int
    /// Read from the store; `LocalProgressStore.saveSession(_:)` ignores it.
    public var lastUploadError: String?

    public init(
        id: String = UUID().uuidString,
        key: MediaKey,
        userId: String,
        mediaType: MediaType,
        displayTitle: String,
        displayAuthor: String? = nil,
        duration: Double,
        playMethod: Int = PendingLocalSession.localPlayMethod,
        startTime: Double,
        startedAt: Date,
        updatedAt: Date,
        timeListening: Double = 0,
        currentTime: Double,
        isActive: Bool = true,
        uploadAttempts: Int = 0,
        lastUploadError: String? = nil
    ) {
        self.id = id
        self.key = key
        self.userId = userId
        self.mediaType = mediaType
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.duration = duration
        self.playMethod = playMethod
        self.startTime = startTime
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.timeListening = timeListening
        self.currentTime = currentTime
        self.isActive = isActive
        self.uploadAttempts = uploadAttempts
        self.lastUploadError = lastUploadError
    }
}

extension PendingLocalSessionDTO {
    init(_ session: PendingLocalSession) {
        self.init(
            id: session.id,
            key: MediaKey(
                serverConnectionID: session.serverConnectionID, libraryItemId: session.libraryItemId,
                episodeId: session.episodeId),
            userId: session.userId,
            mediaType: session.mediaTypeValue,
            displayTitle: session.displayTitle,
            displayAuthor: session.displayAuthor,
            duration: session.duration,
            playMethod: session.playMethod,
            startTime: session.startTime,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt,
            timeListening: session.timeListening,
            currentTime: session.currentTime,
            isActive: session.isActive,
            uploadAttempts: session.uploadAttempts,
            lastUploadError: session.lastUploadError
        )
    }

    /// Copies the session's data into `session`: every field except `id`, `uploadAttempts` and
    /// `lastUploadError`, which only `LocalProgressStore.settleSessionUpload` changes.
    func write(to session: PendingLocalSession) {
        session.serverConnectionID = key.serverConnectionID
        session.libraryItemId = key.libraryItemId
        session.episodeId = key.episodeId
        session.userId = userId
        session.mediaType = mediaType.rawValue
        session.displayTitle = displayTitle
        session.displayAuthor = displayAuthor
        session.duration = duration
        session.playMethod = playMethod
        session.startTime = startTime
        session.startedAt = startedAt
        session.updatedAt = updatedAt
        session.timeListening = timeListening
        session.currentTime = currentTime
        session.isActive = isActive
    }
}
