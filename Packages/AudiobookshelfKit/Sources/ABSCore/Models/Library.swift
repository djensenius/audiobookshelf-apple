import Foundation

public struct Library: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let folders: [LibraryFolder]?
    public let displayOrder: Int?
    public let icon: String?
    public let mediaType: MediaType
    public let provider: String?
    public let settings: LibrarySettings?
    /// Epoch milliseconds.
    public let lastScan: Int?
    public let lastScanVersion: String?
    /// Epoch milliseconds.
    public let createdAt: Int?
    /// Epoch milliseconds.
    public let lastUpdate: Int?
}

public struct LibraryFolder: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let fullPath: String
    public let libraryId: String?
    /// Epoch milliseconds.
    public let addedAt: Int?
}

public struct LibrarySettings: Sendable, Hashable, Codable {
    /// `0` for standard (1.6:1) covers, `1` for square covers.
    public let coverAspectRatio: Int?
    public let disableWatcher: Bool?
    public let skipMatchingMediaWithAsin: Bool?
    public let skipMatchingMediaWithIsbn: Bool?
    public let autoScanCronExpression: String?
    public let audiobooksOnly: Bool?
    public let epubsAllowScriptedContent: Bool?
    public let hideSingleBookSeries: Bool?
    public let onlyShowLaterBooksInContinueSeries: Bool?
    public let metadataPrecedence: [String]?
    public let podcastSearchRegion: String?
    public let markAsFinishedPercentComplete: Double?
    public let markAsFinishedTimeRemaining: Double?
}
