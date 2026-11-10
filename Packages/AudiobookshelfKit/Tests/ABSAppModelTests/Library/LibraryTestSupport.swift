import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

/// Calls that suspend until the test answers them, so tests control the order of responses.
/// Each call is delivered on ``calls`` with its continuation.
final class GatedCalls<Request: Sendable, Response: Sendable>: Sendable {
    struct Call: Sendable {
        let request: Request
        let reply: CheckedContinuation<Response, any Error>
    }

    let calls: AsyncStream<Call>
    private let continuation: AsyncStream<Call>.Continuation

    init() {
        (calls, continuation) = AsyncStream.makeStream()
    }

    func call(_ request: Request) async throws -> Response {
        try await withCheckedThrowingContinuation { reply in
            continuation.yield(Call(request: request, reply: reply))
        }
    }
}

/// A ``LibraryService`` whose responses come from closures.
struct FakeLibraryService: LibraryService {
    var librariesHandler: @Sendable () async throws -> [Library] = { [] }
    var libraryHandler: @Sendable (String) async throws -> LibraryWithFilterData = { _ in throw TestError.unexpected }
    var shelvesHandler: @Sendable (String) async throws -> [Shelf] = { _ in [] }
    var itemsHandler: @Sendable (String, LibraryQuery) async throws -> PagedResults<LibraryItem> = { _, _ in
        PagedResults(results: [], total: 0, limit: 0, page: 0)
    }

    func libraries() async throws -> [Library] { try await librariesHandler() }
    func library(id: String) async throws -> LibraryWithFilterData { try await libraryHandler(id) }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { try await shelvesHandler(libraryID) }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await itemsHandler(libraryID, query)
    }
}

/// A value shared with `@Sendable` fakes.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

enum TestError: Error {
    case unexpected
    case offline
}

func makeLibrary(_ id: String, name: String? = nil, mediaType: MediaType = .book) -> Library {
    Library(id: id, name: name ?? id, mediaType: mediaType)
}

func makeShelf(_ id: String) -> Shelf {
    Shelf(id: id, label: id, type: .book, entities: .libraryItems([]))
}

struct TestItem: Identifiable, Decodable, Sendable, Equatable {
    let id: String
}

func items(_ ids: ClosedRange<Int>, prefix: String = "item") -> [TestItem] {
    ids.map { TestItem(id: "\(prefix)\($0)") }
}

/// Runs `body` with settings backed by a fresh, uniquely named `UserDefaults` suite.
@MainActor
func withLibrarySettings(_ body: @MainActor (AppSettings) async throws -> Void) async throws {
    let suiteName = "ABSAppModelTests.Library.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try await body(AppSettings(defaults: defaults))
}
