import Synchronization

/// Like ``GatedCalls``, but a caller whose task is cancelled gets `CancellationError` at once. Run the
/// calling work as a child task (`async let`), and a test that stops early, or whose time limit
/// cancels it, fails instead of waiting forever for a reply. A reply after that, or a second reply,
/// is ignored.
///
/// The shared ``GatedCalls`` is left as it is: its tests may rely on a cancelled call staying
/// suspended until they answer it.
final class CancellableGatedCalls<Request: Sendable, Response: Sendable>: Sendable {
    /// The answer to one call; only the first `resume` counts.
    final class Reply: Sendable {
        private enum State {
            case pending
            case waiting(CheckedContinuation<Response, any Error>)
            case done(Result<Response, any Error>)
        }

        private let state = Mutex(State.pending)

        func resume(returning value: Response) { resume(with: .success(value)) }

        func resume(throwing error: any Error) { resume(with: .failure(error)) }

        func resume(with result: Result<Response, any Error>) {
            let waiting: CheckedContinuation<Response, any Error>? = state.withLock { state in
                switch state {
                case .pending:
                    state = .done(result)
                    return nil
                case .waiting(let continuation):
                    state = .done(result)
                    return continuation
                case .done:
                    return nil
                }
            }
            waiting?.resume(with: result)
        }

        /// Resumes `continuation` with the reply, at once if it has come already (as when the
        /// task was cancelled first).
        fileprivate func wait(_ continuation: CheckedContinuation<Response, any Error>) {
            let result: Result<Response, any Error>? = state.withLock { state in
                if case .done(let result) = state { return result }
                state = .waiting(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    struct Call: Sendable {
        let request: Request
        let reply: Reply
    }

    let calls: AsyncStream<Call>
    private let continuation: AsyncStream<Call>.Continuation

    init() {
        (calls, continuation) = AsyncStream.makeStream()
    }

    func call(_ request: Request) async throws -> Response {
        let reply = Reply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.wait(continuation)
                self.continuation.yield(Call(request: request, reply: reply))
            }
        } onCancel: {
            reply.resume(throwing: CancellationError())
        }
    }
}

/// Counts calls per key across concurrent fakes.
final class KeyedCallCounter: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    /// Counts one call for `key` and returns how many there have been, this one included.
    func record(_ key: String) -> Int {
        counts.withLock { counts in
            counts[key, default: 0] += 1
            return counts[key, default: 0]
        }
    }

    func count(_ key: String) -> Int {
        counts.withLock { $0[key, default: 0] }
    }
}
