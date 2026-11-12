import ABSCore
import Foundation

/// The current user.
public enum UserEndpoints {
    /// `GET /api/me`, decoded only for which media the user finished (picking a podcast's next
    /// episode). The full payload can be large, so nothing else is kept.
    public static func me() -> Endpoint<UserFinishedMediaResponse> {
        Endpoint(.get, "/api/me")
    }
}
