import ABSAPI
import ABSCore
import Foundation

/// The server calls ``EbookProgressModel`` makes, over one connection.
public protocol EbookProgressService: Sendable {
    /// `PATCH /api/me/progress/:itemID[/:episodeID]` with one field group. Must return only once
    /// the request's task has completed (ADR 0007).
    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws
    /// `GET /api/me/progress/:itemID[/:episodeID]`; `nil` when the server has none (404).
    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress?
}

/// Uses `ProgressEndpoints` through the existing `writeProgress` and `mediaProgress` helpers.
extension APIClient: EbookProgressService {}
