import ABSCore
import Foundation

/// The current user's listening statistics (legacy `pages/stats.vue`) and the year in review
/// (legacy `components/stats/YearInReview*.vue`).
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

    /// `GET /api/me`, decoded only for the user's account type, which decides whether the server
    /// year in review is offered.
    public static func userType() -> Endpoint<UserTypeResponse> {
        Endpoint(.get, "/api/me")
    }

    /// `GET /api/me/stats/year/:year`: the current user's year in review. The server answers
    /// 400 for a year outside 2000–9999.
    public static func userYearStats(year: Int) -> Endpoint<UserYearStats> {
        Endpoint(.get, "/api/me/stats/year/\(year)")
    }

    /// `GET /api/stats/year/:year`: the whole server's year in review. Admin and root users only;
    /// the server answers 403 to anyone else and 400 for a year outside 2000–9999.
    public static func serverYearStats(year: Int) -> Endpoint<ServerYearStats> {
        Endpoint(.get, "/api/stats/year/\(year)")
    }
}
