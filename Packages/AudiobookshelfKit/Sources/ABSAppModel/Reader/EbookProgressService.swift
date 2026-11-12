import ABSAPI
import ABSCore
import ABSPlayback
import Foundation

/// The server read ``EbookProgressModel/resume()`` makes, over one connection.
public protocol EbookProgressService: Sendable {
    /// `GET /api/me/progress/:itemID[/:episodeID]`; `nil` when the server has none (404).
    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress?
}

/// Uses `ProgressEndpoints` through the existing `mediaProgress` helper.
extension APIClient: EbookProgressService {}

/// Sends the connection's dirty progress rows. ``EbookProgressModel`` saves locally and hands
/// sending to it, so ebook rows get the same fetch-merge before PATCH, confirmation lookup and
/// rejection handling (ADR 0003) as playback rows.
@MainActor
public protocol ProgressDraining: AnyObject {
    /// PATCHes dirty rows and returns when done (`ProgressSyncer.drainPendingProgress()`).
    func drainPendingProgress() async
}

extension ProgressSyncer: ProgressDraining {}
