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
        let id: Int
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

    /// Suspends until exactly these sleeps (relative to now, in any order) are pending, or the
    /// task is cancelled (e.g. by a test's time limit).
    func waitUntilPending(_ delays: [Duration]) async {
        let expected = delays.sorted()
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if Task.isCancelled || state.pendingDelays == expected { return true }
                    state.waiters.append(Waiter(id: id, delays: expected, continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume()
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
    private let failuresLeft = Mutex(0)
    private let deliversAfterClose: Bool

    /// - Parameter deliversAfterClose: Connections keep delivering pushed frames after `close()`.
    init(deliversAfterClose: Bool = false) {
        self.deliversAfterClose = deliversAfterClose
        (connections, continuation) = AsyncStream.makeStream()
    }

    var requests: [Request] { recorded.withLock { $0 } }

    /// Makes the next `count` connection attempts throw.
    func failNextConnects(_ count: Int) {
        failuresLeft.withLock { $0 = count }
    }

    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        recorded.withLock { $0.append(Request(url: url, headers: headers)) }
        let shouldFail = failuresLeft.withLock { left in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        if shouldFail { throw FakeTransportError() }
        let connection = FakeConnection(deliversAfterClose: deliversAfterClose)
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
    private let deliversAfterClose: Bool
    /// While `isHeld`, `send` records the frame and then suspends until `releaseSends()`.
    private let sendGate = Mutex<(isHeld: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    init(deliversAfterClose: Bool = false) {
        self.deliversAfterClose = deliversAfterClose
        (messages, messageContinuation) = AsyncThrowingStream.makeStream()
        (sent, sentContinuation) = AsyncStream.makeStream()
    }

    var isClosed: Bool { closed.withLock { $0 } }

    func push(_ text: String) {
        messageContinuation.yield(.text(text))
    }

    func push(_ data: Data) {
        messageContinuation.yield(.data(data))
    }

    func fail() {
        messageContinuation.finish(throwing: FakeTransportError())
    }

    func holdSends() {
        sendGate.withLock { $0.isHeld = true }
    }

    func releaseSends() {
        let waiters = sendGate.withLock { gate in
            gate.isHeld = false
            defer { gate.waiters = [] }
            return gate.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func send(_ text: String) async throws {
        sentContinuation.yield(text)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = sendGate.withLock { gate in
                guard gate.isHeld else { return true }
                gate.waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func close() {
        closed.withLock { $0 = true }
        sentContinuation.finish()
        if !deliversAfterClose { messageContinuation.finish() }
    }
}
