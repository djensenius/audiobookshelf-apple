import ABSAPI
import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSDownloads

/// Activation, relaunch, background wakes, session loss and stopping.
@Suite(.timeLimit(.minutes(1))) struct DownloadEngineLifecycleTests {
    private static let forceQuit = NSURLErrorCancelledReasonUserForceQuitApplication

    @Test func reattachesToSurvivingTasksAndRestartsOrphans() async throws {
        let previous = StubGate()
        let never = StubGate()
        let harness = try await DownloadHarness { request in
            switch request.authorization {
            case "Bearer previous": .status(200, gate: previous)
            case nil: .status(200, gate: never)
            default: .status(200)
            }
        }
        let running = UUID()
        let orphan = UUID()
        let record = try await harness.addRecord(parts: [running, orphan], state: .downloading, partState: .running)
        let base = harness.base
        // What a previous launch left in the session: the running part's transfer and one the
        // engine doesn't know.
        let engine = harness.makeEngine(prepare: { stub in
            var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
            request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
            stub.leaveTask(request, description: running.uuidString)
            stub.leaveTask(URLRequest(url: URL(string: base + "/unknown")!), description: "not a part")
        })

        #expect(await engine.activate())
        previous.open()

        #expect(await engine.nextRecordComplete() != nil)
        let downloads = harness.requests.filter { $0.url?.path().hasSuffix("/download") == true }
        let authorization = Dictionary(uniqueKeysWithValues: downloads.map { ($0.url?.path(), $0.authorization) })
        #expect(downloads.count == 2)
        #expect(authorization["/abs/api/items/li_1/file/1/download"] == "Bearer previous")
        #expect(authorization["/abs/api/items/li_1/file/2/download"] == "Bearer token-1")
        #expect(harness.credentials.calls == [nil])
        let unknown = try #require(harness.session?.leftovers.withLock { $0.last })
        #expect(unknown.state != .running)
        #expect(harness.fileExists("li_1/1.mp3"))
        #expect(harness.fileExists("li_1/2.mp3"))
        #expect(try await harness.store.record(id: record.id) == nil)
    }

    @Test func failedReadCreatesNoSessionAndRetries() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let reads = Mutex(0)
        let base = harness.base
        let engine = harness.makeEngine(
            readRecords: { store in
                guard
                    reads.withLock({
                        $0 += 1; return $0
                    }) > 1
                else { throw TestError() }
                return try await store.allRecords()
            },
            prepare: { stub in
                var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
                request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
                stub.leaveTask(request, description: partID.uuidString)
            })

        #expect(await engine.activate() == false)
        // Without a session, the surviving transfer can't have been cancelled.
        #expect(harness.sessions.withLock { $0.isEmpty })

        #expect(await engine.activate())
        gate.open()

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.map(\.authorization) == ["Bearer previous"])
    }

    @Test func forceQuitCancellationRestartsAtOnce() async throws {
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .failure(code: NSURLErrorCancelled, cancelReason: Self.forceQuit) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        #expect(await engine.activate())

        let update = await engine.next {
            if case .partCompleted = $0 { false } else { true }
        }
        guard case .recordComplete = update else {
            Issue.record("Unexpected \(String(describing: update))")
            return
        }
        #expect(harness.clock.sleeps.isEmpty)
        #expect(harness.requests.count == 2)
    }

    @Test(arguments: [
        NSURLErrorCancelledReasonBackgroundUpdatesDisabled,
        NSURLErrorCancelledReasonInsufficientSystemResources,
    ])
    func backgroundCancellationWaitsForActivation(reason: Int) async throws {
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .failure(code: NSURLErrorCancelled, cancelReason: reason) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        #expect(await engine.activate())
        await harness.waitForCompletions(1)
        await engine.processPendingEvents()

        #expect(harness.requests.count == 1)
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.retryCount == 0)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.clock.sleeps.isEmpty)
        #expect(harness.requests.count == 2)
    }

    @Test func backgroundWakeAfterDeactivateDoesNotRestart() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness {
            $0.stubCount == 1
                ? .failure(code: NSURLErrorCancelled, cancelReason: Self.forceQuit, gate: gate) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        #expect(await engine.activate())
        await harness.waitForRequests(1)

        await engine.deactivate()
        let wake = Task { await engine.handleBackgroundEvents() }
        gate.open()
        await harness.waitForCompletions(1)
        await engine.processPendingEvents()
        harness.session?.finishBackgroundEvents()
        await wake.value

        #expect(harness.requests.count == 1)
        #expect(try await harness.store.part(id: partID)?.state == .queued)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 2)
    }

    @Test func systemCancellationsPastTheCapAreRetried() async throws {
        let harness = try await DownloadHarness {
            $0.stubCount <= 4 ? .failure(code: NSURLErrorCancelled, cancelReason: Self.forceQuit) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        #expect(await engine.activate())

        #expect(await engine.nextFailure(willRetry: true) != nil)
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.clock.sleeps == [.milliseconds(1500)])
        #expect(harness.requests.count == 5)
    }

    @Test func lostSessionIsRecreated() async throws {
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .failure(code: NSURLErrorBackgroundSessionWasDisconnected) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.sessions.withLock { $0.count } == 2)
        #expect(harness.clock.sleeps == [.milliseconds(1500)])
    }

    @Test func sessionThatKeepsDisconnectingWaitsForActivation() async throws {
        let harness = try await DownloadHarness { _ in .failure(code: NSURLErrorBackgroundSessionWasDisconnected) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let lost = DownloadUpdate.sessionUnavailable(
            code: .sessionLost, message: "The download session keeps disconnecting.")
        #expect(await engine.next { $0 == lost } != nil)
        #expect(harness.sessions.withLock { $0.count } == 4)
        #expect(harness.requests.count == 4)
        #expect(harness.clock.sleeps.prefix(3) == [.milliseconds(1500), .seconds(3), .seconds(6)])
    }

    @Test func sessionInUseByAnotherProcessStopsDownloads() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in
            .failure(code: NSURLErrorBackgroundSessionInUseByAnotherProcess, gate: gate)
        }
        let first = UUID()
        let second = UUID()
        try await harness.addRecord(parts: [first, second])
        let engine = harness.makeEngine()
        await engine.start(partIDs: [first, second])
        await harness.waitForRequests(2)

        gate.open()

        let inUse = DownloadUpdate.sessionUnavailable(
            code: .sessionInUse, message: "Another process is using the download session.")
        #expect(await engine.next { $0 == inUse } != nil)
        await harness.waitForCompletions(2)
        await engine.processPendingEvents()
        #expect(try await harness.store.part(id: first)?.state == .queued)
        #expect(try await harness.store.part(id: second)?.state == .queued)
        // No session is created again in this process.
        #expect(await engine.activate() == false)
        await engine.start(partIDs: [first])
        #expect(harness.sessions.withLock { $0.count } == 1)
        #expect(harness.requests.count == 2)
    }

    @Test func backgroundWakeDoesNotRestartButActivateDoes() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let engine = harness.makeEngine()
        #expect(await engine.ensureSession())

        let wake = Task { await engine.handleBackgroundEvents() }
        harness.session?.finishBackgroundEvents()
        await wake.value
        await engine.processPendingEvents()

        #expect(harness.requests.isEmpty)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 1)
    }

    @Test func finishWithoutWaiterIsClaimedByNextWake() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let engine = harness.makeEngine()
        #expect(await engine.ensureSession())

        harness.session?.finishBackgroundEvents()
        await engine.processPendingEvents()
        #expect(await engine.unclaimedBackgroundFinishes == 1)

        await engine.handleBackgroundEvents()
        #expect(await engine.unclaimedBackgroundFinishes == 0)
    }

    @Test func staticEntryWaitsForTheEngine() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let registry = DownloadEngineRegistry()
        let clock = SignallingClock()
        let wake = Task {
            await DownloadEngine.handleBackgroundEvents(registry: registry, timeout: .seconds(10), clock: clock)
        }
        for await _ in clock.started { break }

        let engine = harness.makeEngine(registry: registry)
        #expect(await engine.ensureSession())
        harness.session?.finishBackgroundEvents()

        await wake.value
        #expect(await engine.unclaimedBackgroundFinishes == 0)
    }

    @Test func publicStaticEntryUsesTheRegisteredEngine() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let engine = DownloadEngine(
            store: harness.store, localItems: harness.localItems, credentials: harness.credentials,
            vault: harness.vault, locations: harness.locations, networkAccess: { NetworkAccess(policy: .always) },
            makeSession: harness.sessionFactory())
        #expect(await engine.ensureSession())

        let wake = Task { await DownloadEngine.handleBackgroundEvents() }
        harness.session?.finishBackgroundEvents()

        await wake.value
        #expect(await engine.unclaimedBackgroundFinishes == 0)
    }

    @Test func abandonedWakeDoesNotReleaseTheNextOne() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let registry = DownloadEngineRegistry()

        await DownloadEngine.handleBackgroundEvents(registry: registry, timeout: .seconds(10), clock: RecordingClock())

        let engine = harness.makeEngine(registry: registry)
        #expect(await engine.ensureSession())
        // The abandoned wake's events arrive once the session exists.
        harness.session?.finishBackgroundEvents()
        await engine.processPendingEvents()
        #expect(await engine.unclaimedBackgroundFinishes == 0)
    }

    @Test(arguments: [true, false])
    func stopKeepsOrDiscardsResumeData(keepingResumeData: Bool) async throws {
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .failure(resumeData: Data("resume".utf8)) : .status(200)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: [partID])
        #expect(await engine.nextPermanentFailure() != nil)

        await engine.stop(partIDs: [partID], keepingResumeData: keepingResumeData)

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.hasResumeData == keepingResumeData)
        let blob = harness.vault.fileURL(partID: partID).path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: blob) == keepingResumeData)

        try await harness.store.setState(.queued, forRecord: record.id)
        await engine.start(partIDs: [partID])
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == (keepingResumeData ? [Data("resume".utf8)] : []))
    }

    @Test func stopCancelsRunningTransfer() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)

        await engine.stop(partIDs: [partID], keepingResumeData: false)
        gate.open()
        await engine.processPendingEvents()

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.taskIdentifier == nil)
        #expect(part.retryCount == 0)
        #expect(!harness.fileExists("li_1/1.mp3"))
    }

    @Test func discardResumeDataDeletesBlobs() async throws {
        let harness = try await DownloadHarness { _ in .failure(resumeData: Data("resume".utf8)) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: [partID])
        #expect(await engine.nextPermanentFailure() != nil)
        #expect(try await harness.store.part(id: partID)?.hasResumeData == true)

        await engine.discardResumeData(connectionID: harness.connectionID)

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.hasResumeData == false)
        #expect(part.state == .failed)
        #expect(
            !FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false)))
    }

    @Test func partDeletedWhileLaunchingIsNotRequested() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let store = harness.store
        harness.credentials.hook.withLock { $0 = { _ = try? await store.deleteRecord(record.id) } }
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])
        await engine.processPendingEvents()

        #expect(harness.requests.isEmpty)
        #expect(harness.credentials.calls == [nil])
    }

    @Test func permanentFailureStopsSiblings() async throws {
        let first = StubGate()
        let second = StubGate()
        let harness = try await DownloadHarness { request in
            request.url?.path().contains("/file/1/") == true
                ? .status(404, body: Data(), gate: first) : .status(200, gate: second)
        }
        let failing = UUID()
        let sibling = UUID()
        let record = try await harness.addRecord(parts: [failing, sibling])
        let engine = harness.makeEngine()
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)

        first.open()

        #expect(await engine.nextPermanentFailure() != nil)
        second.open()
        await engine.processPendingEvents()
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        let part = try #require(try await harness.store.part(id: sibling))
        #expect(part.state == .queued)
        #expect(part.taskIdentifier == nil)
        #expect(!harness.fileExists("li_1/2.mp3"))
    }

    @Test func activationFinalisesCompletedRecords() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let record = try await harness.addRecord(parts: [UUID()], state: .downloading, partState: .completed)
        let engine = harness.makeEngine()

        #expect(await engine.activate())

        #expect(await engine.nextRecordComplete() != nil)
        #expect(try await harness.store.record(id: record.id) == nil)
        let item = try await harness.localItems.item(serverConnectionID: harness.connectionID, libraryItemId: "li_1")
        #expect(item?.files.map(\.size) == [11])
        #expect(harness.requests.isEmpty)
    }
}
