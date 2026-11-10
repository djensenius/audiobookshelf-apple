import ABSCore
import Foundation

/// The current user's listening statistics (legacy `pages/stats.vue`).
public enum StatsEndpoints {
    /// `GET /api/me/listening-stats`: totals, per-day times and the ten most recent sessions.
    public static func listeningStats() -> Endpoint<ListeningStatsResponse> {
        Endpoint(.get, "/api/me/listening-stats")
    }

    /// `GET /api/me`: the signed-in user with their complete `mediaProgress`, which the stats
    /// page counts finished items from.
    public static func currentUser() -> Endpoint<User> {
        Endpoint(.get, "/api/me")
    }
}
