import ABSAPI
import Foundation
import Synchronization

/// Why playback stops. Account-ending reasons permanently retire the coordinator.
public enum PlaybackStopReason: Sendable, Equatable {
    /// Clear LastPlayed and keep the coordinator reusable.
    case user
    /// Retain the latest matching LastPlayed record; allow final close transport.
    case accountSwitch
    /// Retain LastPlayed but suppress transport.
    case expired
    /// Clear only this connection's LastPlayed record and suppress transport.
    case signOut
    case accountRemoved

    var permitsTransport: Bool { self == .user || self == .accountSwitch }
}

/// The immutable final report and a receipt for its AUDIO POSITION only. The receipt must not
/// succeed until the position (or an explicitly tracked newer edit) commits to local storage.
/// Listening-time/report reconciliation is not covered by this receipt (#53/#158).
public struct PlaybackCloseHandoff: Sendable {
    public let report: PlaybackSyncReport
    let position: PlaybackCloseResult<Void>
    /// Resolved once the closing session's `/sync` in flight returned.
    let sessionSync: PlaybackCloseResult<Void>?

    init(
        report: PlaybackSyncReport, position: PlaybackCloseResult<Void>,
        sessionSync: PlaybackCloseResult<Void>? = nil
    ) {
        self.report = report
        self.position = position
        self.sessionSync = sessionSync
    }

    /// Canceling a waiter never cancels ownership of the captured write.
    public func waitForAudioPosition() async throws {
        try await position.wait()
    }

    /// Waits until the closing session's `/sync` in flight returned, so a `/close` sent after it
    /// is normally the server's last word on the session (#337), or until `sleep(timeout)` ends.
    /// Returns at once when none was in flight; throws only when the waiting task is cancelled.
    func waitForSessionSync(
        timeout: Duration, sleep: @escaping @Sendable (Duration) async -> Void
    ) async throws {
        guard let sessionSync, sessionSync.result == nil else { return }
        let first = PlaybackCloseResult<Void>()
        let timer = Task {
            await sleep(timeout)
            first.resolve(.success(()))
        }
        let sync = Task {
            _ = try? await sessionSync.wait()
            first.resolve(.success(()))
        }
        defer {
            timer.cancel()
            sync.cancel()
        }
        try await first.wait()
    }
}

/// An aggregate of closes joined by a waiter; an empty list means no session needed closing.
public struct PlaybackCloseOutcome: Sendable, Equatable {
    public struct Session: Sendable, Equatable {
        public enum Transport: Sendable, Equatable {
            case acknowledged
            /// Transport failed or exceeded the deadline; only the audio position is durable.
            case committedAudioPositionFallback
            /// New transport was suppressed. An already-issued request was canceled best-effort;
            /// this cannot retract its bytes or imply that the server never saw it.
            case deliberatelySkipped
        }

        /// A server capability, not a value to log.
        public let sessionID: String
        public let transport: Transport
        /// False only for a session that never loaded and therefore had no final-position handoff.
        public let audioPositionCommitted: Bool
    }

    public let sessions: [Session]
}

public enum PlaybackCloseError: Error, Sendable, Equatable {
    case missingReporter(sessionID: String)
    case positionCommitFailed(sessionID: String, description: String)
    case transportFailed(sessionID: String, description: String)
    case timedOut
}

/// First-finish gate with independently cancellable waiters. No task-group scope has to join
/// uncooperative transport/persistence children. Resolving it is not cancellation of the owner.
final class PlaybackCloseResult<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
    }
    private let state = Mutex(State())

    var result: Result<Value, any Error>? { state.withLock { $0.result } }
    /// Waiters suspended now (tests).
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func resolve(_ result: Result<Value, any Error>) {
        let waiters = state.withLock { state in
            guard state.result == nil else { return [CheckedContinuation<Value, any Error>]() }
            state.result = result
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    func wait() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let result = state.result { return result }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

@MainActor
final class PlaybackCloseOperation {
    let sessionID: String
    let wasLoaded: Bool
    let handoff: PlaybackCloseHandoff?
    let transport = PlaybackCloseResult<Bool>()
    /// Resolved as `/close` is called, or once it won't be: the next `/play` waits for it.
    let dispatched = PlaybackCloseResult<Void>()
    var task: Task<Void, Never>?

    init(sessionID: String, wasLoaded: Bool, handoff: PlaybackCloseHandoff?) {
        self.sessionID = sessionID
        self.wasLoaded = wasLoaded
        self.handoff = handoff
    }

    func outcome() throws -> PlaybackCloseOutcome.Session {
        if wasLoaded {
            guard let handoff else { throw PlaybackCloseError.missingReporter(sessionID: sessionID) }
            guard let result = handoff.position.result else { throw PlaybackCloseError.timedOut }
            do { try result.get() } catch {
                throw PlaybackCloseError.positionCommitFailed(
                    sessionID: sessionID, description: String(describing: error))
            }
        }
        let disposition: PlaybackCloseOutcome.Session.Transport
        switch transport.result {
        case .success(true): disposition = .acknowledged
        case .success(false): disposition = .deliberatelySkipped
        case .failure where wasLoaded, nil where wasLoaded: disposition = .committedAudioPositionFallback
        case .failure(let error):
            throw PlaybackCloseError.transportFailed(sessionID: sessionID, description: String(describing: error))
        case nil: throw PlaybackCloseError.timedOut
        }
        return .init(sessionID: sessionID, transport: disposition, audioPositionCommitted: wasLoaded)
    }
}
