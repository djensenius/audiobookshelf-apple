import Synchronization

/// One shared operation and the callers waiting on it (ADR 0005, "Deduplication and
/// cancellation").
///
/// A waiter that is cancelled leaves at once without affecting the others. When the last
/// waiter leaves before the result arrives, the flight is abandoned and its task cancelled;
/// later callers must start a new flight.
final class Flight<Value: Sendable>: Sendable {
    /// Thrown by ``join()`` on an abandoned flight.
    struct Abandoned: Error {}

    private struct State {
        var task: Task<Void, Never>?
        var result: Result<Value, any Error>?
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
        var nextWaiter: UInt64 = 0
        var isAbandoned = false
    }

    private let state = Mutex(State())

    var isAbandoned: Bool { state.withLock { $0.isAbandoned } }
    /// The callers waiting on the result, for tests.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Starts `operation`, whose result is delivered to every waiter.
    func start(priority: TaskPriority? = nil, _ operation: @escaping @Sendable () async throws -> Value) {
        let task = Task(priority: priority) {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        // Publish the handle under the lock: if the flight was abandoned while the task was
        // being created, nobody else can cancel it.
        let isAbandoned = state.withLock { state in
            if !state.isAbandoned, state.result == nil { state.task = task }
            return state.isAbandoned
        }
        if isAbandoned { task.cancel() }
    }

    func join() async throws -> Value {
        let id = state.withLock { state in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (immediate, orphan) = state.withLock {
                    state -> (Result<Value, any Error>?, Task<Void, Never>?) in
                    if let result = state.result { return (result, nil) }
                    if state.isAbandoned { return (.failure(Abandoned()), nil) }
                    if Task.isCancelled {
                        // A caller cancelled before joining may be the flight's only one.
                        guard state.waiters.isEmpty else { return (.failure(CancellationError()), nil) }
                        state.isAbandoned = true
                        return (.failure(CancellationError()), state.task)
                    }
                    state.waiters[id] = continuation
                    return (nil, nil)
                }
                orphan?.cancel()
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            leave(id)
        }
    }

    /// Abandons the flight and cancels its task; current waiters get the task's result, usually
    /// a `CancellationError`.
    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard state.result == nil else { return nil }
            state.isAbandoned = true
            return state.task
        }
        task?.cancel()
    }

    private func leave(_ id: UInt64) {
        let (continuation, task) = state.withLock {
            state -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?) in
            guard let continuation = state.waiters.removeValue(forKey: id) else { return (nil, nil) }
            guard state.waiters.isEmpty, state.result == nil else { return (continuation, nil) }
            state.isAbandoned = true
            return (continuation, state.task)
        }
        continuation?.resume(throwing: CancellationError())
        task?.cancel()
    }

    private func finish(_ result: Result<Value, any Error>) {
        let waiters = state.withLock { state in
            state.result = result
            state.task = nil
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(with: result) }
    }
}

/// A counting semaphore whose waiters can be cancelled.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiter: UInt64 = 0

    init(permits: Int) {
        self.permits = permits
    }

    /// Free permits and queued waiters, for tests.
    var availablePermits: Int { permits }
    var waiterCount: Int { waiters.count }

    func acquire() async throws {
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }
        nextWaiter += 1
        let id = nextWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
