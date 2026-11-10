import Foundation
import Synchronization

/// Finds the process's engine for ``DownloadEngine/handleBackgroundEvents()``, which the
/// system can call before the app has created it.
final class DownloadEngineRegistry: Sendable {
    static let shared = DownloadEngineRegistry()

    private enum Waiter {
        case waiting(CheckedContinuation<DownloadEngine?, Never>)
        case timedOut
    }

    private struct State {
        weak var engine: DownloadEngine?
        var waiters: [UUID: Waiter] = [:]
        /// Wakes that gave up waiting for an engine; their events-finished call has no waiter.
        var abandonedWakes = 0
    }

    private let state = Mutex(State())

    /// The registered engine, if it still exists.
    var current: DownloadEngine? {
        state.withLock { $0.engine }
    }

    /// Makes `engine` the one returned from now on and hands it to the waiting callers.
    func register(_ engine: DownloadEngine) {
        let waiting = state.withLock { state in
            state.engine = engine
            defer { state.waiters.removeAll() }
            return state.waiters.values.compactMap { waiter -> CheckedContinuation<DownloadEngine?, Never>? in
                if case .waiting(let continuation) = waiter { continuation } else { nil }
            }
        }
        for continuation in waiting {
            continuation.resume(returning: engine)
        }
    }

    /// The registered engine, waiting up to `timeout` on `clock` for one to be created.
    func engine(timeout: Duration, clock: any Clock<Duration>) async -> DownloadEngine? {
        let id = UUID()
        let timer = Task { [self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            let waiter = state.withLock { state -> Waiter? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                // The caller hasn't started waiting yet; it returns `nil` when it does.
                if state.engine == nil { state.waiters[id] = .timedOut }
                return nil
            }
            if case .waiting(let continuation) = waiter { continuation.resume(returning: nil) }
        }
        defer {
            timer.cancel()
            state.withLock { _ = $0.waiters.removeValue(forKey: id) }
        }
        return await withCheckedContinuation { continuation in
            let found = state.withLock { state -> DownloadEngine?? in
                if let engine = state.engine { return .some(engine) }
                if case .timedOut = state.waiters[id] {
                    state.waiters[id] = nil
                    return .some(nil)
                }
                state.waiters[id] = .waiting(continuation)
                return .none
            }
            if let found { continuation.resume(returning: found) }
        }
    }

    /// Records a wake that returned without an engine.
    func abandonWake() {
        state.withLock { $0.abandonedWakes += 1 }
    }

    /// Whether an events-finished call belongs to an abandoned wake; consumes it if so.
    func consumeAbandonedWake() -> Bool {
        state.withLock { state in
            guard state.abandonedWakes > 0 else { return false }
            state.abandonedWakes -= 1
            return true
        }
    }
}
