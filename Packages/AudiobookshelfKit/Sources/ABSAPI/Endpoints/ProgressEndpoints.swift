import ABSCore
import Foundation

/// The fields of a `PATCH /api/me/progress` request. Only non-`nil` fields are sent, so a
/// sync can send just the groups it changed: audio (`currentTime`, `progress`, `duration`),
/// finished (`isFinished`), and ebook (`ebookLocation`, `ebookProgress`).
///
/// The server applies the body with `MediaProgress.applyProgressUpdate`: `isFinished: false`
/// on finished progress also resets `currentTime` and `progress`, and changing `currentTime`
/// clears `hideFromContinueListening` unless the body sets it to `true`.
public struct MediaProgressUpdate: Encodable, Sendable, Hashable {
    /// Seconds.
    public var currentTime: Double?
    /// Seconds.
    public var duration: Double?
    /// `0...1`.
    public var progress: Double?
    public var isFinished: Bool?
    /// EPUB CFI or page reference, depending on the ebook format.
    public var ebookLocation: String?
    /// `0...1`.
    public var ebookProgress: Double?
    public var hideFromContinueListening: Bool?

    public init(
        currentTime: Double? = nil, duration: Double? = nil, progress: Double? = nil, isFinished: Bool? = nil,
        ebookLocation: String? = nil, ebookProgress: Double? = nil, hideFromContinueListening: Bool? = nil
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.progress = progress
        self.isFinished = isFinished
        self.ebookLocation = ebookLocation
        self.ebookProgress = ebookProgress
        self.hideFromContinueListening = hideFromContinueListening
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
