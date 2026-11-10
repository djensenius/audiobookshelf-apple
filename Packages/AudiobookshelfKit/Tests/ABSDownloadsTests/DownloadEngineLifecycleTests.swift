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

    /// A resume while a part fails for good (its sibling's stop still under way) skips the
    /// failing part, then starts it once the failure is settled.
    @Test func resumeDuringAPermanentFailureRestartsTheFailingPart() async throws {
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
        let (reading, readDone) = AsyncStream.makeStream(of: Void.self)
        let (cancelling, cancelStarted) = AsyncStream.makeStream(of: Void.self)
        let release = StubGate()
        let isWatching = Mutex(false)
        let engine = harness.makeEngine(
            readRecords: { store in
                let records = try await store.allRecords()
                if isWatching.withLock({ $0 }) { readDone.yield() }
                return records
            },
            cancel: { task in
                cancelStarted.yield()
                await withCheckedContinuation { continuation in release.run { continuation.resume() } }
                return await task.cancelByProducingResumeData()
            })
        await engine.start(partIDs: [failing, sibling])
        await harness.waitForRequests(2)

        // The 404 fails the record for good; the sibling's stop is held.
        first.open()
        _ = await cancelling.first { _ in true }
        isWatching.withLock { $0 = true }
        let resuming = Task { try await engine.resume(recordID: record.id) }
        // The resume's start has read the downloads; a hop lets it find the failing part settling.
        _ = await reading.first { _ in true }
        _ = await engine.backgroundWaiterCount
        release.open()

        #expect(try await resuming.value)
        await engine.processPendingEvents()
        try #require(try await harness.store.part(id: failing)?.state == .running)
        later.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 4)
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
