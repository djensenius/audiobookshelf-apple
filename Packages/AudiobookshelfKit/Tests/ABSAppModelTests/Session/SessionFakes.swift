import ABSAPI
import Foundation
import Observation
import Synchronization

@testable import ABSAppModel

/// Records the calls of every fake, in order.
@MainActor
final class CallLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) { entries.append(entry) }

    func count(of entry: String) -> Int { entries.filter { $0 == entry }.count }

    func clear() { entries = [] }
}

let identityA = SessionIdentity(connectionID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, userID: "a")
let identityB = SessionIdentity(connectionID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!, userID: "b")

/// The account, as `AccountManager` would report it.
@MainActor @Observable
final class FakeAccountSource: AccountSessionSource {
    var phase: AccountSessionPhase = .signedOut
    let client: APIClient? = nil

    @ObservationIgnored private let log: CallLog
    /// What ``restore()`` ends in.
    @ObservationIgnored var restoredPhase: AccountSessionPhase = .signedOut
    @ObservationIgnored var restoreError: (any Error)?
    @ObservationIgnored var switchError: (any Error)?
    @ObservationIgnored private(set) var restoreCount = 0

    init(log: CallLog) {
        self.log = log
    }

    func restore() async throws {
        restoreCount += 1
        log.record("accounts.restore")
        phase = .restoring
        await Task.yield()
        if let restoreError { throw restoreError }
        phase = restoredPhase
    }

    func logout() async -> URL? {
        log.record("accounts.logout")
        phase = .signedOut
        return URL(string: "https://idp.example/logout")
    }

    func `switch`(to connectionID: UUID) async throws {
        let target = [identityA, identityB].first { $0.connectionID == connectionID }
        log.record("accounts.switch(\(target?.userID ?? "?"))")
        if let switchError { throw switchError }
        guard let target else { return }
        phase = .restoring
        await Task.yield()
        phase = .active(target, isOffline: false)
    }

    /// The server rejects the session: the identity disappears on its own.
    func expire() { phase = .signedOut }
}

/// A participant that records its calls; `name` prefixes each entry.
@MainActor
final class FakeParticipant: SessionParticipant {
    let name: String
    private let log: CallLog
    /// When set, ``flush()`` waits for ``releaseFlush()``.
    var blocksFlush = false
    private var flushWaiter: CheckedContinuation<Void, Never>?

    init(_ name: String, log: CallLog) {
        self.name = name
        self.log = log
    }

    func sessionDidStart(_ context: SessionContext) async {
        log.record("\(name).start(\(context.identity.userID))")
    }

    func sessionWillEnd(_ reason: SessionEndReason) async {
        log.record("\(name).end(\(reason))")
    }

    func flush() async {
        log.record("\(name).flush")
        guard blocksFlush else { return }
        await withCheckedContinuation { flushWaiter = $0 }
        log.record("\(name).flushed")
    }

    func releaseFlush() {
        flushWaiter?.resume()
        flushWaiter = nil
    }
}

/// The library: connects, marks the seed boundary, fetches `/api/me` and seeds, then clears.
@MainActor
final class FakeLibrary: SessionSeeding {
    private let log: CallLog

    init(log: CallLog) {
        self.log = log
    }

    func sessionDidStart(_ context: SessionContext) async {
        log.record("library.connect(\(context.identity.userID))")
    }

    func sessionWillEnd(_ reason: SessionEndReason) async {
        log.record("library.clear(\(reason))")
    }

    func flush() async {
        log.record("library.flush")
    }

    func beginSeed(_ context: SessionContext) async {
        log.record("library.beginSeed(\(context.identity.userID))")
    }

    func seed(_ context: SessionContext) async {
        log.record("library.fetchMe(\(context.identity.userID))")
        await Task.yield()
        guard !Task.isCancelled else { return }
        log.record("library.seed(\(context.identity.userID))")
    }
}

struct StoreFailure: Error, CustomStringConvertible {
    var description: String { "The store couldn't be opened." }
}

/// A clock that only moves when the test advances it.
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

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if deadline <= state.now || Task.isCancelled { return true }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Waits for `condition`, letting other tasks run; `false` if it never holds.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for attempt in 0..<2_000 {
        if condition() { return true }
        if attempt < 200 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    return condition()
}
