import ABSCore
import Foundation

/// The body of a `PATCH /api/me/progress` request: one field group, built with a factory, so
/// a sync sends only the group it changed (ADR 0003) and groups can't be mixed by accident.
/// Fields that are `nil` are left out of the JSON.
///
/// The server (`MediaProgress.applyProgressUpdate`) makes the groups interact:
/// - After every PATCH it re-evaluates auto-finish: progress that isn't finished becomes
///   finished when `duration - currentTime < 10` s. So an audio update near the end finishes
///   the item, and so can any other PATCH when the stored time is already near the end.
/// - An audio update that changes `currentTime` on finished progress un-finishes it unless the
///   new time is near the end.
/// - Any change to `currentTime` resets `hideFromContinueListening` to `false`.
/// - `isFinished: false` on finished progress resets `currentTime` and `progress` to 0.
/// - When `isFinished` is present, `progress` is ignored, so mixing them loses `progress`;
///   `{isFinished: true, currentTime}` with a time far from the end is un-finished again.
///
/// ADR 0003 sync must therefore send the audio and finished groups as separate, sequential
/// PATCHes, audio first and then finished, and expect the server to auto-finish or un-finish
/// in response; read the result back (`user_updated` or ``APIClient/mediaProgress(itemID:episodeID:)``)
/// rather than assuming the sent values stuck.
///
/// `lastUpdate` and the `markAsFinishedTimeRemaining` / `markAsFinishedPercentComplete`
/// thresholds are deliberately not sent: the server's clock and its default 10 s rule apply.
public struct MediaProgressUpdate: Encodable, Sendable, Hashable {
    /// Seconds.
    public let currentTime: Double?
    /// Seconds.
    public let duration: Double?
    /// `0...1`.
    public let progress: Double?
    public let isFinished: Bool?
    /// Epoch milliseconds, like ``MediaProgress/finishedAt``. Only sent with `isFinished: true`.
    public let finishedAt: Int?
    /// EPUB CFI or page reference, depending on the ebook format.
    public let ebookLocation: String?
    /// `0...1`.
    public let ebookProgress: Double?
    public let hideFromContinueListening: Bool?

    private init(
        currentTime: Double? = nil, duration: Double? = nil, progress: Double? = nil, isFinished: Bool? = nil,
        finishedAt: Int? = nil, ebookLocation: String? = nil, ebookProgress: Double? = nil,
        hideFromContinueListening: Bool? = nil
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.progress = progress
        self.isFinished = isFinished
        self.finishedAt = finishedAt
        self.ebookLocation = ebookLocation
        self.ebookProgress = ebookProgress
        self.hideFromContinueListening = hideFromContinueListening
    }

    /// The audio group. All three are required: the server stores `progress` as given rather
    /// than deriving it, and needs `duration` for auto-finish.
    public static func audio(currentTime: Double, duration: Double, progress: Double) -> Self {
        Self(currentTime: currentTime, duration: duration, progress: progress)
    }

    /// The finished group. `date` is when the item was finished (the server uses
    /// `finishedAt || Date.now()`); it is ignored when `isFinished` is `false`.
    public static func finished(_ isFinished: Bool, at date: Date? = nil) -> Self {
        let finishedAt = isFinished ? date.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } : nil
        return Self(isFinished: isFinished, finishedAt: finishedAt)
    }

    /// The ebook group.
    public static func ebook(location: String, progress: Double) -> Self {
        Self(ebookLocation: location, ebookProgress: progress)
    }

    /// Hides or shows the item in Continue Listening without touching progress.
    public static func hideFromContinueListening(_ hide: Bool) -> Self {
        Self(hideFromContinueListening: hide)
    }
}

/// The current user's media progress.
public enum ProgressEndpoints {
    /// `GET /api/me/progress/:itemID[/:episodeID]`. The server answers 404 when there is no
    /// progress; ``APIClient/mediaProgress(itemID:episodeID:)`` returns `nil` for that.
    public static func progress(itemID: String, episodeID: String? = nil) -> Endpoint<MediaProgress> {
        Endpoint(.get, path(itemID: itemID, episodeID: episodeID))
    }

    /// `PATCH /api/me/progress/:itemID[/:episodeID]`: creates or updates the progress. The
    /// server answers `OK`; the new progress arrives through `user_updated`.
    public static func update(
        itemID: String, episodeID: String? = nil, _ update: MediaProgressUpdate
    ) -> Endpoint<EmptyResponse> {
        Endpoint(.patch, path(itemID: itemID, episodeID: episodeID), body: update)
    }

    /// `DELETE /api/me/progress/:id`, where `id` is ``MediaProgress/id``, not an item ID.
    public static func delete(id: String) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "/api/me/progress/\(pathSegment(id))")
    }

    /// An empty episode ID counts as none, like ``MediaProgress/key(libraryItemID:episodeID:)``.
    static func path(itemID: String, episodeID: String?) -> String {
        var path = "/api/me/progress/\(pathSegment(itemID))"
        if let episodeID, !episodeID.isEmpty { path += "/\(pathSegment(episodeID))" }
        return path
    }
}

extension APIClient {
    /// The user's progress on an item or episode, or `nil` if there is none (a 404).
    public func mediaProgress(itemID: String, episodeID: String? = nil) async throws -> MediaProgress? {
        do {
            return try await send(ProgressEndpoints.progress(itemID: itemID, episodeID: episodeID))
        } catch APIError.notFound {
            return nil
        }
    }
}
