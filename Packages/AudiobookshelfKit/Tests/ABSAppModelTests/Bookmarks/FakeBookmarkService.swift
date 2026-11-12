import ABSAPI
import ABSCore
import Foundation
import Synchronization

@testable import ABSAppModel

/// A bookmark request, as the store sent it.
enum BookmarkRequest: Sendable, Equatable {
    case create(itemID: String, time: Double, title: String)
    case rename(itemID: String, time: Double, title: String)
    case delete(itemID: String, time: Double)

    var itemID: String {
        switch self {
        case .create(let itemID, _, _), .rename(let itemID, _, _), .delete(let itemID, _): itemID
        }
    }
}

/// A bookmark service whose writes and loads wait until the test answers them, so tests can
/// interleave writes, loads and replies. A write answered with `nil` returns the bookmark it sent.
final class FakeBookmarkService: BookmarkWriting, BookmarkReading {
    let writes = GatedCalls<BookmarkRequest, AudioBookmark?>()
    let loads = GatedCalls<Int, [AudioBookmark]>()
    private let counters = Mutex((inFlight: 0, peak: 0, loads: 0))

    /// The most writes in flight at once.
    var peakWrites: Int { counters.withLock { $0.peak } }

    func createBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        let reply = try await write(.create(itemID: itemID, time: time, title: title))
        return reply ?? AudioBookmark(libraryItemId: itemID, title: title, time: time)
    }

    func renameBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        let reply = try await write(.rename(itemID: itemID, time: time, title: title))
        return reply ?? AudioBookmark(libraryItemId: itemID, title: title, time: time)
    }

    func deleteBookmark(itemID: String, time: Double) async throws {
        _ = try await write(.delete(itemID: itemID, time: time))
    }

    /// Each load is numbered from 1, in the order it was sent.
    func allBookmarks() async throws -> [AudioBookmark] {
        let number = counters.withLock {
            $0.loads += 1
            return $0.loads
        }
        return try await loads.call(number)
    }

    private func write(_ request: BookmarkRequest) async throws -> AudioBookmark? {
        counters.withLock {
            $0.inFlight += 1
            $0.peak = max($0.peak, $0.inFlight)
        }
        defer { counters.withLock { $0.inFlight -= 1 } }
        return try await writes.call(request)
    }
}

enum BookmarkTestError: Error {
    case rejected
}

let bookmarkIdentity = SessionIdentity(
    connectionID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!, userID: "user")

func bookmarkContext(client: APIClient?, isOffline: Bool = false) -> SessionContext {
    SessionContext(identity: bookmarkIdentity, client: client, isOffline: isOffline, sessionID: 1)
}

/// A store whose session uses `service`.
@MainActor
func makeBookmarkStore(_ service: FakeBookmarkService) async throws -> BookmarkStore {
    let store = BookmarkStore(makeService: { _ in service })
    await store.sessionDidStart(bookmarkContext(client: try makeClient()))
    return store
}

func bookmark(_ item: String = "item", _ time: Double, _ title: String = "Mark", createdAt: Int? = nil)
    -> AudioBookmark
{
    AudioBookmark(libraryItemId: item, title: title, time: time, createdAt: createdAt)
}

func bookmarkUser(_ bookmarks: [AudioBookmark]) -> User {
    User(id: "user", username: "me", bookmarks: bookmarks)
}
