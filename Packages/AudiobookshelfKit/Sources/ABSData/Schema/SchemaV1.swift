import ABSCore
import Foundation
import SwiftData

/// Version 1 of the on-device store (ADR 0003).
///
/// Editable until the first TestFlight build that creates a store ships. After that this file is
/// frozen: any change to a stored property, attribute option, relationship, `#Unique` or `#Index`
/// adds `SchemaV2` (a full copy of the models) and a stage in ``ABSMigrationPlan``. Code outside
/// `ABSData/Schema/` uses the module-level typealiases, never `SchemaV1.<Model>` directly.
///
/// Rules: fields in a `#Unique` are never optional (`#Unique` treats `nil` as distinct);
/// enumerations are raw `String`s with a typed accessor; instants are `Date`; positions and
/// durations are `Double` seconds; file locations are paths relative to the downloads root.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            ServerConnectionRecord.self,
            LocalLibraryItem.self,
            LocalFile.self,
            LocalMediaProgress.self,
            DownloadRecord.self,
            DownloadPart.self,
            PendingLocalSession.self,
            PlaybackHistoryEvent.self,
        ]
    }

    /// A saved server connection. Tokens and custom header values live in the Keychain, keyed
    /// by `id.uuidString`.
    @Model public final class ServerConnectionRecord {
        #Unique<ServerConnectionRecord>([\.id], [\.address, \.userId])
        #Index<ServerConnectionRecord>([\.lastUsedAt])

        public var id: UUID
        /// The normalized base URL, including any subpath, without a trailing `/`.
        public var address: String
        public var userId: String
        public var username: String
        /// A ``ServerAuthMethod`` raw value.
        public var authMethod: String
        public var serverVersion: String?
        public var createdAt: Date
        public var lastUsedAt: Date?
        public var isDisconnected: Bool
        public var disconnectedAt: Date?
        /// Set when the user signs out, before the Keychain session is deleted, and cleared when a
        /// sign-in saves a new one, so a session whose delete failed is never restored.
        public var signedOutAt: Date?

        public init(
            id: UUID = UUID(),
            address: String,
            userId: String,
            username: String,
            authMethod: ServerAuthMethod,
            serverVersion: String? = nil,
            createdAt: Date = .now,
            lastUsedAt: Date? = nil,
            isDisconnected: Bool = false,
            disconnectedAt: Date? = nil
        ) {
            self.id = id
            self.address = address
            self.userId = userId
            self.username = username
            self.authMethod = authMethod.rawValue
            self.serverVersion = serverVersion
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.isDisconnected = isDisconnected
            self.disconnectedAt = disconnectedAt
            signedOutAt = nil
        }

        public var authMethodValue: ServerAuthMethod? { ServerAuthMethod(rawValue: authMethod) }
    }

    /// A downloaded library item and its files.
    @Model public final class LocalLibraryItem {
        #Unique<LocalLibraryItem>([\.id], [\.serverConnectionID, \.libraryItemId])
        #Index<LocalLibraryItem>([\.libraryItemId], [\.serverConnectionID])

        public var id: UUID
        public var serverConnectionID: UUID
        public var serverAddress: String
        public var serverUserId: String
        public var libraryItemId: String
        /// A `MediaType` raw value.
        public var mediaType: String
        public var title: String
        public var authorName: String?
        /// The item's directory, relative to the downloads root.
        public var relativeDirectory: String
        public var coverRelativePath: String?
        /// The server's cover timestamp at download time (the item's `updatedAt` when there is
        /// no separate cover time); used by the image cache key and to refresh the cover.
        public var coverUpdatedAt: Date?
        public var addedAt: Date
        public var updatedAt: Date
        @Attribute(.codable) public var media: LocalMediaSnapshot
        @Relationship(deleteRule: .cascade, inverse: \LocalFile.item) public var files: [LocalFile]

        public init(
            id: UUID = UUID(),
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
            addedAt: Date = .now,
            updatedAt: Date = .now,
            media: LocalMediaSnapshot,
            files: [LocalFile] = []
        ) {
            self.id = id
            self.serverConnectionID = serverConnectionID
            self.serverAddress = serverAddress
            self.serverUserId = serverUserId
            self.libraryItemId = libraryItemId
            self.mediaType = mediaType.rawValue
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

        public var mediaTypeValue: MediaType { MediaType(rawValue: mediaType) }
    }

    /// A downloaded file belonging to a ``LocalLibraryItem``.
    @Model public final class LocalFile {
        #Unique<LocalFile>([\.id])

        public var id: UUID
        public var item: LocalLibraryItem?
        /// A ``LocalFileKind`` raw value.
        public var kind: String
        /// The file's path, relative to the downloads root.
        public var relativePath: String
        public var filename: String
        public var mimeType: String
        public var size: Int64
        public var serverIno: String?
        /// The book track this file plays, matching `LocalMediaSnapshot.AudioTrack.index`.
        public var trackIndex: Int?
        /// The podcast episode this file plays.
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
            self.kind = kind.rawValue
            self.relativePath = relativePath
            self.filename = filename
            self.mimeType = mimeType
            self.size = size
            self.serverIno = serverIno
            self.trackIndex = trackIndex
            self.episodeId = episodeId
        }

        public var kindValue: LocalFileKind? { LocalFileKind(rawValue: kind) }
    }

    /// Progress for one media item (book or podcast episode) that was played on this device or
    /// has changes the server hasn't acknowledged. Field groups (audio, finished, ebook) carry
    /// their own dirty flag and edit time; see ADR 0003 for the sync rules.
    @Model public final class LocalMediaProgress {
        #Unique<LocalMediaProgress>([\.key])
        #Index<LocalMediaProgress>(
            [\.needsServerSync], [\.serverConnectionID, \.libraryItemId], [\.localLibraryItemID])

        /// The media key: `"<serverConnectionID>|<libraryItemId>|<episodeId or empty>"`.
        public var key: String
        public var serverConnectionID: UUID
        public var libraryItemId: String
        public var episodeId: String?
        public var localLibraryItemID: UUID?
        public var duration: Double
        public var progress: Double
        public var currentTime: Double
        public var isFinished: Bool
        public var ebookLocation: String?
        public var ebookProgress: Double?
        public var startedAt: Date?
        public var finishedAt: Date?
        /// The latest change, for display and ordering only; never used for conflicts.
        public var lastUpdate: Date
        public var audioDirty: Bool
        public var finishedDirty: Bool
        public var ebookDirty: Bool
        public var audioEditedAt: Date?
        public var finishedEditedAt: Date?
        public var ebookEditedAt: Date?
        @Attribute(.codable) public var serverBaseline: ProgressBaseline?
        /// PATCHes whose outcome is unknown, oldest first, at most `ProgressSend.historyLimit`.
        @Attribute(.codable) public var unacknowledgedSends: [ProgressSend]
        /// Set per group when an entry carrying that group was dropped from
        /// `unacknowledgedSends`; an unmatched server value for the group then keeps the local one.
        public var audioHistoryTruncated: Bool = false
        public var finishedHistoryTruncated: Bool = false
        public var ebookHistoryTruncated: Bool = false
        /// True when any dirty flag is set; the indexed pending-sync query.
        public var needsServerSync: Bool
        public var lastSyncAttemptAt: Date?
        public var lastSyncError: String?

        public init(
            key: String,
            serverConnectionID: UUID,
            libraryItemId: String,
            episodeId: String? = nil,
            localLibraryItemID: UUID? = nil,
            duration: Double = 0,
            progress: Double = 0,
            currentTime: Double = 0,
            isFinished: Bool = false,
            ebookLocation: String? = nil,
            ebookProgress: Double? = nil,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            lastUpdate: Date = .now,
            audioDirty: Bool = false,
            finishedDirty: Bool = false,
            ebookDirty: Bool = false,
            audioEditedAt: Date? = nil,
            finishedEditedAt: Date? = nil,
            ebookEditedAt: Date? = nil,
            serverBaseline: ProgressBaseline? = nil,
            unacknowledgedSends: [ProgressSend] = [],
            audioHistoryTruncated: Bool = false,
            finishedHistoryTruncated: Bool = false,
            ebookHistoryTruncated: Bool = false,
            needsServerSync: Bool = false,
            lastSyncAttemptAt: Date? = nil,
            lastSyncError: String? = nil
        ) {
            self.key = key
            self.serverConnectionID = serverConnectionID
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.localLibraryItemID = localLibraryItemID
            self.duration = duration
            self.progress = progress
            self.currentTime = currentTime
            self.isFinished = isFinished
            self.ebookLocation = ebookLocation
            self.ebookProgress = ebookProgress
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.lastUpdate = lastUpdate
            self.audioDirty = audioDirty
            self.finishedDirty = finishedDirty
            self.ebookDirty = ebookDirty
            self.audioEditedAt = audioEditedAt
            self.finishedEditedAt = finishedEditedAt
            self.ebookEditedAt = ebookEditedAt
            self.serverBaseline = serverBaseline
            self.unacknowledgedSends = unacknowledgedSends
            self.audioHistoryTruncated = audioHistoryTruncated
            self.finishedHistoryTruncated = finishedHistoryTruncated
            self.ebookHistoryTruncated = ebookHistoryTruncated
            self.needsServerSync = needsServerSync
            self.lastSyncAttemptAt = lastSyncAttemptAt
            self.lastSyncError = lastSyncError
        }
    }

    /// A download in progress. When it completes it becomes a ``LocalLibraryItem`` and the
    /// record is deleted.
    @Model public final class DownloadRecord {
        #Unique<DownloadRecord>([\.id], [\.key])
        #Index<DownloadRecord>([\.state])

        public var id: UUID
        /// The media key of the downloaded item or episode.
        public var key: String
        public var serverConnectionID: UUID
        public var libraryItemId: String
        public var episodeId: String?
        /// A `MediaType` raw value.
        public var mediaType: String
        public var title: String
        /// A ``DownloadState`` raw value.
        public var state: String
        /// The destination directory, relative to the downloads root.
        public var relativeDirectory: String
        public var createdAt: Date
        public var updatedAt: Date
        @Attribute(.codable) public var media: LocalMediaSnapshot
        @Relationship(deleteRule: .cascade, inverse: \DownloadPart.record) public var parts: [DownloadPart]

        public init(
            id: UUID = UUID(),
            key: String,
            serverConnectionID: UUID,
            libraryItemId: String,
            episodeId: String? = nil,
            mediaType: MediaType,
            title: String,
            state: DownloadState = .queued,
            relativeDirectory: String,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            media: LocalMediaSnapshot,
            parts: [DownloadPart] = []
        ) {
            self.id = id
            self.key = key
            self.serverConnectionID = serverConnectionID
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.mediaType = mediaType.rawValue
            self.title = title
            self.state = state.rawValue
            self.relativeDirectory = relativeDirectory
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.media = media
            self.parts = parts
        }

        public var mediaTypeValue: MediaType { MediaType(rawValue: mediaType) }
        public var stateValue: DownloadState? { DownloadState(rawValue: state) }
    }

    /// One file of a ``DownloadRecord``. URLSession resume data is never stored here; only
    /// ``hasResumeData`` records that a sealed blob exists outside the store.
    @Model public final class DownloadPart {
        #Unique<DownloadPart>([\.id])
        #Index<DownloadPart>([\.taskIdentifier], [\.state])

        public var id: UUID
        public var record: DownloadRecord?
        /// A ``DownloadPartKind`` raw value.
        public var kind: String
        /// The API path to fetch, without host or token.
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
        /// A ``DownloadPartState`` raw value.
        public var state: String
        /// A lookup cache only; the task's `taskDescription` is the part's `id`.
        public var taskIdentifier: Int?
        public var hasResumeData: Bool
        public var retryCount: Int
        public var lastError: String?

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
            lastError: String? = nil
        ) {
            self.id = id
            self.kind = kind.rawValue
            self.serverPath = serverPath
            self.filename = filename
            self.mimeType = mimeType
            self.serverIno = serverIno
            self.trackIndex = trackIndex
            self.episodeId = episodeId
            self.expectedBytes = expectedBytes
            self.bytesWritten = bytesWritten
            self.destinationRelativePath = destinationRelativePath
            self.state = state.rawValue
            self.taskIdentifier = taskIdentifier
            self.hasResumeData = hasResumeData
            self.retryCount = retryCount
            self.lastError = lastError
        }

        public var kindValue: DownloadPartKind? { DownloadPartKind(rawValue: kind) }
        public var stateValue: DownloadPartState? { DownloadPartState(rawValue: state) }
    }

    /// A listening session recorded while playing a download, waiting for
    /// `POST /api/session/local-all`.
    @Model public final class PendingLocalSession {
        #Unique<PendingLocalSession>([\.id])
        #Index<PendingLocalSession>([\.serverConnectionID, \.isActive])

        /// A client-generated UUID string, sent as the session id.
        public var id: String
        public var serverConnectionID: UUID
        public var userId: String
        public var libraryItemId: String
        public var episodeId: String?
        /// A `MediaType` raw value.
        public var mediaType: String
        public var displayTitle: String
        public var displayAuthor: String?
        public var duration: Double
        /// The server's play method; 3 is local.
        public var playMethod: Int
        /// The media position when the session began.
        public var startTime: Double
        public var startedAt: Date
        public var updatedAt: Date
        public var timeListening: Double
        public var currentTime: Double
        public var isActive: Bool
        /// Failed upload results counted toward discarding the session, at most one per hour.
        public var uploadAttempts: Int
        public var lastUploadError: String?
        /// When a failure was last counted in ``uploadAttempts``.
        public var lastUploadFailureAt: Date?
        /// Consecutive uploads whose results didn't mention the session.
        public var missingUploadResults: Int = 0

        /// The server's `playMethod` for local playback.
        public static let localPlayMethod = 3

        public init(
            id: String = UUID().uuidString,
            serverConnectionID: UUID,
            userId: String,
            libraryItemId: String,
            episodeId: String? = nil,
            mediaType: MediaType,
            displayTitle: String,
            displayAuthor: String? = nil,
            duration: Double,
            playMethod: Int = PendingLocalSession.localPlayMethod,
            startTime: Double,
            startedAt: Date = .now,
            updatedAt: Date = .now,
            timeListening: Double = 0,
            currentTime: Double,
            isActive: Bool = true,
            uploadAttempts: Int = 0,
            lastUploadError: String? = nil,
            lastUploadFailureAt: Date? = nil,
            missingUploadResults: Int = 0
        ) {
            self.id = id
            self.serverConnectionID = serverConnectionID
            self.userId = userId
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.mediaType = mediaType.rawValue
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
            self.lastUploadFailureAt = lastUploadFailureAt
            self.missingUploadResults = missingUploadResults
        }

        public var mediaTypeValue: MediaType { MediaType(rawValue: mediaType) }
    }

    /// One entry in the per-item playback history, kept on the device only.
    @Model public final class PlaybackHistoryEvent {
        #Unique<PlaybackHistoryEvent>([\.id])
        #Index<PlaybackHistoryEvent>([\.mediaKey, \.timestamp])

        public var id: UUID
        /// Kept for display after the connection is deleted.
        public var serverConnectionID: UUID?
        public var mediaKey: String
        public var libraryItemId: String
        public var episodeId: String?
        public var mediaDisplayTitle: String
        /// A ``PlaybackHistoryEventName`` raw value.
        public var name: String
        /// A ``PlaybackHistoryEventType`` raw value.
        public var type: String
        public var details: String?
        public var currentTime: Double?
        public var serverSyncAttempted: Bool
        public var serverSyncSuccess: Bool?
        public var serverSyncMessage: String?
        public var timestamp: Date

        public init(
            id: UUID = UUID(),
            serverConnectionID: UUID?,
            mediaKey: String,
            libraryItemId: String,
            episodeId: String? = nil,
            mediaDisplayTitle: String,
            name: PlaybackHistoryEventName,
            type: PlaybackHistoryEventType,
            details: String? = nil,
            currentTime: Double? = nil,
            serverSyncAttempted: Bool = false,
            serverSyncSuccess: Bool? = nil,
            serverSyncMessage: String? = nil,
            timestamp: Date = .now
        ) {
            self.id = id
            self.serverConnectionID = serverConnectionID
            self.mediaKey = mediaKey
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.mediaDisplayTitle = mediaDisplayTitle
            self.name = name.rawValue
            self.type = type.rawValue
            self.details = details
            self.currentTime = currentTime
            self.serverSyncAttempted = serverSyncAttempted
            self.serverSyncSuccess = serverSyncSuccess
            self.serverSyncMessage = serverSyncMessage
            self.timestamp = timestamp
        }

        public var nameValue: PlaybackHistoryEventName? { PlaybackHistoryEventName(rawValue: name) }
        public var typeValue: PlaybackHistoryEventType? { PlaybackHistoryEventType(rawValue: type) }
    }
}
