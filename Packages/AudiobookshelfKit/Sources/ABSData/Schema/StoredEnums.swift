import Foundation

// Enumerations persisted as raw `String` values (ADR 0003). Models store the raw value so
// predicates stay simple and expose a typed computed accessor. The raw values are part
// of the stored schema: never rename them.

/// How a saved server connection authenticates.
public enum ServerAuthMethod: String, Sendable, Hashable, Codable, CaseIterable {
    case local
    case openid
}

/// What a downloaded `LocalFile` holds.
public enum LocalFileKind: String, Sendable, Hashable, Codable, CaseIterable {
    case audio
    case ebook
}

/// The state of a whole download.
public enum DownloadState: String, Sendable, Hashable, Codable, CaseIterable {
    case queued
    case downloading
    case paused
    case failed
}

/// What a `DownloadPart` fetches.
public enum DownloadPartKind: String, Sendable, Hashable, Codable, CaseIterable {
    case audio
    case ebook
    case cover
}

/// The state of one file in a download.
public enum DownloadPartState: String, Sendable, Hashable, Codable, CaseIterable {
    case queued
    case running
    case completed
    case failed
}

/// The event recorded by a `PlaybackHistoryEvent`, matching the legacy history page.
public enum PlaybackHistoryEventName: String, Sendable, Hashable, Codable, CaseIterable {
    case play = "Play"
    case pause = "Pause"
    case stop = "Stop"
    case seek = "Seek"
    case save = "Save"
    case finished = "Finished"
    case sync = "Sync"
}

/// The category of a `PlaybackHistoryEvent`.
public enum PlaybackHistoryEventType: String, Sendable, Hashable, Codable, CaseIterable {
    case playback = "Playback"
    case sync = "Sync"
}
