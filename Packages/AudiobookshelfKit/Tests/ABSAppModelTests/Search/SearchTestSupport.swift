import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

/// A search request a ``FakeSearchService`` received.
struct SearchRequest: Sendable, Equatable {
    let libraryID: String
    let query: String
    let limit: Int?
}

/// A ``SearchService`` whose responses come from a closure.
struct FakeSearchService: SearchService {
    var handler: @Sendable (SearchRequest) async throws -> LibrarySearchResults

    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        try await handler(SearchRequest(libraryID: id, query: query, limit: limit))
    }
}

/// A clock that moves only when a test calls ``advance(by:)`` and reports each sleep on
/// ``sleeps`` as it starts, so tests wait for the debounce without polling.
final class SearchTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    /// The delay of each sleep, relative to the clock's time when it started.
    let sleeps: AsyncStream<Duration>
    private let sleepContinuation: AsyncStream<Duration>.Continuation
    private let state = Mutex(State())

    init() {
        (sleeps, sleepContinuation) = AsyncStream.makeStream()
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var pendingSleeps: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, delay): (Result<Void, any Error>?, Duration?) = state.withLock { state in
                    if Task.isCancelled { return (.failure(CancellationError()), nil) }
                    let delay = state.now.duration(to: deadline)
                    if deadline <= state.now { return (.success(()), delay) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return (nil, delay)
                }
                if let delay { sleepContinuation.yield(delay) }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return Array(due.values)
        }
        due.forEach { $0.continuation.resume() }
    }
}

func decodeSearch(_ json: String) throws -> LibrarySearchResults {
    try JSONDecoder().decode(LibrarySearchResults.self, from: Data(json.utf8))
}

let searchBook = #"{"id":"li1","libraryId":"lib","mediaType":"book","media":{"id":"b1","metadata":{"title":"One"}}}"#
let searchPodcast =
    #"{"id":"li2","libraryId":"pods","mediaType":"podcast","media":{"id":"p1","metadata":{"title":"Pod"}}}"#
let searchEpisode =
    #"{"id":"li2","libraryId":"pods","mediaType":"podcast","media":{"id":"p1","metadata":{"title":"Pod"}},"#
    + #""recentEpisode":{"id":"ep7","libraryItemId":"li2","title":"Match"}}"#

/// Results with one book titled `title`.
func bookResults(_ id: String, title: String = "Title") throws -> LibrarySearchResults {
    try decodeSearch(
        #"{"book":[{"libraryItem":{"id":"\#(id)","libraryId":"lib","mediaType":"book","media":{"id":"b","metadata":{"title":"\#(title)"}}}}]}"#
    )
}
