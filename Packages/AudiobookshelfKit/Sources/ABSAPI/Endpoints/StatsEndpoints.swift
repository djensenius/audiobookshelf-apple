import ABSCore
import Foundation

/// The current user's listening statistics (legacy `pages/stats.vue`).
public enum StatsEndpoints {
    /// `GET /api/me/listening-stats`: totals, per-day times and the ten most recent sessions.
    public static func listeningStats() -> Endpoint<ListeningStatsResponse> {
        Endpoint(.get, "/api/me/listening-stats")
    }

    /// `GET /api/me`, decoded only for the finished flags of the complete `mediaProgress`, which
    /// the stats page counts finished items from.
    public static func finishedProgress() -> Endpoint<FinishedProgressResponse> {
        Endpoint(.get, "/api/me")
    }
}
