import ABSAPI
import Foundation
import Testing

@testable import ABSData
@testable import ABSDownloads

/// Transfers: completion, response checks, retries, 401 recovery and resume data.
@Suite(.timeLimit(.minutes(1))) struct DownloadEngineTests {
    @Test func movesFinishedFileAndFinalisesRecord() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let update = try #require(await engine.nextRecordComplete())
        guard case .recordComplete(record.id, let itemID) = update else {
            Issue.record("Unexpected \(update)")
            return
        }
        #expect(try Data(contentsOf: harness.fileURL("li_1/1.mp3")) == Data("audio-bytes".utf8))
        let item = try #require(try await harness.localItems.item(id: itemID))
        #expect(item.files.map(\.relativePath) == ["li_1/1.mp3"])
        #expect(item.files.map(\.size) == [11])
        #expect(try await harness.store.record(id: record.id) == nil)
        let request = try #require(harness.requests.first)
        #expect(harness.requests.count == 1)
        #expect(request.url?.absoluteString == "\(harness.base)/api/items/li_1/file/1/download")
        #expect(request.authorization == "Bearer token-1")
        #expect(harness.credentials.calls == [nil])
        let progress = await engine.progress.first { _ in true }
        #expect(progress == DownloadProgress(partID: partID, recordID: record.id, bytesWritten: 11, expectedBytes: 11))
    }

    /// A cover-only record (#326) whose local item was deleted is discarded: deleted and
    /// reported, its cover left on disk for the manager, and no local item made.
    @Test func discardsACoverOnlyRecordWithoutItsItem() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.store.upsertRecord(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: harness.connectionID, libraryItemId: "li_1"), mediaType: .podcast,
                title: "The Show", relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Show")),
                parts: [
                    DownloadPartDTO(
                        id: partID, kind: .cover, serverPath: DownloadRequests.coverPath(itemID: "li_1", updatedAt: 0),
                        filename: "cover.jpg", mimeType: "image/jpeg", expectedBytes: 0, bytesWritten: 0,
                        destinationRelativePath: "li_1/cover.jpg", state: .queued)
                ])
        ).record
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let update = await engine.next { if case .recordDiscarded = $0 { true } else { false } }
        guard case .recordDiscarded(let discarded) = update else {
            Issue.record("Unexpected \(String(describing: update))")
            return
        }
        #expect(discarded.id == record.id)
        #expect(discarded.parts.map(\.state) == [.completed])
        #expect(try await harness.store.record(id: record.id) == nil)
        #expect(try await harness.localItems.allItems().isEmpty)
        #expect(harness.fileExists("li_1/cover.jpg"))
    }

    /// A cover over the limit, declared or sent without a length, fails for good as too large
    /// and never reaches its destination.
    @Test(arguments: [true, false])
    func failsACoverOverTheLimit(declared: Bool) async throws {
        let limit = DownloadEngine.maxCoverBytes
        let reply: StubReply =
            declared
            ? .status(
                200, body: Data("img".utf8), contentType: "image/jpeg", headers: ["Content-Length": "\(limit + 1)"])
            : .status(
                200, body: Data(count: Int(limit) + 1), contentType: "image/jpeg", headers: ["Content-Length": ""])
        let harness = try await DownloadHarness { _ in reply }
        let partID = UUID()
        let record = try await harness.store.upsertRecord(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: harness.connectionID, libraryItemId: "li_1"), mediaType: .podcast,
                title: "The Show", relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Show")),
                parts: [
                    DownloadPartDTO(
                        id: partID, kind: .cover, serverPath: DownloadRequests.coverPath(itemID: "li_1", updatedAt: 0),
                        filename: "cover.jpg", mimeType: "image/jpeg", expectedBytes: 0, bytesWritten: 0,
                        destinationRelativePath: "li_1/cover-1.jpg", state: .queued)
                ])
        ).record
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let update = await engine.next { if case .partFailed = $0 { true } else { false } }
        guard case .partFailed(partID, record.id, let code, _, let willRetry) = update else {
            Issue.record("Unexpected \(String(describing: update))")
            return
        }
        #expect(code == .tooLarge)
        #expect(!willRetry)
        #expect(!harness.fileExists("li_1/cover-1.jpg"))
    }

    /// The record is reported started once, when its first part moves it from queued to
    /// downloading, before any part completes; its other part starts without a report.
    @Test func reportsARecordStartedOnce() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partIDs = [UUID(), UUID()]
        let record = try await harness.addRecord(parts: partIDs)
        let engine = harness.makeEngine()

        await engine.start(partIDs: partIDs)

        var updates: [DownloadUpdate] = []
        for await update in engine.updates {
            updates.append(update)
            if case .recordComplete = update { break }
        }
        #expect(updates.first == .recordStarted(recordID: record.id))
        #expect(updates.filter { $0 == .recordStarted(recordID: record.id) }.count == 1)
    }

    @Test(arguments: [404, 204])
    func errorStatusFailsWithoutTouchingMediaLocation(status: Int) async throws {
        let harness = try await DownloadHarness { _ in .status(status, body: Data("Nope".utf8)) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let message = "The server returned HTTP \(status)."
        #expect(
            await engine.nextPermanentFailure()
                == .partFailed(
                    partID: partID, recordID: record.id, code: .httpStatus, message: message, willRetry: false))
        #expect(!harness.fileExists("li_1/1.mp3"))
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .failed)
        #expect(part.lastError == message)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(harness.requests.count == 1)
    }

    @Test func customHeadersFailWithoutARequest() async throws {
        let harness = try await DownloadHarness(customHeaders: ["CF-Access-Client-Secret": "secret"]) { _ in
            .status(200)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(
            await engine.nextPermanentFailure()
                == .partFailed(
                    partID: partID, recordID: record.id, code: .customHeadersUnsupported,
                    message: "Downloads from a server that needs custom headers aren't supported yet.",
                    willRetry: false))
        #expect(harness.requests.isEmpty)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
    }

    @Test(arguments: [408, 429, 500, 503])
    func retriesTransientStatus(status: Int) async throws {
        let harness = try await DownloadHarness { $0.stubCount == 1 ? .status(status) : .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextFailure(willRetry: true) != nil)
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.clock.sleeps == [.milliseconds(1500)])
        #expect(harness.requests.count == 2)
        #expect(harness.fileExists("li_1/1.mp3"))
    }

    @Test func retriesWithBackoff() async throws {
        let harness = try await DownloadHarness { $0.stubCount <= 2 ? .status(503) : .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        // Default policy with random 0.5: half of 2 s plus a quarter, then half of 4 s plus a quarter.
        #expect(harness.clock.sleeps == [.milliseconds(1500), .seconds(3)])
        #expect(harness.requests.count == 3)
        #expect(harness.credentials.calls == [nil, nil, nil])
    }

    /// Failures counted before a relaunch still count: a new engine continues the backoff from
    /// the store's retry count and fails for good at the limit. A resume starts the count over.
    @Test(arguments: [2, 5])
    func retriesCountedBeforeARelaunchStillCount(earlierRetries: Int) async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { $0.stubCount == 1 ? .status(503) : .status(200, gate: gate) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID], state: .downloading)
        for _ in 0..<earlierRetries {
            _ = try await harness.store.beginRunning(partID: partID, expecting: [.queued, .failed])
            try await harness.store.setPartState(.failed, partID: partID, taskIdentifier: nil, error: "lost")
        }
        try #require(try await harness.store.part(id: partID)?.retryCount == earlierRetries)
        let engine = harness.makeEngine()

        #expect(await engine.activate())

        let isLast = earlierRetries == RetryPolicy.default.maxRetries
        let failure = await engine.next {
            if case .partFailed = $0 { true } else { false }
        }
        #expect(
            failure
                == .partFailed(
                    partID: partID, recordID: record.id, code: .transfer, message: "The server returned HTTP 503.",
                    willRetry: !isLast))
        if isLast {
            #expect(harness.requests.count == 1)
            #expect(try await engine.resume(recordID: record.id))
        }
        await harness.waitForRequests(2)
        // Default policy with random 0.5: the third retry waits half of 8 s plus a quarter.
        #expect(harness.clock.sleeps == (isLast ? [] : [.seconds(6)]))
        #expect(try await harness.store.part(id: partID)?.retryCount == (isLast ? 0 : earlierRetries + 1))
        gate.open()
        #expect(await engine.nextRecordComplete() != nil)
    }

    @Test func failedRetryStateWriteDoesNotStrandThePart() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { $0.stubCount == 1 ? .status(503, gate: gate) : .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        // The `.failed` write after the 503 fails, so the store still has the part running.
        await harness.store.failNextCommit(with: TestError())

        gate.open()

        #expect(await engine.nextFailure(willRetry: true) != nil)
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 2)
    }

    @Test func failedBeginRunningPersistsRetryBudgetAcrossRelaunch() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .status(503) : .status(200, gate: gate)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID], partState: .failed)
        let engine = harness.makeEngine(clock: SignallingClock())
        await harness.store.failNextCommit(with: TestError())

        await engine.start(partIDs: [partID])

        #expect(await engine.nextFailure(willRetry: true) != nil)
        #expect(try await harness.store.part(id: partID)?.retryCount == 1)

        let relaunched = harness.makeEngine(registry: DownloadEngineRegistry())
        #expect(await relaunched.activate())
        #expect(await relaunched.nextFailure(willRetry: true) != nil)
        await harness.waitForRequests(2)
        #expect(try await harness.store.part(id: partID)?.retryCount == 2)
        gate.open()
        #expect(await relaunched.nextRecordComplete() != nil)
        #expect(harness.requests.count == 2)
    }

    /// Posts a finished file for the part, as the delegate does once it has moved it, while
    /// the part's transfer is still running.
    private func postMovedFile(_ partID: UUID, harness: DownloadHarness, engine: DownloadEngine) async throws {
        try FileManager.default.createDirectory(at: harness.fileURL("li_1"), withIntermediateDirectories: true)
        try Data("audio-bytes".utf8).write(to: harness.fileURL("li_1/1.mp3"))
        let session = try #require(harness.session).session
        let task = session.downloadTask(with: URLRequest(url: URL(string: harness.base)!))
        task.taskDescription = partID.uuidString
        await engine.delegate.post(.completed(task, .moved(bytes: 11)))
    }

    @Test(arguments: [true, false])
    func failedCompletionSaveIsRetried(withBackoff: Bool) async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let policy = withBackoff ? RetryPolicy.default : RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0)
        let engine = harness.makeEngine(retryPolicy: policy)
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        await harness.store.failNextCommit(with: TestError())

        try await postMovedFile(partID, harness: harness, engine: engine)

        if !withBackoff {
            // No retries left: the completion waits for the next activation.
            await engine.processPendingEvents()
            #expect(try await harness.store.part(id: partID)?.state == .running)
            #expect(await engine.activate())
        }
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.clock.sleeps == (withBackoff ? [.milliseconds(1500)] : []))
        #expect(try await harness.store.record(id: record.id) == nil)
        #expect(harness.requests.count == 1)
    }

    /// A resume leaves a part whose completion is waiting to be saved alone, with its retry timer:
    /// nothing else would save it before the next activation.
    @Test func resumeKeepsTheRetryOfAnUnsavedCompletion() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let clock = FiringClock()
        let engine = harness.makeEngine(clock: clock)
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        await harness.store.failNextCommit(with: TestError())
        try await postMovedFile(partID, harness: harness, engine: engine)
        _ = await clock.started.first { _ in true }

        #expect(try await engine.resume(recordID: record.id))
        clock.fire()

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 1)
    }

    @Test func backgroundWakeSavesCompletionsBeforeItEnds() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        // Without retries, nothing else saves the completion before the next activation.
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        await harness.store.failNextCommit(with: TestError())
        try await postMovedFile(partID, harness: harness, engine: engine)
        await engine.processPendingEvents()
        #expect(try await harness.store.part(id: partID)?.state == .running)

        let wake = Task { await engine.handleBackgroundEvents() }
        harness.session?.finishBackgroundEvents()
        await wake.value

        #expect(try await harness.store.record(id: record.id) == nil)
        #expect(harness.clock.sleeps.isEmpty)
        #expect(harness.requests.count == 1)
    }

    /// In the background a failed transfer's replacement is created before the wake is
    /// released: after a 503 it begins once the backoff has passed (`earliestBeginDate`), as
    /// nothing waits in a process iOS can suspend; after a 401 it begins at once. A relaunch
    /// adopts it like any other transfer.
    @Test(arguments: [503, 401])
    func backgroundRetryIsCreatedBeforeTheWakeEnds(status: Int) async throws {
        let gate = StubGate()
        let never = StubGate()
        let harness = try await DownloadHarness {
            switch $0.stubCount {
            case 1: .status(status, gate: gate)
            case 2: .status(200, gate: never)
            default: .status(200)
            }
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        // A retry that waited in the process would never begin.
        let engine = harness.makeEngine(clock: SignallingClock())
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        // The replacement's credentials take a while.
        harness.credentials.hook.withLock { $0 = { try? await Task.sleep(for: .milliseconds(100)) } }
        await engine.deactivate()

        let wake = Task { await engine.handleBackgroundEvents() }
        let failed = Date.now
        gate.open()
        await harness.waitForCompletions(1)
        harness.session?.finishBackgroundEvents()
        await wake.value

        let session = try #require(harness.session).session
        let task = try #require(await session.allTasks.first { $0.taskDescription == partID.uuidString })
        #expect(task.state == .running)
        if status == 503 {
            let begins = try #require(task.earliestBeginDate)
            #expect(begins.timeIntervalSince(failed) >= 1.5)
            #expect(begins.timeIntervalSince(failed) < 10)
        } else {
            #expect(task.earliestBeginDate == nil)
        }
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .running)
        #expect(part.taskIdentifier == task.taskIdentifier)
        #expect(harness.credentials.calls.count == 2)

        // What the next launch finds: the transfer, running in the session.
        let base = harness.base
        let relaunched = harness.makeEngine(
            registry: DownloadEngineRegistry(),
            prepare: { stub in
                let url = URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!
                stub.leaveTask(URLRequest(url: url), description: partID.uuidString)
            })
        #expect(await relaunched.activate())
        #expect(await relaunched.nextRecordComplete() != nil)
        #expect(harness.credentials.calls.count == 2)
        #expect(harness.requests.count == 3)
    }

    /// A completed part queued again downloads again: the file in place is from an earlier
    /// transfer.
    @Test func requeuedCompletedPartDownloadsAgain() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        // A second part keeps the record from being finalised.
        let record = try await harness.addRecord(parts: [partID, UUID()])
        let engine = harness.makeEngine()
        let completed = DownloadUpdate.partCompleted(partID: partID, recordID: record.id)
        await engine.start(partIDs: [partID])
        #expect(await engine.next { $0 == completed } != nil)

        #expect(try await harness.store.setPartState(.queued, partID: partID, taskIdentifier: nil, requeue: true))
        await engine.start(partIDs: [partID])

        #expect(await engine.next { $0 == completed } != nil)
        #expect(harness.requests.count == 2)
    }

    @Test func htmlBodyIsRetried() async throws {
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .status(200, body: Data("<html>".utf8), contentType: "text/html") : .status(200)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(
            await engine.nextFailure(willRetry: true)
                == .partFailed(
                    partID: partID, recordID: record.id, code: .unexpectedContent,
                    message: "The server sent text/html instead of the file.", willRetry: true))
        #expect(await engine.nextRecordComplete() != nil)
        #expect(try Data(contentsOf: harness.fileURL("li_1/1.mp3")) == Data("audio-bytes".utf8))
    }

    @Test(arguments: ["text/html", "application/json"])
    func rejectedResponseProgressDoesNotChangeThePlannedSize(contentType: String) async throws {
        let body = Data(#"{"error":1}"#.utf8)
        let harness = try await DownloadHarness { _ in
            .status(200, body: body, contentType: contentType)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))

        await engine.start(partIDs: [partID])

        #expect(await engine.nextPermanentFailure() != nil)
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.expectedBytes == 11)
        #expect(part.bytesWritten == 0)
    }

    @Test func sizeMismatchIsRetried() async throws {
        // Without a declared length, a short body can't be a changed file.
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .status(200, body: Data("short".utf8), headers: ["Content-Length": ""]) : .status(200)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(
            await engine.nextFailure(willRetry: true)
                == .partFailed(
                    partID: partID, recordID: record.id, code: .sizeMismatch,
                    message: "The file has 5 bytes instead of 11.", willRetry: true))
        #expect(await engine.nextRecordComplete() != nil)
        #expect(try Data(contentsOf: harness.fileURL("li_1/1.mp3")) == Data("audio-bytes".utf8))
    }

    @Test(arguments: [
        (200, [String: String]()),
        (206, ["Content-Range": "bytes 0-17/18", "Content-Length": ""]),
    ])
    func declaredSizeChangeUpdatesExpectedSize(status: Int, headers: [String: String]) async throws {
        let body = Data("audio-bytes-longer".utf8)
        let harness = try await DownloadHarness { _ in .status(status, body: body, headers: headers) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID, UUID()])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(
            await engine.next { if case .partCompleted = $0 { true } else { false } }
                == .partCompleted(partID: partID, recordID: record.id))
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .completed)
        #expect(part.bytesWritten == 18)
        #expect(part.expectedBytes == 18)
        #expect(try Data(contentsOf: harness.fileURL("li_1/1.mp3")) == body)
        #expect(harness.requests.count == 1)
    }

    @Test(arguments: [200, 401], [Data("audio-bytes".utf8), Data()])
    func offOriginResponseFailsWithoutRefresh(status: Int, body: Data) async throws {
        let harness = try await DownloadHarness { _ in
            .status(status, body: body, from: URL(string: "https://cdn.other.test/file.mp3")!)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let update = try #require(await engine.nextPermanentFailure())
        guard case .partFailed(_, _, .offOrigin, _, false) = update else {
            Issue.record("Unexpected \(update)")
            return
        }
        #expect(harness.credentials.calls == [nil])
        #expect(harness.requests.count == 1)
        #expect(!harness.fileExists("li_1/1.mp3"))
    }

    @Test(arguments: [Data("Unauthorized".utf8), Data()])
    func redirectedUnauthorizedFailsWithoutRefresh(body: Data) async throws {
        let harness = try await DownloadHarness { request in
            .status(401, body: body, from: URL(string: "https://\(request.url!.host()!)/abs/elsewhere")!)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let update = try #require(await engine.nextPermanentFailure())
        guard case .partFailed(_, _, .redirectedUnauthorized, _, false) = update else {
            Issue.record("Unexpected \(update)")
            return
        }
        #expect(harness.credentials.calls == [nil])
        #expect(harness.requests.count == 1)
    }

    @Test func recreatesTaskOnceAfterUnauthorized() async throws {
        let harness = try await DownloadHarness { $0.authorization == "Bearer token-1" ? .status(401) : .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.credentials.calls == [nil, "token-1"])
        #expect(harness.requests.map(\.authorization) == ["Bearer token-1", "Bearer token-2"])
        #expect(harness.clock.sleeps.isEmpty)
    }

    @Test func failsAfterSecondUnauthorized() async throws {
        let harness = try await DownloadHarness { _ in .status(401) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let update = try #require(await engine.nextPermanentFailure())
        guard case .partFailed(_, _, .unauthorized, _, false) = update else {
            Issue.record("Unexpected \(update)")
            return
        }
        #expect(harness.requests.count == 2)
        #expect(harness.credentials.calls == [nil, "token-1"])
        #expect(!harness.fileExists("li_1/1.mp3"))
    }

    @Test func recoversFromSeparateUnauthorizedResponses() async throws {
        // 401, then a transfer that starts and drops, then a 401 for the refreshed token.
        let harness = try await DownloadHarness {
            switch $0.stubCount {
            case 1, 3: .status(401)
            case 2: .failure(partialBody: Data("audio".utf8))
            default: .status(200)
            }
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.credentials.calls == [nil, "token-1", nil, "token-2"])
        #expect(
            harness.requests.map(\.authorization) == [
                "Bearer token-1", "Bearer token-2", "Bearer token-2", "Bearer token-3",
            ])
    }

    @Test func unauthorizedForReplacedTokenDoesNotCount() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness {
            switch $0.stubCount {
            case 1: .status(401, gate: gate)
            case 2: .status(401)
            default: .status(200)
            }
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        harness.credentials.rotate()
        gate.open()

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.credentials.calls == [nil, "token-1", "token-2"])
        #expect(harness.requests.map(\.authorization) == ["Bearer token-1", "Bearer token-2", "Bearer token-3"])
    }

    private static let resumeData = Data("resume: Bearer token-1, X-Proxy: proxy-secret".utf8)

    /// Fails the part's first transfer with resume data and no retries left, then queues its
    /// record again, as a retry from the app would; later requests get `then`.
    private func failWithResumeData(
        keyStore: any ResumeDataKeyStore = MemoryKeyStore(),
        then: @escaping @Sendable (URLRequest) -> StubReply = { _ in .status(200) }
    ) async throws -> (DownloadHarness, DownloadEngine, UUID) {
        let harness = try await DownloadHarness(keyStore: keyStore) {
            $0.stubCount == 1 ? .failure(resumeData: Self.resumeData) : then($0)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: [partID])
        #expect(await engine.nextPermanentFailure() != nil)
        try await harness.store.setState(.queued, forRecord: record.id)
        return (harness, engine, partID)
    }

    @Test func sealsResumeDataAndResumesWithIt() async throws {
        let (harness, engine, partID) = try await failWithResumeData()
        #expect(try await harness.store.part(id: partID)?.hasResumeData == true)
        let blobURL = harness.vault.fileURL(partID: partID)
        let blob = try Data(contentsOf: blobURL)
        #expect(blob.range(of: Data("token-1".utf8)) == nil)
        #expect(blob.range(of: Data("proxy-secret".utf8)) == nil)

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [Self.resumeData])
        // Credentials are refreshed (or checked) before resuming too.
        #expect(harness.credentials.calls == [nil, nil])
        #expect(!FileManager.default.fileExists(atPath: blobURL.path(percentEncoded: false)))
    }

    @Test func credentialChangeDiscardsResumeData() async throws {
        let (harness, engine, partID) = try await failWithResumeData()
        harness.credentials.rotate()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [])
        #expect(harness.requests.last?.authorization == "Bearer token-2")
        #expect(
            !FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false)))
    }

    @Test func unauthorizedResumedTaskStartsFresh() async throws {
        let (harness, engine, partID) = try await failWithResumeData { $0.stubCount == 2 ? .status(401) : .status(200) }

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [Self.resumeData])
        #expect(harness.credentials.calls == [nil, nil, "token-1"])
        #expect(harness.requests.map(\.authorization) == ["Bearer token-1", "Bearer token-1", "Bearer token-2"])
    }

    @Test func unreadableResumeDataStartsFreshAndKeepsIt() async throws {
        let keyStore = FlakyKeyStore()
        let gate = StubGate()
        let (harness, engine, partID) = try await failWithResumeData(keyStore: keyStore) { _ in
            .status(200, gate: gate)
        }
        let failed = try #require(try await harness.store.part(id: partID))
        let blob = harness.vault.fileURL(partID: partID).path(percentEncoded: false)
        keyStore.failNextLoad()

        await engine.start(partIDs: [partID])
        await harness.waitForRequests(2)

        // The Keychain was unavailable: a fresh request, and the blob stays for a later launch.
        #expect(FileManager.default.fileExists(atPath: blob))
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .running)
        #expect(part.hasResumeData)
        // A start begins the retry count again.
        #expect(failed.retryCount == 1)
        #expect(part.retryCount == 0)
        gate.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [])
        #expect(!FileManager.default.fileExists(atPath: blob))
    }
}
