import ABSAPI
import ABSCore
import Foundation

/// Changes the user's bookmarks on the server; `APIClient` conforms.
public protocol BookmarkWriting: Sendable {
    /// Creates a bookmark, or renames the one already at `time`, and returns the server's copy.
    func createBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark
    /// Renames the bookmark at `time`; fails if there is none.
    func renameBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark
    func deleteBookmark(itemID: String, time: Double) async throws
}

/// Fetches every bookmark of the user; `APIClient` conforms.
public protocol BookmarkReading: Sendable {
    func allBookmarks() async throws -> [AudioBookmark]
}

extension APIClient: BookmarkWriting, BookmarkReading {
    public func createBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        try await send(BookmarkEndpoints.create(itemID: itemID, time: time, title: title))
    }

    public func renameBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        try await send(BookmarkEndpoints.update(itemID: itemID, time: time, title: title))
    }

    public func deleteBookmark(itemID: String, time: Double) async throws {
        _ = try await send(BookmarkEndpoints.delete(itemID: itemID, time: time))
    }

    public func allBookmarks() async throws -> [AudioBookmark] {
        try await send(UserEndpoints.meBookmarks()).bookmarks
    }
}
