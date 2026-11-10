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

    /// The entries other than flushes, whose order is concurrent.
    var withoutFlushes: [String] { entries.filter { !$0.contains(".flush") } }

    var flushes: Set<String> { Set(entries.filter { $0.contains(".flush") }) }
}

/// Holds its waiters until it's opened, then lets everyone through.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

let identityA = SessionIdentity(connectionID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, userID: "a")
let identityB = SessionIdentity(connectionID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!, userID: "b")

private struct NoTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

func makeClient() throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: URL(string: "https://abs.example")!),
        tokenProvider: NoTokens())
}

/// The account, as `AccountManager` would report it.
@MainActor @Observable
final class FakeAccountSource: AccountSessionSource {
    var phase: AccountSessionPhase = .signedOut
    var client: APIClient?

    @ObservationIgnored private let log: CallLog
    /// What ``restore()`` ends in.
    @ObservationIgnored var restoredPhase: AccountSessionPhase = .signedOut
    @ObservationIgnored var restoredClient: APIClient?
    @ObservationIgnored var restoreGate: Gate?
    @ObservationIgnored var restoreError: (any Error)?
    @ObservationIgnored var switchError: (any Error)?
    /// The switch fails without throwing and leaves the account signed out.
    @ObservationIgnored var switchSignsOut = false
    /// Runs inside ``switch(to:)``, before it changes anything.
    @ObservationIgnored var onSwitch: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var restoreCount = 0

    init(log: CallLog) {
        self.log = log
    }

    func restore() async throws {
        restoreCount += 1
        log.record("accounts.restore")
        phase = .restoring
        await restoreGate?.wait()
        await Task.yield()
        if let restoreError { throw restoreError }
        client = restoredClient
        phase = restoredPhase
    }

    func logout() async -> URL? {
        log.record("accounts.logout")
        phase = .signedOut
        client = nil
        return URL(string: "https://idp.example/logout")
    }

    func `switch`(to connectionID: UUID) async throws {
        let target = [identityA, identityB].first { $0.connectionID == connectionID }
        log.record("accounts.switch(\(target?.userID ?? "?"))")
        onSwitch?()
        if let switchError { throw switchError }
        phase = .restoring
        await Task.yield()
        if switchSignsOut {
            phase = .signedOut
            return
        }
        guard let target else { return }
        phase = .active(target, isOffline: false)
    }

    func remove(_ connectionID: UUID) async throws -> URL? {
        let target = [identityA, identityB].first { $0.connectionID == connectionID }
        log.record("accounts.remove(\(target?.userID ?? "?"))")
        guard phase.identity?.connectionID == connectionID else { return nil }
        phase = .signedOut
        client = nil
        return URL(string: "https://idp.example/logout")
    }

    /// The server rejects the session: the identity disappears on its own.
    func expire() {
        phase = .signedOut
        client = nil
    }

    /// Expires without notifying observers, so the lifecycle hasn't reconciled it when its next
    /// transition runs.
    func expireUnobserved() {
        _phase = .signedOut
        _client = nil
    }

    /// Restores again, as from offline, and gets `client` for the same identity.
    func reconnect(client: APIClient) async {
        guard let identity = phase.identity else { return }
        phase = .restoring
        await Task.yield()
        self.client = client
        phase = .active(identity, isOffline: false)
    }
}

/// A participant that records its calls; `name` prefixes each entry.
@MainActor
final class FakeParticipant: SessionParticipant {
    let name: String
    private let log: CallLog
    /// When set, ``flush()`` waits for it to open, or for cancellation.
    var flushGate: Gate?
    /// When set, ``sessionWillEnd(_:)`` waits for it to open after stopping, or for
    /// cancellation.
    var endGate: Gate?
    /// When set, ``sessionDidReconnect(_:)`` waits for it.
    var reconnectGate: Gate?
    /// The context of the last start or reconnect.
    private(set) var context: SessionContext?
    /// Runs once inside the next ``sessionDidStart(_:)``.
    var onStart: (@MainActor () async -> Void)?
    /// Runs inside ``sessionWillEnd(_:)``, after stopping.
    var onEnd: (@MainActor () -> Void)?
    /// Between start and end; a flush outside a session does nothing.
    private var isRunning = false

