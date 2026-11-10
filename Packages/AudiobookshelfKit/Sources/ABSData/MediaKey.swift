import Foundation

/// Identifies one playable media item (a book, or a podcast episode) on one server connection.
///
/// ``rawValue`` is the stored key of `LocalMediaProgress`, `DownloadRecord` and
/// `PlaybackHistoryEvent`: `"<serverConnectionID>|<libraryItemId>|<episodeId or empty>"` (ADR 0003).
/// Always build keys with this type so every writer produces the same string.
public struct MediaKey: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    public var serverConnectionID: UUID
    public var libraryItemId: String
    public var episodeId: String?

    public init(serverConnectionID: UUID, libraryItemId: String, episodeId: String? = nil) {
        self.serverConnectionID = serverConnectionID
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId?.isEmpty == true ? nil : episodeId
    }

    /// Parses a stored key; `nil` when it doesn't have three `|`-separated parts or the first isn't
    /// a UUID.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let id = UUID(uuidString: String(parts[0])), !parts[1].isEmpty else { return nil }
        self.init(serverConnectionID: id, libraryItemId: String(parts[1]), episodeId: String(parts[2]))
    }

    public var rawValue: String {
        "\(serverConnectionID.uuidString)|\(libraryItemId)|\(episodeId ?? "")"
    }

    public var description: String { rawValue }
}
