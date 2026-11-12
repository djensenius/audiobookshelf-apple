import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

/// The calls of every fake, in the order they were made.
private final class Calls: Sendable {
    private let calls = Mutex<[String]>([])

    func append(_ call: String) {
        calls.withLock { $0.append(call) }
    }

    var all: [String] { calls.withLock { $0 } }
}

/// An engine that records its calls and whether it ends activated.
private actor FakeEngine: DownloadsLifecycleEngine {
    let calls: Calls
    /// What the next activations return.
    var activates = true
    /// Holds the next activation until it opens.
    var activateGate: StubGate?
    private(set) var isActive = false

    init(calls: Calls) {
        self.calls = calls
    }

    func set(activates: Bool) {
        self.activates = activates
    }

    func hold(_ gate: StubGate) {
        activateGate = gate
    }

    func activate() async -> Bool {
        calls.append("activate")
        if let gate = activateGate {
            activateGate = nil
            await gate.pass()
        }
        isActive = activates
        calls.append("activated")
        return activates
    }

    func deactivate() {
        calls.append("deactivate")
        isActive = false
    }

    /// What the next quiesces return, then `true`.
    private var quiesceResults: [Bool] = []

    func failQuiesces(_ count: Int) {
        quiesceResults = Array(repeating: false, count: count)
    }

    /// Pauses first, then is skipped when cancelled, as work that checks for cancellation would be.
    func quiesce(connectionID: UUID, pausing: @Sendable () async -> Void) async -> Bool {
        await pausing()
        guard !Task.isCancelled else {
            calls.append("cancelled quiesce \(connectionID)")
            return false
        }
        calls.append("quiesce \(connectionID)")
        return quiesceResults.isEmpty ? true : quiesceResults.removeFirst()
    }
}

