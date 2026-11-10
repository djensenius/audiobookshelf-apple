import ABSCore
import Foundation

/// The signed-in user.
public enum UserEndpoints {
    /// `GET /api/me`: the user with all their media progress and bookmarks.
    public static var me: Endpoint<User> {
        Endpoint(.get, "/api/me")
    }
}
