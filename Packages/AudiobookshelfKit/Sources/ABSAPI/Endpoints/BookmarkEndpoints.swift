import ABSCore
import Foundation

/// The current user's audiobook bookmarks. The server identifies a bookmark by item ID and
/// `time`; the title must not be empty.
public enum BookmarkEndpoints {
    /// `POST /api/me/item/:itemID/bookmark`. If a bookmark exists at `time`, the server renames
    /// it and returns it.
    public static func create(itemID: String, time: Double, title: String) -> Endpoint<AudioBookmark> {
        Endpoint(.post, path(itemID: itemID), body: Body(time: time, title: title))
    }

    /// `PATCH /api/me/item/:itemID/bookmark`: renames the bookmark at `time` (404 if none).
    public static func update(itemID: String, time: Double, title: String) -> Endpoint<AudioBookmark> {
        Endpoint(.patch, path(itemID: itemID), body: Body(time: time, title: title))
    }

    /// `DELETE /api/me/item/:itemID/bookmark/:time`.
    public static func delete(itemID: String, time: Double) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "\(path(itemID: itemID))/\(pathSegment(pathTime(time)))")
    }

    /// `time` as the server's `Number(req.params.time)` reads it back, matched with `==`
    /// against the stored value: whole seconds without a fraction (like JavaScript's
    /// `String(12)`), others as Swift's shortest round-trip form, which is locale-independent.
    static func pathTime(_ time: Double) -> String {
        // 2^53: every whole Double below it is exact as an Int64 and as a JavaScript number.
        if time.rounded() == time, abs(time) < 9_007_199_254_740_992 {
            return String(Int64(time))
        }
        return String(describing: time)
    }

    private static func path(itemID: String) -> String {
        "/api/me/item/\(pathSegment(itemID))/bookmark"
    }

    private struct Body: Encodable, Sendable {
        let time: Double
        let title: String
    }
}