/// A manager that records its calls.
private actor FakeManager: DownloadsLifecycleManager {
    let calls: Calls
    /// How many of the next starts throw.
    private var failingStarts = 0
    /// Holds the next pause until it opens.
    private var pauseGate: StubGate?
    /// How many of the next pauses throw.
    private var failingPauses = 0

    init(calls: Calls) {
        self.calls = calls
    }

    func failStarts(_ count: Int) {
        failingStarts = count
    }

    func hold(_ gate: StubGate) {
        pauseGate = gate
    }

    func failPauses(_ count: Int) {
        failingPauses = count
    }

    func start() throws {
        calls.append("start manager")
        if failingStarts > 0 {
            failingStarts -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Skipped when cancelled, as work that checks for cancellation would be.
    func pause(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        guard !Task.isCancelled else {
            calls.append("cancelled pause \(recordID)")
            return false
        }
        calls.append("pause \(recordID)")
        if let gate = pauseGate {
            pauseGate = nil
            await gate.pass()
        }
        if failingPauses > 0 {
            failingPauses -= 1
            throw .storeFailure
        }
        return true
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DownloadsLifecycleTests {
    private let calls = Calls()
    private let engine: FakeEngine
    private let manager: FakeManager
    let connectionA = UUID()
    let connectionB = UUID()
    /// Every state, for each connection.
    let recordsA: [DownloadRecordDTO]
    let recordsB: [DownloadRecordDTO]

    init() {
        engine = FakeEngine(calls: calls)
        manager = FakeManager(calls: calls)
        recordsA = DownloadState.allCases.map { [connectionA] in Self.record($0, connectionID: connectionA) }
        recordsB = DownloadState.allCases.map { [connectionB] in Self.record($0, connectionID: connectionB) }
    }

    private static func record(_ state: DownloadState, connectionID: UUID) -> DownloadRecordDTO {
        let title = "\(state.rawValue)-\(connectionID)"
        return DownloadRecordDTO(
            id: UUID(), key: MediaKey(serverConnectionID: connectionID, libraryItemId: title), mediaType: .book,
            title: title, state: state, relativeDirectory: title, createdAt: .now,
            media: LocalMediaSnapshot(metadata: .init(title: title)))
    }

    private func makeLifecycle(
        records: (@Sendable (UUID) async throws -> [DownloadRecordDTO])? = nil
    ) -> DownloadsLifecycle {
        let calls = calls
        let stored = recordsA + recordsB
        return DownloadsLifecycle(
            engine: engine, manager: manager,
            records: records ?? { id in stored.filter { $0.key.serverConnectionID == id } },
            startController: { calls.append("start controller") },
            sweep: { calls.append("sweep") })
    }

    private func context(_ connectionID: UUID) -> SessionContext {
        SessionContext(
            identity: SessionIdentity(connectionID: connectionID, userID: "usr"), client: nil, isOffline: false,
            sessionID: 1)
    }

    /// The pauses of `records`' queued and downloading records, in order.
    private func pauses(_ records: [DownloadRecordDTO]) -> [String] {
        records.filter { $0.state == .queued || $0.state == .downloading }.map { "pause \($0.id)" }
    }

    // MARK: - App lifecycle

    /// A launch without a window starts no transfer: the controller's network policy can restart
    /// them, so it starts only with an active phase.
    @Test func launchStartsOnlyTheManagerOnceWithoutActivating() async {
        let lifecycle = makeLifecycle()

        let first = lifecycle.launch()
        let second = lifecycle.launch()
        await first.value
        await second.value

        #expect(calls.all == ["start manager"])
    }

    @Test func activeLaunchesThenActivatesThenSweeps() async {
        let lifecycle = makeLifecycle()

        await lifecycle.handle(scenePhase: .active).value

        #expect(calls.all == ["start manager", "start controller", "activate", "activated", "sweep"])
        #expect(await engine.isActive)
    }

    @Test func everyActiveActivatesButOnlyASuccessfulOneSweeps() async {
        let lifecycle = makeLifecycle()
        await lifecycle.launch().value

        await lifecycle.handle(scenePhase: .active).value
        await engine.set(activates: false)
        await lifecycle.handle(scenePhase: .active).value
        await lifecycle.handle(scenePhase: .inactive).value
        await engine.set(activates: true)
        await lifecycle.handle(scenePhase: .active).value

        #expect(
            calls.all == [
                "start manager", "start controller", "activate", "activated", "sweep", "activate", "activated",
                "activate", "activated", "sweep",
            ])
    }

    @Test func backgroundDeactivates() async {
        let lifecycle = makeLifecycle()
        await lifecycle.handle(scenePhase: .active).value

        await lifecycle.handle(scenePhase: .background).value

        #expect(calls.all.suffix(2) == ["sweep", "deactivate"])
        #expect(await !engine.isActive)
    }

    /// The phases run in call order: a background during an activation deactivates after it.
    @Test func backgroundDuringAGatedActivateEndsDeactivated() async throws {
        let lifecycle = makeLifecycle()
        let gate = StubGate()
        await engine.hold(gate)

        let active = lifecycle.handle(scenePhase: .active)
        await gate.arrived()
        let background = lifecycle.handle(scenePhase: .background)
        for _ in 0..<10 { await Task.yield() }
        #expect(!calls.all.contains("deactivate"))
        gate.open()
        await active.value
        await background.value

        let all = calls.all
        let activated = try #require(all.firstIndex(of: "activated"))
        let deactivated = try #require(all.firstIndex(of: "deactivate"))
        #expect(activated < deactivated)
        #expect(await !engine.isActive)
    }

    /// Until the folders are prepared, nothing starts a transfer: no activation, no controller.
    @Test func failedFolderPreparationActivatesNothingUntilARetrySucceeds() async {
        await manager.failStarts(2)
        let lifecycle = makeLifecycle()

        await lifecycle.launch().value
        #expect(calls.all == ["start manager"])
        await lifecycle.handle(scenePhase: .active).value
        #expect(calls.all == ["start manager", "start manager"])
        await lifecycle.handle(scenePhase: .active).value
        await lifecycle.handle(scenePhase: .active).value

        #expect(
            calls.all == [
                "start manager", "start manager", "start manager", "start controller", "activate", "activated",
                "sweep", "activate", "activated", "sweep",
            ])
    }

    // MARK: - Connections

    @Test(arguments: [SessionEndReason.signOut, .expired])
    func endPausesTheConnectionsRunningRecordsThenQuiescesIt(_ reason: SessionEndReason) async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.sessionWillEnd(reason)

        #expect(calls.all == pauses(recordsA) + ["quiesce \(connectionA)"])
        #expect(pauses(recordsA).count == 2)
    }

    @Test func switchKeepsTheDownloads() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.sessionWillEnd(.switch)
        // The ended session's connection isn't stopped later.
        await lifecycle.sessionWillEnd(.signOut)

        #expect(calls.all.isEmpty)
    }

    @Test func removingAnotherConnectionPausesThenQuiescesOnlyIt() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.connectionRemoved(connectionB)

        #expect(calls.all == pauses(recordsB) + ["quiesce \(connectionB)"])
    }

    @Test func unreadableRecordsStillQuiesce() async {
        let lifecycle = makeLifecycle(records: { _ in throw CocoaError(.fileReadUnknown) })
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.sessionWillEnd(.signOut)

        #expect(calls.all == ["quiesce \(connectionA)"])
    }

    /// The session teardown cancels a participant that runs out of time; the quiesce still follows.
    @Test func cancelledEndStillQuiescesAfterThePauses() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))
        let gate = StubGate()
        await manager.hold(gate)

        let end = Task { await lifecycle.sessionWillEnd(.signOut) }
        await gate.arrived()
        end.cancel()
        gate.open()
        await end.value

        #expect(calls.all == pauses(recordsA) + ["quiesce \(connectionA)"])
    }

    /// A removal stops the downloads only once its credentials are deleted (connectionRemoved),
    /// so a removal that fails earlier keeps them and their progress.
    @Test func removedSessionEndStopsNothing() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.sessionWillEnd(.removed)

        #expect(calls.all.isEmpty)
    }

    /// A cleanup that outlived the teardown's budget finishes before a new session of its
    /// connection starts, so it can't pause or discard what that session starts.
    @Test func newSessionOfTheConnectionWaitsForItsCleanup() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))
        let gate = StubGate()
        await manager.hold(gate)
        let end = Task { await lifecycle.sessionWillEnd(.signOut) }
        await gate.arrived()
        end.cancel()

        let calls = calls
        let start = Task {
            await lifecycle.sessionDidStart(context(connectionA))
            calls.append("started")
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!calls.all.contains("started"))
        gate.open()
        await start.value
        await end.value

        #expect(calls.all == pauses(recordsA) + ["quiesce \(connectionA)", "started"])
    }

    /// A cleanup that couldn't stop the transfers is tried again after the next activation.
    @Test func unfinishedCleanupIsRetriedAfterTheNextActivation() async {
        let lifecycle = makeLifecycle()
        await lifecycle.launch().value
        await lifecycle.sessionDidStart(context(connectionA))
        await engine.failQuiesces(1)
        await lifecycle.sessionWillEnd(.signOut)

        await lifecycle.handle(scenePhase: .active).value
        await lifecycle.handle(scenePhase: .active).value

        let cleanup = pauses(recordsA) + ["quiesce \(connectionA)"]
        #expect(
            calls.all == ["start manager"] + cleanup + ["start controller", "activate", "activated"] + cleanup
                + ["sweep", "activate", "activated", "sweep"])
    }

    /// A pause that wasn't saved leaves a record the next activation would restart, so the
    /// cleanup is tried again after it even though the quiesce succeeded.
    @Test func cleanupWithAFailedPauseIsRetriedAfterTheNextActivation() async {
        let lifecycle = makeLifecycle()
        await lifecycle.launch().value
        await lifecycle.sessionDidStart(context(connectionA))
        await manager.failPauses(1)
        await lifecycle.sessionWillEnd(.signOut)

        await lifecycle.handle(scenePhase: .active).value
        await lifecycle.handle(scenePhase: .active).value

        let cleanup = pauses(recordsA) + ["quiesce \(connectionA)"]
        #expect(
            calls.all == ["start manager"] + cleanup + ["start controller", "activate", "activated"] + cleanup
                + ["sweep", "activate", "activated", "sweep"])
    }

    /// Each connection's retry runs alongside the others': whichever reads its records first
    /// waits there for the other's read, which a retry stuck behind it would never reach.
    @Test func stuckRetryDoesNotHoldUpAnotherConnections() async {
        let holding = Mutex(false)
        let gate = StubGate()
        let reads = Mutex(0)
        let stored = recordsA + recordsB
        let lifecycle = makeLifecycle(records: { id in
            if holding.withLock({ $0 }) {
                if reads.withLock({
                    $0 += 1; return $0
                }) == 1 {
                    await gate.pass()
                } else {
                    gate.open()
                }
            }
            return stored.filter { $0.key.serverConnectionID == id }
        })
        await lifecycle.launch().value
        await engine.failQuiesces(2)
        await lifecycle.connectionRemoved(connectionA)
        await lifecycle.connectionRemoved(connectionB)
        holding.withLock { $0 = true }

        await lifecycle.handle(scenePhase: .active).value

        #expect(reads.withLock { $0 } == 2)
        #expect(calls.all.filter { $0.hasPrefix("quiesce") }.count == 4)
        #expect(calls.all.last == "sweep")
    }

    /// A retry runs outside the phase chain: one that is stuck doesn't keep a background
    /// phase from deactivating.
    @Test func stuckRetryDoesNotHoldUpABackground() async {
        let lifecycle = makeLifecycle()
        await lifecycle.launch().value
        await lifecycle.sessionDidStart(context(connectionA))
        await engine.failQuiesces(1)
        await lifecycle.sessionWillEnd(.signOut)
        let gate = StubGate()
        await manager.hold(gate)

        let active = lifecycle.handle(scenePhase: .active)
        await gate.arrived()
        await lifecycle.handle(scenePhase: .background).value

        #expect(calls.all.last == "deactivate")
        #expect(await !engine.isActive)
        gate.open()
        await active.value
    }

    /// An expiry during a restore, or of another connection, has no session ending to clean up
    /// in; a later session of the connection waits for this cleanup.
    @Test func expiryWithoutARunningSessionPausesThenQuiescesBeforeASignIn() async {
        let lifecycle = makeLifecycle()
        let gate = StubGate()
        await manager.hold(gate)

        lifecycle.connectionExpired(connectionA)
        let calls = calls
        let start = Task {
            await lifecycle.sessionDidStart(context(connectionA))
            calls.append("started")
        }
        await gate.arrived()
        for _ in 0..<10 { await Task.yield() }
        #expect(!calls.all.contains("started"))
        gate.open()
        await start.value

        #expect(calls.all == pauses(recordsA) + ["quiesce \(connectionA)", "started"])
    }

    /// An expiry during a switch's teardown: the session still ends with `.switch`, which
    /// keeps the downloads, so the expiry cleans up itself.
    @Test func expiryOfTheRunningSessionsConnectionCleansUpEvenIfItEndsWithASwitch() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        lifecycle.connectionExpired(connectionA)
        await lifecycle.sessionWillEnd(.switch)
        await lifecycle.sessionDidStart(context(connectionB))
        // Signing in to it again waits for the cleanup.
        await lifecycle.sessionDidStart(context(connectionA))

        #expect(calls.all == pauses(recordsA) + ["quiesce \(connectionA)"])
    }

    /// Once a session of the connection starts, its downloads are that session's.
    @Test func unfinishedCleanupIsDroppedOnceTheConnectionSignsInAgain() async {
        let lifecycle = makeLifecycle()
        await lifecycle.launch().value
        await lifecycle.sessionDidStart(context(connectionA))
        await engine.failQuiesces(1)
        await lifecycle.sessionWillEnd(.signOut)
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.handle(scenePhase: .active).value

        #expect(
            calls.all == ["start manager"] + pauses(recordsA)
                + ["quiesce \(connectionA)", "start controller", "activate", "activated", "sweep"])
    }
}
