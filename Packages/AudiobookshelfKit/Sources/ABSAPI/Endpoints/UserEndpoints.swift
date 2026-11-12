import ABSCore
import Foundation

/// The current user.
public enum UserEndpoints {
    /// `GET /api/me`, decoded only for which media the user finished (picking a podcast's next
    /// episode). The full payload can be large, so nothing else is kept.
    public static func me() -> Endpoint<UserFinishedMediaResponse> {
        Endpoint(.get, "/api/me")
    }

    /// `GET /api/me`, decoded for the user's full progress list (``UserProgressResponse``), the
    /// only list complete enough to seed the library's progress cache.
    public static func progress() -> Endpoint<UserProgressResponse> {
        Endpoint(.get, "/api/me")
    }

    /// `GET /api/me`, decoded only for the user's bookmarks.
    public static func meBookmarks() -> Endpoint<UserBookmarksResponse> {
        Endpoint(.get, "/api/me")
    }
}
