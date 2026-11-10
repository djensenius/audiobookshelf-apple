import Foundation

/// One playback history entry (`PlaybackHistoryEvent`) as a `Sendable` value.
public struct PlaybackHistoryEventDTO: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Kept for display after the connection is deleted.
    public var serverConnectionID: UUID?
    public var mediaKey: MediaKey
    public var mediaDisplayTitle: String
    public var name: PlaybackHistoryEventName
    public var type: PlaybackHistoryEventType
    public var details: String?
    public var currentTime: Double?
    public var serverSyncAttempted: Bool
    public var serverSyncSuccess: Bool?
    public var serverSyncMessage: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        serverConnectionID: UUID?,
        mediaKey: MediaKey,
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
        self.mediaDisplayTitle = mediaDisplayTitle
        self.name = name
        self.type = type
        self.details = details
        self.currentTime = currentTime
        self.serverSyncAttempted = serverSyncAttempted
        self.serverSyncSuccess = serverSyncSuccess
        self.serverSyncMessage = serverSyncMessage
        self.timestamp = timestamp
    }
}

extension PlaybackHistoryEventDTO {
    /// `nil` for a row whose stored key or enum values don't parse; only
    /// `PlaybackHistoryStore` writes them, always from typed values.
    init?(_ event: PlaybackHistoryEvent) {
        guard let mediaKey = MediaKey(rawValue: event.mediaKey),
            let name = event.nameValue,
            let type = event.typeValue
        else { return nil }
        self.init(
            id: event.id,
            serverConnectionID: event.serverConnectionID,
            mediaKey: mediaKey,
            mediaDisplayTitle: event.mediaDisplayTitle,
            name: name,
            type: type,
            details: event.details,
            currentTime: event.currentTime,
            serverSyncAttempted: event.serverSyncAttempted,
            serverSyncSuccess: event.serverSyncSuccess,
            serverSyncMessage: event.serverSyncMessage,
            timestamp: event.timestamp
        )
    }

    /// Copies every field except `id` into `event`.
    func apply(to event: PlaybackHistoryEvent) {
        event.serverConnectionID = serverConnectionID
        event.mediaKey = mediaKey.rawValue
        event.libraryItemId = mediaKey.libraryItemId
        event.episodeId = mediaKey.episodeId
        event.mediaDisplayTitle = mediaDisplayTitle
        event.name = name.rawValue
        event.type = type.rawValue
        event.details = details
        event.currentTime = currentTime
        event.serverSyncAttempted = serverSyncAttempted
        event.serverSyncSuccess = serverSyncSuccess
        event.serverSyncMessage = serverSyncMessage
        event.timestamp = timestamp
    }
}
