import ABSCore
import Foundation
import Testing

@testable import ABSAPI

// Both pinned releases (tags v2.26.0 and v2.37.2 of advplyr/audiobookshelf) share the bookmark
// code: `server/controllers/MeController.js`
// (`createBookmark`, `updateBookmark`, `removeBookmark`; 2.26.0 L194–L264, 2.37.2 L327–L424) and
// `server/models/User.js` (`findBookmark` … `removeBookmark`; 2.26.0 L831–L903, 2.37.2
// L841–L913). A bookmark is found by `libraryItemId` and `bm.time == time`.

extension ContractSession {
    fileprivate func bookmark(_ itemID: String, at time: Double, _ title: String) async throws -> AudioBookmark {
        try await client.send(BookmarkEndpoints.create(itemID: itemID, time: time, title: title))
    }

    fileprivate func bookmarks() async throws -> [AudioBookmark] {
        try await client.send(UserEndpoints.meBookmarks()).bookmarks
    }
}

/// Expects `operation` to fail with the server's 400.
private func expectBadRequest<T>(
    sourceLocation: SourceLocation = #_sourceLocation, _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    if case .http(400, _)? = error { return }
    Issue.record("Expected a 400, got \(String(describing: error))", sourceLocation: sourceLocation)
}

@Suite("Server contract: bookmarks", .requiresServer, .tags(.serverContract))
struct BookmarkContractTests {
    @Test("create returns the bookmark at a whole and a fractional time")
    func create() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            #expect(try await session.bookmarks().isEmpty)

            let whole = try await session.bookmark(seed.taleID, at: 12, "Whole")
            #expect(whole.libraryItemId == seed.taleID)
            #expect(whole.time == 12)
            #expect(whole.title == "Whole")
            #expect(whole.createdAt != nil)

            let fractional = try await session.bookmark(seed.taleID, at: 12.345, "Fractional")
            #expect(fractional.libraryItemId == seed.taleID)
            #expect(fractional.time == 12.345)
            #expect(fractional.title == "Fractional")

            #expect(Set(try await session.bookmarks()) == [whole, fractional])
        }
    }

    @Test("create at an existing time renames that bookmark")
    func createAtExistingTimeRenames() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let first = try await session.bookmark(seed.taleID, at: 12.345, "First")
            // `User.createBookmark` returns the existing bookmark, renamed.
            let renamed = try await session.bookmark(seed.taleID, at: 12.345, "Second")
            #expect(renamed.time == 12.345)
            #expect(renamed.title == "Second")
            #expect(renamed.createdAt == first.createdAt)

            let listed = try await session.bookmarks()
            #expect(listed.count == 1)
            #expect(listed.first?.title == "Second")
        }
    }

    @Test("update renames a bookmark, and is a 404 at an unknown time")
    func update() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let created = try await session.bookmark(seed.taleID, at: 12.345, "Before")
            let updated = try await session.client.send(
                BookmarkEndpoints.update(itemID: seed.taleID, time: 12.345, title: "After"))
            #expect(updated.libraryItemId == seed.taleID)
            #expect(updated.time == 12.345)
            #expect(updated.title == "After")
            #expect(updated.createdAt == created.createdAt)
            #expect(try await session.bookmarks().map(\.title) == ["After"])

            // `updateBookmark` answers `sendStatus(404)` when `User.updateBookmark` finds none.
            await expectNotFound {
                try await session.client.send(BookmarkEndpoints.update(itemID: seed.taleID, time: 13, title: "None"))
            }
            await expectNotFound {
                try await session.client.send(
                    BookmarkEndpoints.update(itemID: seed.singleFileID, time: 12.345, title: "Other item"))
            }
            #expect(try await session.bookmarks().map(\.title) == ["After"])
        }
    }

    @Test("delete at a fractional time removes exactly that bookmark; a second delete is a 404")
    func delete() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let whole = try await session.bookmark(seed.taleID, at: 12, "Whole")
            _ = try await session.bookmark(seed.taleID, at: 12.345, "Fractional")
            let other = try await session.bookmark(seed.singleFileID, at: 12.345, "Other item")

            // `BookmarkEndpoints.pathTime` must read back as the stored number.
            _ = try await session.client.send(BookmarkEndpoints.delete(itemID: seed.taleID, time: 12.345))
            #expect(Set(try await session.bookmarks()) == [whole, other])

            // Pinned, the same on 2.26.0 and 2.37.2: `removeBookmark` answers `sendStatus(404)`
            // when `findBookmark` has nothing at the time (MeController.js 2.26.0 L255–L258,
            // 2.37.2 L415–L418).
            await expectNotFound {
                try await session.client.send(BookmarkEndpoints.delete(itemID: seed.taleID, time: 12.345))
            }

            _ = try await session.client.send(BookmarkEndpoints.delete(itemID: seed.taleID, time: 12))
            #expect(try await session.bookmarks() == [other])
        }
    }

    @Test("GET /api/me lists bookmarks across items without lossy drops")
    func listAcrossItems() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let created = [
                try await session.bookmark(seed.taleID, at: 5, "Tale start"),
                try await session.bookmark(seed.taleID, at: 31.5, "Tale part two"),
                try await session.bookmark(seed.singleFileID, at: 20.25, "Single middle"),
            ]

            let listed = try await session.bookmarks()
            #expect(Set(listed) == Set(created))
            // `UserBookmarksResponse` skips rows it can't decode, so count the raw rows too.
            let raw = try await session.client.send(Endpoint<Data>(.get, "/api/me"))
            let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            let rows = try #require(object["bookmarks"] as? [Any])
            #expect(rows.count == created.count)
            #expect(listed.count == rows.count)
        }
    }

    @Test("an empty title is a 400 and changes nothing")
    func emptyTitle() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let kept = try await session.bookmark(seed.taleID, at: 12, "Kept")

            // Pinned, the same on 2.26.0 and 2.37.2: `!title` answers `status(400)` "Invalid
            // title" (MeController.js createBookmark 2.26.0 L202–L205, 2.37.2 L344–L347;
            // updateBookmark 2.26.0 L226–L229, 2.37.2 L377–L380).
            await expectBadRequest { try await session.bookmark(seed.taleID, at: 13, "") }
            await expectBadRequest {
                try await session.client.send(BookmarkEndpoints.update(itemID: seed.taleID, time: 12, title: ""))
            }
            #expect(try await session.bookmarks() == [kept])
        }
    }
}