    init(_ name: String, log: CallLog) {
        self.name = name
        self.log = log
    }

    func sessionDidStart(_ context: SessionContext) async {
        isRunning = true
        self.context = context
        log.record("\(name).start(\(context.identity.userID))")
        if let onStart {
            self.onStart = nil
            await onStart()
        }
    }

    func sessionDidReconnect(_ context: SessionContext) async {
        self.context = context
        log.record("\(name).reconnect(\(context.identity.userID))")
        await reconnectGate?.wait()
    }

    func sessionWillEnd(_ reason: SessionEndReason) async {
        isRunning = false
        log.record("\(name).end(\(reason))")
        onEnd?()
        if let endGate {
            await withTaskCancellationHandler {
                await endGate.wait()
            } onCancel: {
                Task { @MainActor in endGate.open() }
            }
            log.record(Task.isCancelled ? "\(name).endCancelled" : "\(name).ended")
        }
    }

    func flush() async {
        guard isRunning else { return }
        log.record("\(name).flush")
        if let flushGate {
            await withTaskCancellationHandler {
                await flushGate.wait()
            } onCancel: {
                Task { @MainActor in flushGate.open() }
            }
        }
        log.record(Task.isCancelled ? "\(name).flushCancelled" : "\(name).flushed")
    }
}

/// The library: connects, marks the seed boundary, fetches `/api/me` and seeds, then clears. A
/// seed drops itself when the library reconnected, reseeded or cleared since it began. Like
/// `ProgressCache`, a seed keeps progress applied after the boundary, and drops progress applied
/// before it that `/api/me` (here always empty) doesn't return.
@MainActor
final class FakeLibrary: SessionSeeding {
    private let log: CallLog
    /// When set, ``sessionDidStart(_:)`` waits for it after connecting.
    var connectGate: Gate?
    /// When set, ``seed(_:)`` waits for it after fetching.
    var seedGate: Gate?
    private var generation = 0
    private var isRunning = false
    /// Orders progress writes against the seed boundary.
    private var tick = 0
    private var boundary = 0
    private var appliedAt: [String: Int] = [:]
    /// Items with cached progress.
    var progress: Set<String> { Set(appliedAt.keys) }

    init(log: CallLog) {
        self.log = log
    }

    func sessionDidStart(_ context: SessionContext) async {
        generation += 1
        isRunning = true
        log.record("library.connect(\(context.identity.userID))")
        await connectGate?.wait()
    }

    func sessionDidReconnect(_ context: SessionContext) async {
        log.record("library.reconnect(\(context.identity.userID))")
    }

    func sessionWillEnd(_ reason: SessionEndReason) async {
        generation += 1
        isRunning = false
        log.record("library.clear(\(reason))")
    }

    func flush() async {
        guard isRunning else { return }
        log.record("library.flush")
        log.record("library.flushed")
    }

    func beginSeed(_ context: SessionContext) async {
        generation += 1
        tick += 1
        boundary = tick
        log.record("library.beginSeed(\(context.identity.userID))")
    }

    func seed(_ context: SessionContext) async {
        let generation = generation
        log.record("library.fetchMe(\(context.identity.userID))")
        if let seedGate { await seedGate.wait() } else { await Task.yield() }
        guard generation == self.generation else {
            log.record("library.seedDropped(\(context.identity.userID))")
            return
        }
        appliedAt = appliedAt.filter { $0.value > boundary }
        log.record("library.seed(\(context.identity.userID))")
    }

    /// Progress from a running source, such as playback.
    func apply(_ item: String) {
        tick += 1
        appliedAt[item] = tick
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
