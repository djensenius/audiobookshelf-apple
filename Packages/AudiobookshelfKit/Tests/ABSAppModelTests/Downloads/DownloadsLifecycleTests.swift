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

    /// Skipped when cancelled, as work that checks for cancellation would be.
    func discardResumeData(connectionID: UUID) {
        guard !Task.isCancelled else { return calls.append("cancelled discard \(connectionID)") }
        calls.append("discard \(connectionID)")
    }
}

/// A manager that records its calls.
private actor FakeManager: DownloadsLifecycleManager {
    let calls: Calls
    /// How many of the next starts throw.
    private var failingStarts = 0
    /// Holds the next pause until it opens.
    private var pauseGate: StubGate?

    init(calls: Calls) {
        self.calls = calls
    }

    func failStarts(_ count: Int) {
        failingStarts = count
    }

    func hold(_ gate: StubGate) {
        pauseGate = gate
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

    @Test func launchStartsTheManagerThenTheControllerOnceWithoutActivating() async {
        let lifecycle = makeLifecycle()

        let first = lifecycle.launch()
        let second = lifecycle.launch()
        await first.value
        await second.value

        #expect(calls.all == ["start manager", "start controller"])
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

    @Test func failedFolderPreparationIsRetriedAtTheNextActivation() async {
        await manager.failStarts(1)
        let lifecycle = makeLifecycle()

        await lifecycle.handle(scenePhase: .active).value
        await lifecycle.handle(scenePhase: .active).value
        await lifecycle.handle(scenePhase: .active).value

        #expect(calls.all.filter { $0 == "start manager" }.count == 2)
        #expect(calls.all.filter { $0 == "start controller" }.count == 1)
    }

    // MARK: - Connections

    @Test(arguments: [SessionEndReason.signOut, .expired, .removed])
    func endPausesTheConnectionsRunningRecordsThenDiscardsItsResumeData(_ reason: SessionEndReason) async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.sessionWillEnd(reason)

        #expect(calls.all == pauses(recordsA) + ["discard \(connectionA)"])
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

    @Test func removingAnotherConnectionPausesThenDiscardsOnlyIt() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.connectionRemoved(connectionB)

        #expect(calls.all == pauses(recordsB) + ["discard \(connectionB)"])
    }

    @Test func unreadableRecordsStillDiscard() async {
        let lifecycle = makeLifecycle(records: { _ in throw CocoaError(.fileReadUnknown) })
        await lifecycle.sessionDidStart(context(connectionA))

        await lifecycle.sessionWillEnd(.signOut)

        #expect(calls.all == ["discard \(connectionA)"])
    }

    /// The session teardown cancels a participant that runs out of time; the discard still follows.
    @Test func cancelledEndStillDiscardsAfterThePauses() async {
        let lifecycle = makeLifecycle()
        await lifecycle.sessionDidStart(context(connectionA))
        let gate = StubGate()
        await manager.hold(gate)

        let end = Task { await lifecycle.sessionWillEnd(.signOut) }
        await gate.arrived()
        end.cancel()
        gate.open()
        await end.value

        #expect(calls.all == pauses(recordsA) + ["discard \(connectionA)"])
    }
}
