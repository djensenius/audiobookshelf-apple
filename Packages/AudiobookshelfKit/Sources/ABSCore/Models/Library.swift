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

    public init(
        id: String, name: String, folders: [LibraryFolder]? = nil, displayOrder: Int? = nil, icon: String? = nil,
        mediaType: MediaType, provider: String? = nil, settings: LibrarySettings? = nil, lastScan: Int? = nil,
        lastScanVersion: String? = nil, createdAt: Int? = nil, lastUpdate: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.folders = folders
        self.displayOrder = displayOrder
        self.icon = icon
        self.mediaType = mediaType
        self.provider = provider
        self.settings = settings
        self.lastScan = lastScan
        self.lastScanVersion = lastScanVersion
        self.createdAt = createdAt
        self.lastUpdate = lastUpdate
    }
}

public struct LibraryFolder: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let fullPath: String
    public let libraryId: String?
    /// Epoch milliseconds.
    public let addedAt: Int?

    public init(id: String, fullPath: String, libraryId: String? = nil, addedAt: Int? = nil) {
        self.id = id
        self.fullPath = fullPath
        self.libraryId = libraryId
        self.addedAt = addedAt
    }
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

    public init(
        coverAspectRatio: Int? = nil, disableWatcher: Bool? = nil, skipMatchingMediaWithAsin: Bool? = nil,
        skipMatchingMediaWithIsbn: Bool? = nil, autoScanCronExpression: String? = nil, audiobooksOnly: Bool? = nil,
        epubsAllowScriptedContent: Bool? = nil, hideSingleBookSeries: Bool? = nil,
        onlyShowLaterBooksInContinueSeries: Bool? = nil, metadataPrecedence: [String]? = nil,
        podcastSearchRegion: String? = nil, markAsFinishedPercentComplete: Double? = nil,
        markAsFinishedTimeRemaining: Double? = nil
    ) {
        self.coverAspectRatio = coverAspectRatio
        self.disableWatcher = disableWatcher
        self.skipMatchingMediaWithAsin = skipMatchingMediaWithAsin
        self.skipMatchingMediaWithIsbn = skipMatchingMediaWithIsbn
        self.autoScanCronExpression = autoScanCronExpression
        self.audiobooksOnly = audiobooksOnly
        self.epubsAllowScriptedContent = epubsAllowScriptedContent
        self.hideSingleBookSeries = hideSingleBookSeries
        self.onlyShowLaterBooksInContinueSeries = onlyShowLaterBooksInContinueSeries
        self.metadataPrecedence = metadataPrecedence
        self.podcastSearchRegion = podcastSearchRegion
        self.markAsFinishedPercentComplete = markAsFinishedPercentComplete
        self.markAsFinishedTimeRemaining = markAsFinishedTimeRemaining
    }
}
