import Foundation

// Sync bookkeeping stored as `.codable` attributes on `LocalMediaProgress` (ADR 0003). The
// same evolution rules as `LocalMediaSnapshot` apply: only add optional properties, never
// rename or retype a key.

/// The server's progress values for a media item as last seen or acknowledged.
public struct ProgressBaseline: Codable, Sendable, Hashable {
    public var currentTime: Double
    public var progress: Double
    public var duration: Double
    public var isFinished: Bool
    public var finishedAt: Date?
    public var ebookLocation: String?
    /// An unseeded PATCH omitted location: it is unknown until a server read, not known-null.
    /// Optional for existing stored baselines, which keep their original known-value semantics.
    public var ebookLocationIsUnknown: Bool?
    public var ebookProgress: Double?
    public var lastUpdate: Date

    public init(
        currentTime: Double,
        progress: Double,
        duration: Double,
        isFinished: Bool,
        finishedAt: Date? = nil,
        ebookLocation: String? = nil,
        ebookProgress: Double? = nil,
        lastUpdate: Date
    ) {
        self.currentTime = currentTime
        self.progress = progress
        self.duration = duration
        self.isFinished = isFinished
        self.finishedAt = finishedAt
        self.ebookLocation = ebookLocation
        self.ebookProgress = ebookProgress
        self.lastUpdate = lastUpdate
    }
}

/// A progress PATCH whose outcome is unknown: the values of the groups it sent and each
/// group's `<group>EditedAt` when the snapshot was taken. A `nil` group was not sent.
public struct ProgressSend: Codable, Sendable, Hashable {
    /// The most entries `LocalMediaProgress.unacknowledgedSends` keeps; when an older one is
    /// dropped, the `<group>HistoryTruncated` flag of each group it carried is set.
    public static let historyLimit = 8

    public var audio: Audio?
    public var finished: Finished?
    public var ebook: Ebook?

    public init(audio: Audio? = nil, finished: Finished? = nil, ebook: Ebook? = nil) {
        self.audio = audio
        self.finished = finished
        self.ebook = ebook
    }

    public struct Audio: Codable, Sendable, Hashable {
        public var currentTime: Double
        public var progress: Double
        public var duration: Double
        public var editedAt: Date

        public init(currentTime: Double, progress: Double, duration: Double, editedAt: Date) {
            self.currentTime = currentTime
            self.progress = progress
            self.duration = duration
            self.editedAt = editedAt
        }
    }

    public struct Finished: Codable, Sendable, Hashable {
        public var isFinished: Bool
        public var finishedAt: Date?
        public var editedAt: Date

        public init(isFinished: Bool, finishedAt: Date?, editedAt: Date) {
            self.isFinished = isFinished
            self.finishedAt = finishedAt
            self.editedAt = editedAt
        }
    }

    public struct Ebook: Codable, Sendable, Hashable {
        /// `nil` omits this field from PATCH, preserving the server's location; it does not clear it.
        public var ebookLocation: String?
        public var ebookProgress: Double?
        public var editedAt: Date

        public init(ebookLocation: String?, ebookProgress: Double?, editedAt: Date) {
            self.ebookLocation = ebookLocation
            self.ebookProgress = ebookProgress
            self.editedAt = editedAt
        }
    }
}
