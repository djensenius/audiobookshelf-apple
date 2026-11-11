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

/// Bounded progress-send evidence: normally a PATCH, or explicitly marked session audio.
/// Carries the actual sent values and their originating `<group>EditedAt`. A nil group was
/// not sent; session audio must never be treated as a PATCH acknowledgement.
public struct ProgressSend: Codable, Sendable, Hashable {
    /// The most entries `LocalMediaProgress.unacknowledgedSends` keeps; when an older one is
    /// dropped, the `<group>HistoryTruncated` flag of each group it carried is set.
    public static let historyLimit = 8

    public var audio: Audio?
    public var finished: Finished?
    public var ebook: Ebook?
    /// Present only for an actual online session report, never a progress PATCH. Optional for
    /// legacy rows. Its audio edit is the originating committed edit, not a later equal value.
    public var sessionAudio: SessionAudio?

    public struct SessionAudio: Codable, Sendable, Hashable {
        public let attemptID: UUID
        public let sessionID: String
        /// Nil means prepared/unknown. Neither success nor ambiguity is a PATCH acknowledgement.
        public var outcome: Outcome?

        public enum Outcome: String, Codable, Sendable {
            case succeeded
            case ambiguous
        }

        public init(attemptID: UUID, sessionID: String, outcome: Outcome? = nil) {
            self.attemptID = attemptID
            self.sessionID = sessionID
            self.outcome = outcome
        }
    }

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
