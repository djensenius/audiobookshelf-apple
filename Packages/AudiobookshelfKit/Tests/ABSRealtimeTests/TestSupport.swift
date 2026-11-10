import ABSRealtime
import Foundation
import Synchronization

/// A clock that only moves when a test calls ``advance(by:)``.
final class ManualClock: Clock, Sendable {
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

    private struct Waiter {
        let delays: [Duration]
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var waiters: [Waiter] = []

        var pendingDelays: [Duration] {
            sleepers.values.map { now.duration(to: $0.deadline) }.sorted()
        }

        /// Removes and returns the waiters whose expected delays are now pending.
        mutating func satisfiedWaiters() -> [Waiter] {
            let pending = pendingDelays
            let ready = waiters.filter { $0.delays == pending }
            waiters.removeAll { $0.delays == pending }
            return ready
        }
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Deadlines of pending sleeps, relative to now.
    var pendingDelays: [Duration] {
        state.withLock { $0.pendingDelays }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (immediate, waiters): (Result<Void, any Error>?, [Waiter]) = state.withLock { state in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return (nil, state.satisfiedWaiters())
                }
                if let immediate { continuation.resume(with: immediate) }
                waiters.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            let (sleeper, waiters) = state.withLock { state in
                let sleeper = state.sleepers.removeValue(forKey: id)
                return (sleeper, state.satisfiedWaiters())
            }
            sleeper?.continuation.resume(throwing: CancellationError())
            waiters.forEach { $0.continuation.resume() }
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let (due, waiters) = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return (Array(due.values), state.satisfiedWaiters())
        }
        due.forEach { $0.continuation.resume() }
        waiters.forEach { $0.continuation.resume() }
    }

    /// Suspends until exactly these sleeps (relative to now, in any order) are pending.
    func waitUntilPending(_ delays: [Duration]) async {
        let expected = delays.sorted()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if state.pendingDelays == expected { return true }
                state.waiters.append(Waiter(delays: expected, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

struct FakeTransportError: Error {}

/// Records connections and hands each one to the test.
final class FakeTransport: WebSocketTransport {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
    }

    let connections: AsyncStream<FakeConnection>
    private let continuation: AsyncStream<FakeConnection>.Continuation
    private let recorded = Mutex<[Request]>([])

    init() {
        (connections, continuation) = AsyncStream.makeStream()
    }

    var requests: [Request] { recorded.withLock { $0 } }

    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        recorded.withLock { $0.append(Request(url: url, headers: headers)) }
        let connection = FakeConnection()
        continuation.yield(connection)
        return connection
    }
}

/// A connection the test drives: ``push(_:)`` plays the server, ``sent`` records the client.
final class FakeConnection: WebSocketConnection {
    let messages: AsyncThrowingStream<WebSocketMessage, any Error>
    private let messageContinuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation
    let sent: AsyncStream<String>
    private let sentContinuation: AsyncStream<String>.Continuation
    private let closed = Mutex(false)

    init() {
        (messages, messageContinuation) = AsyncThrowingStream.makeStream()
        (sent, sentContinuation) = AsyncStream.makeStream()
    }

    var isClosed: Bool { closed.withLock { $0 } }

    func push(_ text: String) {
        messageContinuation.yield(.text(text))
    }

    func fail() {
        messageContinuation.finish(throwing: FakeTransportError())
    }

    func send(_ text: String) async throws {
        sentContinuation.yield(text)
    }

    func close() {
        closed.withLock { $0 = true }
        messageContinuation.finish()
        sentContinuation.finish()
    }
}
