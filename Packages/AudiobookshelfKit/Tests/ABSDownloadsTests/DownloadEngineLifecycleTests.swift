import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSData
@testable import ABSDownloads

/// Activation, relaunch, background wakes, session loss and stopping.
@Suite(.timeLimit(.minutes(1))) struct DownloadEngineLifecycleTests {
    private static let forceQuit = NSURLErrorCancelledReasonUserForceQuitApplication
    enum FailureInterruption: String, CaseIterable, Sendable {
        case pause
        case delete
    }
    enum ActivationRetryFailure: String, CaseIterable, Sendable {
        case exhaustedRetry
        case inlineRetryLaunch
        case replaySiblingLaunch
    }

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

    /// Adopting a survivor of a queued record (one a restart couldn't resume, say) starts it.
    @Test func adoptingASurvivorReportsItsRecordStarted() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let base = harness.base
        let engine = harness.makeEngine(prepare: { stub in
            let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
            stub.leaveTask(URLRequest(url: url), description: partID.uuidString)
        })

        #expect(await engine.attachSurvivingTransfers())

        #expect(await engine.next { _ in true } == .recordStarted(recordID: record.id))
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
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
            switch $0 {
            case .partCompleted, .recordStarted: false
            default: true
            }
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

    @Test func sessionInUseByAnotherProcessWaitsForActivation() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness {
            $0.stubCount <= 2
                ? .failure(code: NSURLErrorBackgroundSessionInUseByAnotherProcess, gate: gate) : .status(200)
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
        // No session is created again until the next activation, which tries once more.
        await engine.start(partIDs: [first])
        #expect(harness.sessions.withLock { $0.count } == 1)
        #expect(harness.requests.count == 2)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.sessions.withLock { $0.count } == 2)
        #expect(harness.requests.count == 4)
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

    @Test func wakeThatCantReadTheDownloadsIsAbandoned() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let reads = Mutex(0)
        let engine = harness.makeEngine(readRecords: { store in
            guard
                reads.withLock({
                    $0 += 1; return $0
                }) > 1
            else { throw TestError() }
            return try await store.allRecords()
        })

        // The wake can't read the downloads, so it returns without a session.
        await engine.handleBackgroundEvents()
        #expect(harness.sessions.withLock { $0.isEmpty })
        #expect(await engine.activate())
        // Its events-finished call arrives once the activation has created the session.
        harness.session?.finishBackgroundEvents()
        await engine.processPendingEvents()
        #expect(await engine.unclaimedBackgroundFinishes == 0)

        // A later wake is released by its own events-finished call, which leaves nothing behind.
        let wake = Task { await engine.handleBackgroundEvents() }
        harness.session?.finishBackgroundEvents()
        await wake.value
        await engine.processPendingEvents()
        #expect(await engine.unclaimedBackgroundFinishes == 0)
        #expect(harness.registry.consumeAbandonedWake() == false)
    }

    /// An abandoned wake's events-finished call that comes once a later wake waits is the
    /// abandoned wake's: the later wake waits for its own.
    @Test func lateFinishOfAnAbandonedWakeDoesNotReleaseAWaitingOne() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let reads = Mutex(0)
        let engine = harness.makeEngine(readRecords: { store in
            guard
                reads.withLock({
                    $0 += 1; return $0
                }) > 1
            else { throw TestError() }
            return try await store.allRecords()
        })
        await engine.handleBackgroundEvents()
        #expect(await engine.activate())

        let wake = Task { await engine.handleBackgroundEvents() }
        for _ in 0..<400 {
            if await engine.backgroundWaiterCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await engine.backgroundWaiterCount == 1)
        harness.session?.finishBackgroundEvents()
        await engine.processPendingEvents()
        #expect(await engine.backgroundWaiterCount == 1)

        harness.session?.finishBackgroundEvents()
        await wake.value
        #expect(await engine.unclaimedBackgroundFinishes == 0)
        #expect(harness.registry.consumeAbandonedWake() == false)
    }

    @Test func timedOutWaitLeavesNoEntry() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let registry = DownloadEngineRegistry()

        // The timer fires before anything registers: the wait gives up and leaves nothing.
        #expect(await registry.engine(timeout: .seconds(10), clock: RecordingClock()) == nil)
        #expect(registry.waiterCount == 0)

        let engine = harness.makeEngine(registry: registry)
        #expect(registry.waiterCount == 0)
        #expect(await registry.engine(timeout: .seconds(10), clock: RecordingClock()) === engine)
        #expect(registry.waiterCount == 0)
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

    /// A part whose transfer fails while its resume data is being discarded keeps that failure
    /// (and its retry): the discard only clears the part's resume-data flag.
    @Test func discardResumeDataKeepsAStateWrittenMeanwhile() async throws {
        let keyStore = FlakyKeyStore()
        let gate = StubGate()
        let harness = try await DownloadHarness(keyStore: keyStore) {
            switch $0.stubCount {
            case 1: .failure(resumeData: Data("resume-1".utf8))
            case 2: .failure(resumeData: Data("resume-2".utf8), gate: gate)
            default: .status(200)
            }
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let (holding, holdStarted) = AsyncStream.makeStream(of: Void.self)
        let release = StubGate()
        let holdsNextRead = Mutex(false)
        let engine = harness.makeEngine(
            clock: SignallingClock(),
            readRecords: { store in
                let records = try await store.allRecords()
                if holdsNextRead.withLock({ holds in
                    defer { holds = false }
                    return holds
                }) {
                    holdStarted.yield()
                    await withCheckedContinuation { continuation in release.run { continuation.resume() } }
                }
                return records
            })
        await engine.start(partIDs: [partID])
        #expect(await engine.nextFailure(willRetry: true) != nil)
        // The Keychain is unavailable for the restart, so the part runs and keeps its flag.
        keyStore.failNextLoad()
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(2)
        try #require(try await harness.store.part(id: partID)?.hasResumeData == true)

        // The discard's read is held while the transfer fails and its retry is scheduled.
        holdsNextRead.withLock { $0 = true }
        let discarding = Task { await engine.discardResumeData(connectionID: harness.connectionID) }
        _ = await holding.first { _ in true }
        gate.open()
        #expect(await engine.nextFailure(willRetry: true) != nil)
        release.open()
        await discarding.value

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .failed)
        #expect(part.taskIdentifier == nil)
        #expect(part.lastError != nil)
        #expect(!part.hasResumeData)
        #expect(
            !FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false)))
    }

    /// After a relaunch, a sign-out can come before anything attached the session: the
    /// quiesce attaches first, so a surviving transfer with the old token is stopped too.
    @Test func quiesceStopsASurvivorOfARelaunch() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let base = harness.base
        let engine = harness.makeEngine(prepare: { stub in
            var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
            request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
            stub.leaveTask(request, description: partID.uuidString)
        })

        #expect(await engine.quiesce(connectionID: harness.connectionID))

        let survivor = try #require(harness.session?.leftovers.withLock { $0.first })
        #expect(survivor.state != .running)
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.taskIdentifier == nil)
        #expect(!part.hasResumeData)
        #expect(
            !FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false)))
    }

    /// Without a session nothing can be stopped, so the quiesce reports it didn't finish.
    @Test func quiesceWithoutASessionReportsItDidNotFinish() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        try await harness.addRecord(parts: [UUID()], state: .downloading, partState: .running)
        let engine = harness.makeEngine(readRecords: { _ in throw TestError() })

        #expect(await engine.quiesce(connectionID: harness.connectionID) == false)
        #expect(harness.sessions.withLock { $0.isEmpty })
    }

    /// Without a session the transfers can't be stopped, but the resume data sealed with the old
    /// credentials is deleted at once, and a transfer that survived the relaunch is cancelled,
    /// not adopted, once the session is created, even after signing in again meanwhile.
    @Test func quiesceWithoutASessionDeletesResumeDataAndLaterCancelsSurvivors() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        try harness.vault.seal(Data("resume".utf8), partID: partID, credentialTag: Data("previous".utf8))
        _ = try await harness.store.updatePart(partID: partID, hasResumeData: true)
        let blob = harness.vault.fileURL(partID: partID).path(percentEncoded: false)
        let reads = Mutex(0)
        let base = harness.base
        let engine = harness.makeEngine(
            readRecords: { store in
                // Only the first activation's read fails.
                let read = reads.withLock {
                    $0 += 1
                    return $0
                }
                if read == 1 { throw TestError() }
                return try await store.allRecords()
            },
            prepare: { stub in
                var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
                request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
                stub.leaveTask(request, description: partID.uuidString)
            })

        #expect(await engine.quiesce(connectionID: harness.connectionID) == false)
        #expect(harness.sessions.withLock { $0.isEmpty })
        #expect(try await harness.store.part(id: partID)?.hasResumeData == false)
        #expect(!FileManager.default.fileExists(atPath: blob))

        // Signed in again (the record is still downloading), then the app comes to the foreground.
        #expect(await engine.activate())

        let survivor = try #require(harness.session?.leftovers.withLock { $0.first })
        #expect(survivor.state != .running)
        // The part starts again with the new credentials.
        await harness.waitForRequests(2)
        #expect(harness.requests.map(\.authorization) == ["Bearer previous", "Bearer token-1"])
        #expect(try await harness.store.part(id: partID)?.hasResumeData == false)
        #expect(!FileManager.default.fileExists(atPath: blob))
        never.open()
    }

    /// A transfer that survived the relaunch and finished before or while the session was
    /// created was made with the old credentials: its file isn't adopted, and its part starts
    /// again with the new ones.
    @Test func quiesceWithoutASessionDropsASurvivorThatFinished() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { request in
            request.authorization == "Bearer previous" ? .status(200) : .status(200, gate: never)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let reads = Mutex(0)
        let base = harness.base
        let engine = harness.makeEngine(
            readRecords: { store in
                let read = reads.withLock {
                    $0 += 1
                    return $0
                }
                if read == 1 { throw TestError() }
                return try await store.allRecords()
            },
            prepare: { stub in
                var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
                request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
                stub.leaveTask(request, description: partID.uuidString)
                // Finished before the engine lists the session's tasks, so only its completion
                // reaches the engine.
                let deadline = Date.now.addingTimeInterval(10)
                while stub.leftovers.withLock({ $0.first?.state }) != .completed, Date.now < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            })
        #expect(await engine.quiesce(connectionID: harness.connectionID) == false)

        #expect(await engine.activate())

        await harness.waitForRequests(2)
        #expect(harness.requests.map(\.authorization) == ["Bearer previous", "Bearer token-1"])
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .running)
        #expect(part.hasResumeData == false)
        #expect(
            !FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false)))
        never.open()
    }

    /// Resume data that couldn't be deleted, because the downloads couldn't be read, leaves the
    /// quiesce unfinished, so it's tried again.
    @Test func quiesceThatCouldNotDeleteTheResumeDataReportsItDidNotFinish() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .paused, partState: .queued)
        try harness.vault.seal(Data("resume".utf8), partID: partID, credentialTag: Data("previous".utf8))
        _ = try await harness.store.updatePart(partID: partID, hasResumeData: true)
        let goodReads = Mutex(Int.max)
        let engine = harness.makeEngine(readRecords: { store in
            let fails = goodReads.withLock {
                $0 -= 1
                return $0 < 0
            }
            if fails { throw TestError() }
            return try await store.allRecords()
        })
        #expect(await engine.activate())
        // The quiesce's own read succeeds; the discard's fails.
        goodReads.withLock { $0 = 1 }

        #expect(await engine.quiesce(connectionID: harness.connectionID) == false)
        #expect(try await harness.store.part(id: partID)?.hasResumeData == true)
    }

    /// Resume data that couldn't be deleted (here, a read-only folder) stays flagged, both when
    /// its transfer is stopped and in the discard, so the quiesce reports it and a later one
    /// deletes it.
    @Test func quiesceThatCouldNotDeleteABlobKeepsItFlaggedForALaterOne() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        #expect(await engine.activate())
        await harness.waitForRequests(1)
        try harness.vault.seal(Data("resume".utf8), partID: partID, credentialTag: Data("previous".utf8))
        let blob = harness.vault.fileURL(partID: partID)
        let folder = blob.deletingLastPathComponent().path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        #expect(await engine.quiesce(connectionID: harness.connectionID) == false)
        #expect(FileManager.default.fileExists(atPath: blob.path(percentEncoded: false)))
        #expect(try await harness.store.part(id: partID)?.hasResumeData == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        #expect(await engine.quiesce(connectionID: harness.connectionID))
        #expect(!FileManager.default.fileExists(atPath: blob.path(percentEncoded: false)))
        #expect(try await harness.store.part(id: partID)?.hasResumeData == false)
        never.open()
    }

    /// With a session but no readable downloads, the transfers the engine knows of are still
    /// stopped: they run with the old credentials. The quiesce reports it didn't finish.
    @Test func quiesceThatCouldNotReadTheDownloadsStillStopsKnownTransfers() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let failsReads = Mutex(false)
        let engine = harness.makeEngine(readRecords: { store in
            if failsReads.withLock({ $0 }) { throw TestError() }
            return try await store.allRecords()
        })
        #expect(await engine.activate())
        await harness.waitForRequests(1)
        #expect(try await harness.store.part(id: partID)?.state == .running)
        failsReads.withLock { $0 = true }

        #expect(await engine.quiesce(connectionID: harness.connectionID) == false)

        #expect(try await harness.store.part(id: partID)?.state == .queued)
        let tasks = await harness.session?.session.allTasks ?? []
        #expect(tasks.allSatisfy { $0.state != .running })
        never.open()
    }

    /// A caller that paused a record to restart it, while a quiesce of its server ran from
    /// start to end, doesn't resume it: the quiesce passed over the paused record. A later
    /// resume (by the user, signed in again) still does.
    @Test func resumeUnlessQuiescedSinceLeavesARecordPausedAfterAQuiesce() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        #expect(await engine.activate())
        await harness.waitForRequests(1)
        let generation = await engine.quiesceGeneration()
        #expect(try await engine.pause(recordID: record.id))
        #expect(await engine.quiesce(connectionID: harness.connectionID))

        #expect(try await engine.resume(recordID: record.id, unlessQuiescedSince: generation) == false)

        #expect(try await harness.store.record(id: record.id)?.state == .paused)
        #expect(await harness.session?.session.allTasks.allSatisfy { $0.state != .running } ?? true)
        #expect(try await engine.resume(recordID: record.id))
        await harness.waitForRequests(2)
        never.open()
    }

    /// A part failing for good stops its siblings and may replay a start that overlapped it,
    /// after which its transfer would run with the old token: the quiesce waits for it, then
    /// stops what it started. In production the sign-out pauses the record first.
    @Test(arguments: [false, true])
    func quiesceWaitsForAFailureForGoodAndStopsItsReplay(pausing: Bool) async throws {
        let failure = StubGate()
        let never = StubGate()
        let failingRequests = Mutex(0)
        let harness = try await DownloadHarness { request in
            guard request.url?.path().contains("/file/1/") == true else { return .status(200, gate: never) }
            let count = failingRequests.withLock {
                $0 += 1
                return $0
            }
            return count == 1 ? .status(404, body: Data(), gate: failure) : .status(200, gate: never)
        }
        let failing = UUID()
        let sibling = UUID()
        let record = try await harness.addRecord(parts: [failing, sibling])
        let seams = FailureSeams()
        seams.hold(failing)
        let (replays, replayReached) = AsyncStream.makeStream(of: Void.self)
        let releaseReplay = StubGate()
        let engine = harness.makeEngine(
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure,
            beforeReplayStart: { _ in
                replayReached.yield()
                await withCheckedContinuation { continuation in releaseReplay.run { continuation.resume() } }
            })
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)
        failure.open()
        _ = await seams.nextHeld()
        // A start while the part is settling is replayed once its failure is handled; the replay
        // has queued the record when the sign-out begins.
        await engine.start(partIDs: [failing])
        seams.release()
        _ = await replays.first { _ in true }

        let finished = Mutex(false)
        let quiescing = Task {
            defer { finished.withLock { $0 = true } }
            return await engine.quiesce(connectionID: harness.connectionID) {
                if pausing { _ = try? await engine.pause(recordID: record.id) }
            }
        }
        while await engine.failureWaiterCount == 0, !finished.withLock({ $0 }) { await Task.yield() }
        #expect(await engine.failureWaiterCount > 0)
        releaseReplay.open()
        #expect(await quiescing.value)
        _ = await seams.nextSettled()

        let running = await harness.session?.session.allTasks.filter { $0.state == .running } ?? []
        #expect(running.isEmpty)
        for partID in [failing, sibling] {
            #expect(try await harness.store.part(id: partID)?.hasResumeData == false)
        }
        if pausing { #expect(try await harness.store.record(id: record.id)?.state == .paused) }
        never.open()
    }

    /// The replay's launch can fail the same part for good again (here the server now needs
    /// custom headers) while the first failure is still under way: the quiesce keeps waiting
    /// until that one has finished too, not only the one that ended first.
    @Test func quiesceWaitsForTheOuterFailureWhenTheReplayFailsThePartAgain() async throws {
        let failure = StubGate()
        let harness = try await DownloadHarness { _ in .status(404, body: Data(), gate: failure) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let seams = FailureSeams()
        seams.hold(partID)
        let (replays, replayReached) = AsyncStream.makeStream(of: Void.self)
        let releaseReplay = StubGate()
        let (outerSettles, outerSettling) = AsyncStream.makeStream(of: Void.self)
        let releaseOuter = StubGate()
        let settled = Mutex(0)
        let engine = harness.makeEngine(
            beforeStoppingSiblings: seams.beforeStoppingSiblings,
            afterPermanentFailure: { _ in
                // The replay's failure settles first, within the outer failure's replay.
                let count = settled.withLock {
                    $0 += 1
                    return $0
                }
                guard count == 2 else { return }
                outerSettling.yield()
                await withCheckedContinuation { continuation in releaseOuter.run { continuation.resume() } }
            },
            beforeReplayStart: { _ in
                replayReached.yield()
                await withCheckedContinuation { continuation in releaseReplay.run { continuation.resume() } }
            })
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        failure.open()
        #expect(await seams.nextHeld() == partID)
        await engine.start(partIDs: [partID])
        harness.credentials.configurationOverride.withLock {
            $0 = try? APIClientConfiguration(
                baseURL: URL(string: harness.base)!, customHeaders: ["CF-Access-Client-Secret": "secret"])
        }
        seams.release()
        _ = await replays.first { _ in true }

        let finished = Mutex(false)
        let quiescing = Task {
            defer { finished.withLock { $0 = true } }
            return await engine.quiesce(connectionID: harness.connectionID)
        }
        while await engine.failureWaiterCount == 0, !finished.withLock({ $0 }) { await Task.yield() }
        #expect(await engine.failureWaiterCount > 0)
        releaseReplay.open()
        _ = await outerSettles.first { _ in true }
        // The replay's failure has ended; the outer one hasn't.
        while await engine.failureWaiterCount == 0, !finished.withLock({ $0 }) { await Task.yield() }
        #expect(!finished.withLock { $0 })
        releaseOuter.open()

        #expect(await quiescing.value)
        #expect(settled.withLock { $0 } == 2)
        #expect(try await harness.store.part(id: partID)?.state == .failed)
        #expect(harness.requests.count == 1)
    }

    /// A sign-out pauses only queued and downloading records, so a `failed` one stays failed.
    /// A replay of a plain start that overlapped its failure would queue it again, and the next
    /// activation restart it: while the server is quiesced, the replay is skipped.
    @Test func quiesceKeepsAReplayFromQueuingAFailedRecord() async throws {
        let failure = StubGate()
        let never = StubGate()
        let counter = PathCounter()
        let harness = try await DownloadHarness { request in
            counter.next(request) == 1 ? .status(404, body: Data(), gate: failure) : .status(200, gate: never)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let seams = FailureSeams()
        seams.hold(partID)
        let engine = harness.makeEngine(
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure)
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        failure.open()
        #expect(await seams.nextHeld() == partID)
        await engine.start(partIDs: [partID])
        #expect(try await harness.store.record(id: record.id)?.state == .failed)

        let (pauses, paused) = AsyncStream.makeStream(of: Void.self)
        // The lifecycle's pause leaves the failed record as it is.
        let quiescing = Task { await engine.quiesce(connectionID: harness.connectionID) { paused.yield() } }
        _ = await pauses.first { _ in true }
        seams.release()

        #expect(await seams.nextSettled() == partID)
        #expect(await quiescing.value)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(harness.requests.count == 1)
        never.open()
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

    @Test func requeuedFailedRecordResumesItsSiblings() async throws {
        let gate = StubGate()
        let seen = Mutex<Set<String>>([])
        // A resumed task repeats the last fresh request, so only each path's first answer fails.
        let harness = try await DownloadHarness { request in
            let path = request.url?.path() ?? ""
            guard seen.withLock({ $0.insert(path).inserted }) else { return .status(200) }
            return path.contains("/file/1/")
                ? .status(404, body: Data(), gate: gate) : .failure(resumeData: Data("resume-b".utf8))
        }
        let failing = UUID()
        let sibling = UUID()
        let record = try await harness.addRecord(parts: [failing, sibling])
        let engine = harness.makeEngine(clock: SignallingClock())
        await engine.start(partIDs: [failing, sibling])
        #expect(await engine.nextFailure(willRetry: true) != nil)

        gate.open()

        #expect(await engine.nextPermanentFailure() != nil)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(try await harness.store.part(id: sibling)?.hasResumeData == true)
        try await harness.store.setState(.queued, forRecord: record.id)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [Data("resume-b".utf8)])
    }

    /// The resume's start finds the failing part still settling and skips it; the replay restarts it.
    @Test func resumeStartingWhileFailureSettlesIsFollowedByAReplayOfThePart() async throws {
        let first = StubGate()
        let resumed = StubGate()
        let requests = Mutex(0)
        let harness = try await DownloadHarness { _ in
            let count = requests.withLock {
                $0 += 1; return $0
            }
            return count == 1 ? .status(404, body: Data(), gate: first) : .status(200, gate: resumed)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let (resumeReads, resumeReadStarted) = AsyncStream.makeStream(of: DownloadState?.self)
        let releaseResumeRead = StubGate()
        let seams = FailureSeams()
        seams.hold(partID)
        let engine = harness.makeEngine(
            readRecord: { store, id in
                let record = try await store.record(id: id)
                resumeReadStarted.yield(record?.state)
                await withCheckedContinuation { continuation in
                    releaseResumeRead.run { continuation.resume() }
                }
                return record
            },
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure,
            startFoundSettling: seams.startFoundSettling)
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)

        let resuming = Task { try await engine.resume(recordID: record.id) }
        #expect(await resumeReads.first { _ in true } == .queued)
        first.open()
        _ = await seams.nextHeld()

        // The resume's start runs while the part is settling, and leaves it to the replay.
        releaseResumeRead.open()
        #expect(await seams.nextFoundSettling() == [partID])
        #expect(try await resuming.value)
        #expect(harness.requests.count == 1)

        seams.release()
        _ = await seams.nextSettled()
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        #expect(try await harness.store.part(id: partID)?.state == .running)
        await harness.waitForRequests(2)
        let task = try #require(
            await harness.session?.session.allTasks.first { $0.taskDescription == partID.uuidString })
        #expect(task.state == .running)

        resumed.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(try await harness.store.record(id: record.id) == nil)
    }

    @Test func permanentFailureFromResumeLaunchIsNotReplayed() async throws {
        let harness = try await DownloadHarness { _ in .status(404) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: .failed, partState: .failed)
        let engine = harness.makeEngine()

        #expect(try await engine.resume(recordID: record.id))
        #expect(await engine.nextPermanentFailure() != nil)

        #expect(harness.requests.count == 1)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(try await harness.store.part(id: partID)?.state == .failed)
    }

    @Test func resumeBeforeSiblingStopsRestartsEveryStoppedPart() async throws {
        let failure = StubGate()
        let replay = StubGate()
        let never = StubGate()
        let counter = PathCounter()
        let failing = UUID()
        let sibling = UUID()
        let harness = try await DownloadHarness { request in
            let count = counter.next(request)
            if request.url?.path().contains("/file/1/") == true {
                return count == 1 ? .status(404, body: Data(), gate: failure) : .status(200, gate: replay)
            }
            return .status(200, gate: never)
        }
        let record = try await harness.addRecord(parts: [failing, sibling])
        let seams = FailureSeams()
        seams.hold(failing)
        let engine = harness.makeEngine(
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure)
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)

        failure.open()
        _ = await seams.nextHeld()
        #expect(try await harness.store.part(id: failing)?.state == .failed)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)

        // The failure has saved A as failed, but has not registered B's stop yet.
        #expect(try await engine.resume(recordID: record.id))
        let siblingTask = try #require(
            await harness.session?.session.allTasks.first { $0.taskDescription == sibling.uuidString })
        #expect(siblingTask.state == .running)

        seams.release()
        _ = await seams.nextSettled()
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        #expect(try await harness.store.part(id: failing)?.state == .running)
        let siblingPart = try #require(try await harness.store.part(id: sibling))
        #expect(siblingPart.state == .running)
        #expect(siblingPart.retryCount == 0)
        await harness.waitForRequests(4)
        #expect(harness.requestCount(file: 1) == 2)
        #expect(harness.requestCount(file: 2) == 2)

        replay.open()
        never.open()
        #expect(await engine.nextRecordComplete() != nil)
    }

    @Test(arguments: FailureInterruption.allCases)
    func pauseOrDeleteBeforeFailureReplayIsRespected(_ interruption: FailureInterruption) async throws {
        let failure = StubGate()
        let releaseFailure = StubGate()
        let never = StubGate()
        let failing = UUID()
        let sibling = UUID()
        let harness = try await DownloadHarness { request in
            request.url?.path().contains("/file/1/") == true
                ? .status(404, body: Data(), gate: failure) : .status(200, gate: never)
        }
        let record = try await harness.addRecord(parts: [failing, sibling])
        let (failureWriteFinished, failureWritten) = AsyncStream.makeStream(of: Void.self)
        let (failureSettled, failureSettledContinuation) = AsyncStream.makeStream(of: Void.self)
        let engine = harness.makeEngine(
            beforeStoppingSiblings: { partID in
                guard partID == failing else { return }
                failureWritten.yield()
                await withCheckedContinuation { continuation in
                    releaseFailure.run { continuation.resume() }
                }
            },
            afterPermanentFailure: { _ in
                failureSettledContinuation.yield()
            })
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)
        failure.open()
        _ = await failureWriteFinished.first { _ in true }

        #expect(try await engine.resume(recordID: record.id))
        switch interruption {
        case .pause:
            #expect(try await engine.pause(recordID: record.id))
        case .delete:
            try await harness.store.deleteRecord(record.id)
        }

        releaseFailure.open()
        #expect(await engine.nextPermanentFailure() != nil)
        _ = await failureSettled.first { _ in true }
        #expect(harness.requests.count == 2)
        let activeTasks = await harness.session?.session.allTasks.filter {
            $0.state == .running || $0.state == .suspended
        }
        #expect(activeTasks?.isEmpty == true)
        switch interruption {
        case .pause:
            #expect(try await harness.store.record(id: record.id)?.state == .paused)
            #expect(try await harness.store.part(id: sibling)?.state == .queued)
        case .delete:
            #expect(try await harness.store.record(id: record.id) == nil)
        }
    }

    /// The replay window's second half: a resume overlapped A's failure, and its replay has
    /// queued the record but not started the parts yet. A pause or delete there is respected:
    /// the replay's start launches nothing.
    @Test(arguments: FailureInterruption.allCases)
    func pauseOrDeleteBetweenReplayWriteAndStartIsRespected(_ interruption: FailureInterruption) async throws {
        let failure = StubGate()
        let never = StubGate()
        let failing = UUID()
        let sibling = UUID()
        let harness = try await DownloadHarness { request in
            request.url?.path().contains("/file/1/") == true
                ? .status(404, body: Data(), gate: failure) : .status(200, gate: never)
        }
        let record = try await harness.addRecord(parts: [failing, sibling])
        let seams = FailureSeams()
        seams.hold(failing)
        let (replayWrites, replayWritten) = AsyncStream.makeStream(of: UUID.self)
        let releaseReplay = StubGate()
        let engine = harness.makeEngine(
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure,
            beforeReplayStart: { partID in
                replayWritten.yield(partID)
                await withCheckedContinuation { continuation in
                    releaseReplay.run { continuation.resume() }
                }
            })
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)
        failure.open()
        #expect(await seams.nextHeld() == failing)

        #expect(try await engine.resume(recordID: record.id))
        seams.release()
        #expect(await replayWrites.first { _ in true } == failing)
        #expect(try await harness.store.record(id: record.id)?.state == .queued)
        switch interruption {
        case .pause:
            #expect(try await engine.pause(recordID: record.id))
        case .delete:
            try await harness.store.deleteRecord(record.id)
        }

        releaseReplay.open()
        #expect(await seams.nextSettled() == failing)
        #expect(harness.requests.count == 2)
        let activeTasks = await harness.session?.session.allTasks.filter {
            $0.state == .running || $0.state == .suspended
        }
        #expect(activeTasks?.isEmpty == true)
        switch interruption {
        case .pause:
            #expect(try await harness.store.record(id: record.id)?.state == .paused)
            #expect(try await harness.store.part(id: failing)?.state == .queued)
            #expect(try await harness.store.part(id: sibling)?.state == .queued)
        case .delete:
            #expect(try await harness.store.record(id: record.id) == nil)
        }
        never.open()
    }

    /// Window "i": a resume that begins while A's failure stops its siblings bumps its generation
    /// after the failure began. Its own start skips A, which is settling, and starts B once B's
    /// stop is done; the replay then starts A with a fresh budget and skips B, which is already
    /// launching or running, so B isn't launched twice.
    @Test func resumeDuringSiblingStopsLaunchesEachPartOnce() async throws {
        let replay = StubGate()
        let resumed = StubGate()
        let never = StubGate()
        let counter = PathCounter()
        let harness = try await DownloadHarness { request in
            let count = counter.next(request)
            if request.url?.path().contains("/file/1/") == true {
                return count <= 3 ? .status(503) : .status(200, gate: replay)
            }
            return count == 1 ? .status(200, gate: never) : .status(200, gate: resumed)
        }
        let failing = UUID()
        let sibling = UUID()
        let record = try await harness.addRecord(parts: [failing, sibling])
        let (cancelling, cancelStarted) = AsyncStream.makeStream(of: Void.self)
        let releaseCancel = StubGate()
        let cancelHeld = Mutex(false)
        let seams = FailureSeams()
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 2),
            cancel: { task in
                if !cancelHeld.withLock({ held in
                    defer { held = true }
                    return held
                }) {
                    cancelStarted.yield()
                    await withCheckedContinuation { continuation in releaseCancel.run { continuation.resume() } }
                }
                return await task.cancelByProducingResumeData()
            },
            afterPermanentFailure: seams.afterPermanentFailure, startFoundSettling: seams.startFoundSettling)
        await engine.start(partIDs: [failing, sibling])

        // A used up its retries and failed for good; its stop of B is under way.
        _ = await cancelling.first { _ in true }
        #expect(try await harness.store.part(id: failing)?.retryCount == 3)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)

        let resuming = Task { try await engine.resume(recordID: record.id) }
        #expect(await seams.nextFoundSettling() == [failing])
        releaseCancel.open()
        #expect(try await resuming.value)
        #expect(await seams.nextSettled() == failing)

        await harness.waitForRequests(file: 1, count: 4)
        await harness.waitForRequests(file: 2, count: 2)
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        let failingPart = try #require(try await harness.store.part(id: failing))
        #expect(failingPart.state == .running)
        #expect(failingPart.retryCount == 0)
        #expect(try await harness.store.part(id: sibling)?.state == .running)
        let siblingTasks = await harness.session?.session.allTasks.filter {
            $0.taskDescription == sibling.uuidString && ($0.state == .running || $0.state == .suspended)
        }
        #expect(siblingTasks?.count == 1)

        replay.open()
        resumed.open()
        never.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requestCount(file: 1) == 4)
        #expect(harness.requestCount(file: 2) == 2)
    }

    /// A part A that failed for good while a resume was pending, replayed, and then failed again,
    /// the resume still pending (it is held at its read). The replay's attempt was launched for
    /// that resume, so its failure is final.
    private struct ReplayedFailure {
        let harness: DownloadHarness
        let engine: DownloadEngine
        let seams: FailureSeams
        let record: DownloadRecordDTO
        let failing: UUID
        let sibling: UUID
        let secondFailure: StubGate
        let never: StubGate
        let releaseResumeRead: StubGate
        let resuming: Task<Bool, any Error>
    }

    /// Returns once the replay has launched A and B again; A's second attempt waits on `secondFailure`.
    private func startReplayedFailure() async throws -> ReplayedFailure {
        let first = StubGate()
        let second = StubGate()
        let never = StubGate()
        let counter = PathCounter()
        let harness = try await DownloadHarness { request in
            let count = counter.next(request)
            if request.url?.path().contains("/file/1/") == true {
                switch count {
                case 1: return .status(404, body: Data(), gate: first)
                case 2: return .status(404, body: Data(), gate: second)
                default: return .status(200)
                }
            }
            return .status(200, gate: never)
        }
        let failing = UUID()
        let sibling = UUID()
        let record = try await harness.addRecord(parts: [failing, sibling])
        let (resumeReads, resumeReadStarted) = AsyncStream.makeStream(of: Void.self)
        let releaseResumeRead = StubGate()
        let seams = FailureSeams()
        seams.hold(failing)
        let engine = harness.makeEngine(
            readRecord: { store, id in
                let record = try await store.record(id: id)
                resumeReadStarted.yield()
                await withCheckedContinuation { continuation in
                    releaseResumeRead.run { continuation.resume() }
                }
                return record
            },
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure)
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)
        first.open()
        _ = await seams.nextHeld()
        let resuming = Task { try await engine.resume(recordID: record.id) }
        _ = await resumeReads.first { _ in true }

        seams.release()
        #expect(await seams.nextSettled() == failing)
        await harness.waitForRequests(4)
        return ReplayedFailure(
            harness: harness, engine: engine, seams: seams, record: record, failing: failing, sibling: sibling,
            secondFailure: second, never: never, releaseResumeRead: releaseResumeRead, resuming: resuming)
    }

    /// The cap: the replayed attempt's failure is not replayed again for the same resume, even
    /// when the record's `failed` state couldn't be saved. The resume's own start then makes one
    /// more attempt, as it would after any failure it didn't see.
    @Test func replayedAttemptFailingWhileResumeIsPendingIsNotReplayedAgain() async throws {
        let scenario = try await startReplayedFailure()
        let harness = scenario.harness
        await harness.store.failNextCommit(with: TestError())
        scenario.secondFailure.open()

        #expect(await scenario.seams.nextSettled() == scenario.failing)
        #expect(harness.requestCount(file: 1) == 2)
        #expect(try await harness.store.part(id: scenario.failing)?.state == .failed)
        #expect(try await harness.store.record(id: scenario.record.id)?.state == .downloading)

        scenario.releaseResumeRead.open()
        #expect(try await scenario.resuming.value)
        scenario.never.open()
        #expect(await scenario.engine.nextRecordComplete() != nil)
    }

    /// The replayed attempt's failure fails the record although its resume is still pending:
    /// the resume's start then finds the record failed, and makes no further attempt.
    @Test func replayedAttemptFailingWhileResumeIsPendingFailsTheRecord() async throws {
        let scenario = try await startReplayedFailure()
        let harness = scenario.harness
        scenario.secondFailure.open()

        #expect(await scenario.seams.nextSettled() == scenario.failing)
        #expect(harness.requestCount(file: 1) == 2)
        #expect(try await harness.store.record(id: scenario.record.id)?.state == .failed)
        #expect(try await harness.store.part(id: scenario.failing)?.state == .failed)
        #expect(try await harness.store.part(id: scenario.sibling)?.state == .queued)

        scenario.releaseResumeRead.open()
        #expect(try await scenario.resuming.value)
        #expect(harness.requestCount(file: 1) == 2)
        #expect(harness.requestCount(file: 2) == 2)
        #expect(try await harness.store.record(id: scenario.record.id)?.state == .failed)
        #expect(try await harness.store.part(id: scenario.failing)?.state == .failed)
        #expect(try await harness.store.part(id: scenario.sibling)?.state == .queued)
        scenario.never.open()
    }

    /// A part that used up its retries fails for good; the replay of a resume that overlapped
    /// that failure starts it with a fresh budget, in the store too.
    @Test func replayAfterRetryExhaustionStartsWithAFreshRetryBudget() async throws {
        let counter = PathCounter()
        let replay = StubGate()
        let harness = try await DownloadHarness { request in
            switch counter.next(request) {
            case 1, 2, 3: .status(503)
            case 4: .status(503, gate: replay)
            default: .status(200)
            }
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let seams = FailureSeams()
        seams.hold(partID)
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 2),
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure)
        await engine.start(partIDs: [partID])
        _ = await seams.nextHeld()
        #expect(try await harness.store.part(id: partID)?.retryCount == 3)

        #expect(try await engine.resume(recordID: record.id))
        seams.release()
        _ = await seams.nextSettled()

        #expect(try await harness.store.part(id: partID)?.retryCount == 0)
        #expect(try await harness.store.part(id: partID)?.state == .running)
        replay.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 5)
    }

    /// A resume replay doesn't restart the parts of a record that another part failed for good
    /// after the resume: that failure is newer than the resume's `queued`. (The events of
    /// transfers are handled one at a time, so the other failure comes from a launch: here the
    /// resume's own start can't save B's state.)
    @Test func staleResumeReplayDoesNotOverwriteANewerFailure() async throws {
        let failing = StubGate()
        let never = StubGate()
        let harness = try await DownloadHarness { request in
            request.url?.path().contains("/file/1/") == true
                ? .status(404, body: Data(), gate: failing) : .status(200, gate: never)
        }
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let record = try await harness.addRecord(parts: [first, second, third])
        let seams = FailureSeams()
        seams.hold(first)
        let store = harness.store
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0),
            readRecord: { store, id in
                let record = try await store.record(id: id)
                await store.failNextCommit(with: TestError())
                return record
            },
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure)
        await engine.start(partIDs: [first, third])
        await harness.waitForRequests(2)
        failing.open()
        _ = await seams.nextHeld()

        // The resume's start launches B, whose state can't be saved: B fails for good.
        #expect(try await engine.resume(recordID: record.id))
        #expect(await seams.nextSettled() == second)
        #expect(try await store.record(id: record.id)?.state == .failed)
        seams.release()
        #expect(await seams.nextSettled() == first)

        #expect(try await store.record(id: record.id)?.state == .failed)
        #expect(try await store.part(id: first)?.state == .failed)
        #expect(try await store.part(id: second)?.state == .failed)
        #expect(try await store.part(id: third)?.state == .queued)
        #expect(harness.requests.count == 2)
        never.open()
    }

    /// A plain start of A overlaps A's failure for good, and sibling B fails for good while A is
    /// held before its siblings stop (B's write of the record's `failed` is a no-op: A's came
    /// first). A's replay must not queue the record and restart A only: B would stay failed and
    /// the download never complete. The record stays failed, and a resume restarts both. (A
    /// transfer's events are handled one at a time, so B fails from its retry's launch.)
    @Test func plainStartReplayDoesNotStrandASiblingsNewerFailure() async throws {
        let failing = StubGate()
        let counter = PathCounter()
        let harness = try await DownloadHarness { request in
            let count = counter.next(request)
            if request.url?.path().contains("/file/1/") == true {
                return count == 1 ? .status(404, body: Data(), gate: failing) : .status(200)
            }
            return count == 1 ? .status(503) : .status(200)
        }
        let first = UUID()
        let second = UUID()
        let record = try await harness.addRecord(parts: [first, second])
        let clock = FiringClock()
        let seams = FailureSeams()
        seams.hold(first)
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 1), clock: clock,
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure,
            startFoundSettling: seams.startFoundSettling)
        await engine.start(partIDs: [first, second])
        await harness.waitForRequests(2)
        _ = await clock.started.first { _ in true }
        failing.open()
        #expect(await seams.nextHeld() == first)

        // The plain start finds A settling and leaves it to the replay.
        await engine.start(partIDs: [first])
        #expect(await seams.nextFoundSettling() == [first])

        // B's retry can't save its state and has no retries left: B fails for good.
        await harness.store.failNextCommit(with: TestError())
        clock.fire()
        #expect(await seams.nextSettled() == second)
        #expect(try await harness.store.part(id: second)?.state == .failed)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)

        seams.release()
        #expect(await seams.nextSettled() == first)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(try await harness.store.part(id: first)?.state == .failed)
        #expect(try await harness.store.part(id: second)?.state == .failed)
        #expect(harness.requests.count == 2)
        let activeTasks = await harness.session?.session.allTasks.filter {
            $0.state == .running || $0.state == .suspended
        }
        #expect(activeTasks?.isEmpty == true)

        #expect(try await engine.resume(recordID: record.id))
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 4)
    }

    /// Two parts fail for good while a resume is pending (A's transfer failed, B's retry can't
    /// save its state): each is replayed once for the resume, B again with A's replay, and the
    /// record ends up downloading with no further attempts. A transfer's events are handled one
    /// at a time, so B fails from its retry's launch.
    @Test func simultaneousFailuresDuringAResumeEachReplayOnceAndConverge() async throws {
        let failingA = StubGate()
        let never = StubGate()
        let counter = PathCounter()
        let harness = try await DownloadHarness { request in
            let count = counter.next(request)
            if request.url?.path().contains("/file/1/") == true {
                return count == 1 ? .status(404, body: Data(), gate: failingA) : .status(200, gate: never)
            }
            return count == 1 ? .status(503) : .status(200, gate: never)
        }
        let first = UUID()
        let second = UUID()
        let record = try await harness.addRecord(parts: [first, second])
        let (resumeReads, resumeReadStarted) = AsyncStream.makeStream(of: Void.self)
        let releaseResumeRead = StubGate()
        let clock = FiringClock()
        let seams = FailureSeams()
        seams.hold(first)
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 1), clock: clock,
            readRecord: { store, id in
                let record = try await store.record(id: id)
                resumeReadStarted.yield()
                await withCheckedContinuation { continuation in
                    releaseResumeRead.run { continuation.resume() }
                }
                return record
            },
            beforeStoppingSiblings: seams.beforeStoppingSiblings, afterPermanentFailure: seams.afterPermanentFailure)
        await engine.start(partIDs: [first, second])
        await harness.waitForRequests(2)
        _ = await clock.started.first { _ in true }
        failingA.open()
        _ = await seams.nextHeld()
        let resuming = Task { try await engine.resume(recordID: record.id) }
        _ = await resumeReads.first { _ in true }

        // B's retry can't save its state: B fails for good, and is replayed for the resume.
        await harness.store.failNextCommit(with: TestError())
        clock.fire()
        #expect(await seams.nextSettled() == second)
        #expect(try await harness.store.part(id: second)?.state == .running)

        // A's replay restarts B too, which A's failure stopped.
        seams.release()
        #expect(await seams.nextSettled() == first)
        await harness.waitForRequests(5)
        #expect(harness.requestCount(file: 1) == 2)
        #expect(harness.requestCount(file: 2) == 3)
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)

        releaseResumeRead.open()
        #expect(try await resuming.value)
        never.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 5)
    }

    /// A resume can queue a record before its start reaches a part that is settling.
    @Test func resumeBeforePermanentFailureSettlesRestartsTheFailingPart() async throws {
        let first = StubGate()
        let later = StubGate()
        let never = StubGate()
        let seen = Mutex<Set<String>>([])
        let harness = try await DownloadHarness { request in
            let path = request.url?.path() ?? ""
            let isFirst = seen.withLock { $0.insert(path).inserted }
            if path.contains("/file/1/") {
                return isFirst ? .status(404, body: Data(), gate: first) : .status(200, gate: later)
            }
            return isFirst ? .status(200, gate: never) : .status(200)
        }
        let failing = UUID()
        let sibling = UUID()
        let record = try await harness.addRecord(parts: [failing, sibling])
        let (resumeReads, resumeReadStarted) = AsyncStream.makeStream(of: DownloadState?.self)
        let releaseResumeRead = StubGate()
        let (cancelling, cancelStarted) = AsyncStream.makeStream(of: Void.self)
        let release = StubGate()
        let seams = FailureSeams()
        let engine = harness.makeEngine(
            readRecord: { store, id in
                let record = try await store.record(id: id)
                resumeReadStarted.yield(record?.state)
                await withCheckedContinuation { continuation in
                    releaseResumeRead.run { continuation.resume() }
                }
                return record
            },
            cancel: { task in
                cancelStarted.yield()
                await withCheckedContinuation { continuation in release.run { continuation.resume() } }
                return await task.cancelByProducingResumeData()
            }, startFoundSettling: seams.startFoundSettling)
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)

        let resuming = Task { try await engine.resume(recordID: record.id) }
        #expect(await resumeReads.first { _ in true } == .queued)

        // The resume has saved `.queued` and read it, but can't start until released.
        first.open()
        _ = await cancelling.first { _ in true }
        #expect(try await harness.store.record(id: record.id)?.state == .queued)
        releaseResumeRead.open()
        _ = await seams.nextFoundSettling()
        release.open()

        #expect(try await resuming.value)
        await engine.processPendingEvents()
        try #require(try await harness.store.part(id: failing)?.state == .running)
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        let task = try #require(
            await harness.session?.session.allTasks.first { $0.taskDescription == failing.uuidString })
        #expect(task.state == .running)
        later.open()
        await harness.waitForCompletions(3)
        await engine.processPendingEvents()
    }

    @Test(arguments: [DownloadState.paused, .failed])
    func activateDoesNotRestartStoppedRecords(state: DownloadState) async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: state)
        let engine = harness.makeEngine()

        #expect(await engine.activate())
        await engine.waitForRestart()

        #expect(harness.requests.isEmpty)
        #expect(try await harness.store.part(id: partID)?.state == .queued)
    }

    @Test(arguments: [DownloadState.paused, .failed])
    func reattachStopsTransfersOfStoppedRecords(state: DownloadState) async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: state, partState: .running)
        let base = harness.base
        let engine = harness.makeEngine(prepare: { stub in
            let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
            stub.leaveTask(URLRequest(url: url), description: partID.uuidString)
        })

        #expect(await engine.activate())
        await harness.waitForCompletions(1)
        await engine.waitForRestart()

        #expect(harness.session?.leftovers.withLock { $0.first?.state } == .completed)
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.taskIdentifier == nil)
        #expect(try await harness.store.record(id: record.id)?.state == state)
        #expect(harness.credentials.calls.isEmpty)
        #expect(!harness.fileExists("li_1/1.mp3"))
    }

    @Test(arguments: [DownloadState.paused, .failed], [false, true])
    func survivorFinishingDuringAdoptionDoesNotCompleteStoppedRecords(
        state: DownloadState, finishesFirst: Bool
    ) async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: state, partState: .running)
        let base = harness.base
        // The leftover finishes at once: before, during or after the adoption's store write; or,
        // with `finishesFirst`, before the engine lists its tasks.
        var listing: (@Sendable () async -> Void)?
        if finishesFirst {
            listing = { await harness.waitForCompletions(1) }
        }
        let engine = harness.makeEngine(
            listing: listing,
            prepare: { stub in
                let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
                stub.leaveTask(URLRequest(url: url), description: partID.uuidString)
            })

        #expect(await engine.activate())
        await harness.waitForCompletions(1)
        await engine.waitForRestart()

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(try await harness.store.record(id: record.id)?.state == state)
        #expect(harness.credentials.calls.isEmpty)
    }

    /// A survivor of a stopped download that finished after its transfer's start marker moved
    /// its file into place. Its adoption is refused, so activation doesn't complete the part
    /// from that file, although the part was running when the downloads were read.
    @Test(arguments: [DownloadState.paused, .failed])
    func stoppedSurvivorsFileDoesNotCompleteItsPart(state: DownloadState) async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: state, partState: .running)
        try harness.locations.markTransferStart(partID: partID)
        let base = harness.base
        let box = Mutex<DownloadEngine?>(nil)
        // The leftover finishes, and its refused adoption is handled, before the tasks are listed.
        let engine = harness.makeEngine(
            listing: {
                await harness.waitForCompletions(1)
                await box.withLock { $0 }?.processPendingEvents()
            },
            prepare: { stub in
                let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
                stub.leaveTask(URLRequest(url: url), description: partID.uuidString)
            })
        box.withLock { $0 = engine }

        #expect(await engine.activate())
        await engine.waitForRestart()

        #expect(harness.fileExists("li_1/1.mp3"))
        #expect(try await harness.store.record(id: record.id)?.state == state)
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(harness.credentials.calls.isEmpty)
    }

    @Test func survivorIsStoppedWhenItsAdoptionCantBeSaved() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness {
            $0.authorization == "Bearer previous" ? .status(200, gate: never) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let base = harness.base
        let engine = harness.makeEngine(prepare: { stub in
            var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
            request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
            stub.leaveTask(request, description: partID.uuidString)
        })
        // The adoption's `beginRunning` fails.
        await harness.store.failNextCommit(with: TestError())

        #expect(await engine.ensureSession())

        #expect(harness.session?.leftovers.withLock { $0.first?.state } != .running)
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.taskIdentifier == nil)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.credentials.calls == [nil])
    }

    @Test(arguments: [false, true])
    func survivorFailingBeforeAdoptionDoesNotFailStoppedRecords(withResumeData: Bool) async throws {
        let harness = try await DownloadHarness {
            guard $0.stubCount == 1 else { return .status(200) }
            return withResumeData ? .failure(resumeData: Data("resume".utf8)) : .status(404, body: Data())
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: .paused, partState: .running)
        let base = harness.base
        // The leftover fails before the engine lists its tasks. Its request is the one a launch
        // would make, so its resume data stays valid.
        let engine = harness.makeEngine(
            listing: { await harness.waitForCompletions(1) },
            prepare: { stub in
                var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
                request.setValue("Bearer token-1", forHTTPHeaderField: "Authorization")
                let task = stub.downloadTask(with: request)
                task.taskDescription = partID.uuidString
                task.resume()
            })

        #expect(await engine.activate())
        await engine.waitForRestart()

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.hasResumeData == withResumeData)
        #expect(part.retryCount == 0)
        #expect(try await harness.store.record(id: record.id)?.state == .paused)
        #expect(harness.credentials.calls.isEmpty)
        #expect(try await engine.resume(recordID: record.id))
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == (withResumeData ? [Data("resume".utf8)] : []))
    }

    /// A surviving transfer that fails for good while the session lists its tasks leaves its
    /// part failed: activation queues only parts the store still has running.
    @Test func survivorFailingWhileTasksAreListedStaysFailed() async throws {
        let harness = try await DownloadHarness { _ in .status(404, body: Data()) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let base = harness.base
        let listed = StubGate()
        let engine = harness.makeEngine(
            listing: { await withCheckedContinuation { continuation in listed.run { continuation.resume() } } },
            prepare: { stub in
                let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
                stub.leaveTask(URLRequest(url: url), description: partID.uuidString)
            })

        let activating = Task { await engine.activate() }
        #expect(await engine.nextPermanentFailure() != nil)
        listed.open()
        #expect(await activating.value)
        await engine.waitForRestart()

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .failed)
        #expect(part.lastError == "The server returned HTTP 404.")
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(harness.requests.count == 1)
    }

    /// Retry failures raised while activation reattaches a survivor must not make a background
    /// wake wait for its own activation. This covers exhausted retries and failed launches from
    /// both the inline retry and replay paths.
    @Test(.timeLimit(.minutes(1)), arguments: ActivationRetryFailure.allCases)
    func retryFailureDuringAdoptionWithPendingResumeDoesNotDeadlockBackgroundWake(
        scenario: ActivationRetryFailure
    ) async throws {
        let survivorGate = StubGate()
        let replay = StubGate()
        let never = StubGate()
        let counter = PathCounter()
        let isInlineRetryLaunch = scenario == .inlineRetryLaunch
        let isReplaySiblingLaunch = scenario == .replaySiblingLaunch
        let customHeaders = isInlineRetryLaunch ? ["CF-Access-Client-Secret": "secret"] : [:]
        let harness = try await DownloadHarness(customHeaders: customHeaders) { request in
            let count = counter.next(request)
            if request.url?.path().contains("/file/1/") == true {
                let status = isReplaySiblingLaunch ? 404 : 500
                return count == 1 ? .status(status, body: Data(), gate: survivorGate) : .status(200, gate: replay)
            }
            return .status(200, gate: never)
        }
        let failing = UUID()
        let sibling = UUID()
        let parts = isInlineRetryLaunch ? [failing] : [failing, sibling]
        let record = try await harness.addRecord(parts: parts, state: .downloading)
        let failingRetryCount = isInlineRetryLaunch ? 3 : scenario == .exhaustedRetry ? 5 : 0
        _ = try await harness.store.updatePart(partID: failing, retryCount: failingRetryCount)
        if isReplaySiblingLaunch {
            _ = try await harness.store.updatePart(partID: sibling, retryCount: 5)
            harness.credentials.failCredentials(onCall: 2)
        }
        let base = harness.base
        let (adopting, adoptingContinuation) = AsyncStream.makeStream(of: UUID.self)
        let proceed = StubGate()
        let (resumeReads, resumeReadStarted) = AsyncStream.makeStream(of: Void.self)
        let engine = harness.makeEngine(
            readRecord: { store, id in
                resumeReadStarted.yield()
                return try await store.record(id: id)
            },
            adoptionStarted: { partID in
                adoptingContinuation.yield(partID)
                await withCheckedContinuation { continuation in proceed.run { continuation.resume() } }
            },
            prepare: { stub in
                let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
                stub.leaveTask(URLRequest(url: url), description: failing.uuidString)
            })

        // A background wake waits before it decides the survivor's adoption.
        let waking = Task { await engine.handleBackgroundEvents() }
        #expect(await adopting.first { _ in true } == failing)
        let resuming = Task { try await engine.resume(recordID: record.id) }
        _ = await resumeReads.first { _ in true }

        // The result is held while activation adopts the survivor.
        harness.session?.finishBackgroundEvents()
        await engine.processPendingEvents()
        #expect(await engine.unclaimedBackgroundFinishes == 1)
        survivorGate.open()
        await harness.waitForCompletions(1)
        await engine.processPendingEvents()
        proceed.open()

        let (finished, finishedContinuation) = AsyncStream.makeStream(of: Bool.self)
        let completion = Task {
            await waking.value
            let resumed = (try? await resuming.value) ?? false
            await engine.waitForRestart()
            if !isInlineRetryLaunch {
                // The restart has resumed both transfers, but the stub sees them only once the
                // session starts loading them.
                await harness.waitForRequests(file: 1, count: 2)
                await harness.waitForRequests(file: 2, count: 1)
            }
            let requestsMatch =
                isInlineRetryLaunch
                ? harness.requestCount(file: 1) == 1 && harness.requestCount(file: 2) == 0
                : harness.requestCount(file: 1) >= 2 && harness.requestCount(file: 2) == 1
            finishedContinuation.yield(resumed && requestsMatch)
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            finishedContinuation.yield(false)
        }
        let replayFinished = await finished.first { _ in true } ?? false
        timeout.cancel()
        if !replayFinished {
            waking.cancel()
            resuming.cancel()
            completion.cancel()
        }
        #expect(replayFinished)
        guard replayFinished else { return }
        if isInlineRetryLaunch {
            #expect(try await harness.store.record(id: record.id)?.state == .failed)
            #expect(try await harness.store.part(id: failing)?.state == .failed)
            #expect(harness.credentials.calls.count >= 1)
            #expect(harness.requestCount(file: 1) == 1)
            #expect(harness.requestCount(file: 2) == 0)
            return
        }
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        let failingPart = try #require(try await harness.store.part(id: failing))
        #expect(failingPart.state == .running)
        #expect(failingPart.retryCount == 0)
        let siblingPart = try #require(try await harness.store.part(id: sibling))
        #expect(siblingPart.state == .running)
        #expect(siblingPart.retryCount == 0)
        #expect(harness.requestCount(file: 1) >= 2)
        #expect(harness.requestCount(file: 2) == 1)

        replay.open()
        never.open()
        #expect(await engine.nextRecordComplete() != nil)
    }

    @Test func unsavedRecordFailureBlocksRestartsUntilSaved() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(404, body: Data(), gate: gate) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        // Saving the record's `failed` state fails, then fails again on the next activation.
        await harness.store.failNextCommit(with: TestError())
        gate.open()
        #expect(await engine.nextPermanentFailure() != nil)
        #expect(try await harness.store.record(id: record.id)?.state != .failed)

        await harness.store.failNextCommit(with: TestError())
        #expect(await engine.activate())
        await engine.waitForRestart()
        #expect(try await harness.store.part(id: partID)?.state == .failed)

        #expect(await engine.activate())
        await engine.waitForRestart()
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(try await harness.store.part(id: partID)?.state == .failed)
        #expect(harness.requests.count == 1)
    }

    /// What a background wake whose completion couldn't be saved leaves: the moved file, and
    /// the part running. Only a file of the expected size that the part's current transfer
    /// moved (modified after its start marker) completes it; otherwise the part downloads again.
    @Test(arguments: [
        ("audio-bytes", true, true, true), ("audio", true, true, false), ("audio-bytes", true, false, false),
        ("audio-bytes", false, true, false),
    ])
    func fileAlreadyInPlaceCompletesThePart(
        contents: String, hasMarker: Bool, isNewer: Bool, isKept: Bool
    ) async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], state: .downloading, partState: .running)
        let file = harness.fileURL("li_1/1.mp3")
        try FileManager.default.createDirectory(at: harness.fileURL("li_1"), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if hasMarker { try harness.locations.markTransferStart(partID: partID) }
        try FileManager.default.setAttributes(
            [.modificationDate: isNewer ? Date.now.addingTimeInterval(60) : Date.distantPast],
            ofItemAtPath: file.path(percentEncoded: false))
        let engine = harness.makeEngine()

        #expect(await engine.activate())

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == (isKept ? 0 : 1))
    }

    @Test func pauseStopsAndResumeContinues() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { $0.stubCount == 1 ? .status(200, gate: gate) : .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)

        #expect(try await engine.pause(recordID: record.id))
        gate.open()
        #expect(await engine.activate())
        await engine.waitForRestart()

        #expect(try await harness.store.record(id: record.id)?.state == .paused)
        #expect(try await harness.store.part(id: partID)?.state == .queued)
        #expect(harness.requests.count == 1)
        #expect(try await engine.resume(recordID: record.id))
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 2)
        #expect(try await engine.pause(recordID: UUID()) == false)
    }

    @Test func failedPauseReadLeavesRecordAndTransferConsistent() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let reads = Mutex(0)
        let engine = harness.makeEngine(readRecord: { store, recordID in
            if reads.withLock({
                $0 += 1
                return $0
            }) == 1 {
                throw TestError()
            }
            return try await store.record(id: recordID)
        })
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)

        do {
            _ = try await engine.pause(recordID: record.id)
            Issue.record("Expected the injected record read to fail")
        } catch is TestError {
        }

        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        #expect(await harness.session?.session.allTasks.first?.state == .running)
        #expect(try await engine.pause(recordID: record.id))
        #expect(try await harness.store.record(id: record.id)?.state == .paused)
        gate.open()
        await harness.waitForCompletions(1)
        await engine.processPendingEvents()

        #expect(try await harness.store.record(id: record.id)?.state == .paused)
        #expect(try await harness.store.part(id: partID)?.state == .queued)
        #expect(
            try await harness.localItems.item(
                serverConnectionID: record.key.serverConnectionID, libraryItemId: record.key.libraryItemId) == nil)
    }

    @Test func backgroundDisconnectRecreatesSessionBeforeReleasingWake() async throws {
        let gate = StubGate()
        let never = StubGate()
        let harness = try await DownloadHarness {
            $0.stubCount == 1
                ? .failure(code: NSURLErrorBackgroundSessionWasDisconnected, gate: gate)
                : .status(200, gate: never)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let clock = SignallingClock()
        let engine = harness.makeEngine(clock: clock)
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        let originalSession = try #require(harness.session)
        await engine.deactivate()

        let wake = Task { await engine.handleBackgroundEvents() }
        while await engine.backgroundWaiterCount == 0 { await Task.yield() }
        gate.open()
        await harness.waitForCompletions(1)
        originalSession.finishBackgroundEvents()
        await wake.value
        await engine.processPendingEvents()

        #expect(clock.sleeps == 0)
        #expect(harness.sessions.withLock { $0.count } == 2)
        let session = try #require(harness.session).session
        let task = try #require(await session.allTasks.first { $0.taskDescription == partID.uuidString })
        #expect(task.state == .running)
        #expect(task.earliestBeginDate != nil)
        #expect(try await harness.store.part(id: partID)?.state == .running)
    }

    /// A start during a multi-part pause's stops waits for each part's stop, then restarts every
    /// part, in whatever order it lists them. (A resume waits for the whole pause; see
    /// ``resumeWaitsForAPauseBeforeItsStops()``.)
    @Test(arguments: [false, true])
    func startWaitsForAPauseUnderWay(reversingParts: Bool) async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { $0.stubCount <= 2 ? .status(200, gate: never) : .status(200) }
        let partIDs = [UUID(), UUID()]
        let record = try await harness.addRecord(parts: partIDs)
        let (reads, readCount) = AsyncStream.makeStream(of: Int.self)
        let (cancelling, cancelStarted) = AsyncStream.makeStream(of: Void.self)
        let release = StubGate()
        let count = Mutex(0)
        let engine = harness.makeEngine(
            readRecords: { store in
                let records = try await store.allRecords()
                readCount.yield(
                    count.withLock {
                        $0 += 1; return $0
                    })
                return records
            },
            cancel: { task in
                cancelStarted.yield()
                await withCheckedContinuation { continuation in release.run { continuation.resume() } }
                return await task.cancelByProducingResumeData()
            })
        await engine.start(partIDs: partIDs)
        await harness.waitForRequests(2)

        // The pause's first cancellation is held while the restart reads the downloads and launches.
        let pausing = Task { try await engine.pause(recordID: record.id) }
        _ = await cancelling.first { _ in true }
        let starting = Task {
            let isQueued = try await harness.store.setState(.queued, forRecord: record.id)
            await engine.start(partIDs: reversingParts ? partIDs.reversed() : partIDs)
            return isQueued
        }
        // The activation and the first start read twice; the restart's start reads the third time.
        _ = await reads.first { $0 >= 3 }
        await engine.processPendingEvents()
        release.open()

        #expect(try await pausing.value)
        #expect(try await starting.value)
        // No part is left queued without a transfer (otherwise the record never completes).
        for partID in partIDs {
            try #require(try await harness.store.part(id: partID)?.state != .queued)
        }
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 4)
    }

    /// A resume that comes while a pause is between its state write and its stops waits for the
    /// whole pause, then restarts every part the pause stopped.
    @Test func resumeWaitsForAPauseBeforeItsStops() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { $0.stubCount <= 2 ? .status(200, gate: never) : .status(200) }
        let partIDs = [UUID(), UUID()]
        let record = try await harness.addRecord(parts: partIDs)
        let (reading, readStarted) = AsyncStream.makeStream(of: Void.self)
        let release = StubGate()
        let reads = Mutex(0)
        // The pause's read of its record, after it wrote `paused`, is held.
        let engine = harness.makeEngine(readRecord: { store, id in
            if reads.withLock({
                $0 += 1; return $0
            }) == 1 {
                readStarted.yield()
                await withCheckedContinuation { continuation in release.run { continuation.resume() } }
            }
            return try await store.record(id: id)
        })
        await engine.start(partIDs: partIDs)
        await harness.waitForRequests(2)

        let pausing = Task { try await engine.pause(recordID: record.id) }
        _ = await reading.first { _ in true }
        let resuming = Task { try await engine.resume(recordID: record.id) }
        // Time for a resume that didn't wait to find both transfers still running.
        try await Task.sleep(for: .milliseconds(200))
        release.open()

        #expect(try await pausing.value)
        #expect(try await resuming.value)
        for partID in partIDs {
            try #require(try await harness.store.part(id: partID)?.state != .queued)
        }
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 4)
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

    @Test func failedFinalisationIsRetriedOnActivate() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        await harness.localItems.failNextCommit(with: TestError())

        await engine.start(partIDs: [partID])
        #expect(
            await engine.next {
                if case .partCompleted = $0 { true } else { false }
            } != nil)
        await engine.processPendingEvents()
        #expect(try await harness.store.record(id: record.id) != nil)

        #expect(await engine.activate())

        #expect(await engine.nextRecordComplete() != nil)
        #expect(try await harness.store.record(id: record.id) == nil)
        let item = try await harness.localItems.item(serverConnectionID: harness.connectionID, libraryItemId: "li_1")
        #expect(item?.files.map(\.size) == [11])
        #expect(harness.requests.count == 1)
    }
}
