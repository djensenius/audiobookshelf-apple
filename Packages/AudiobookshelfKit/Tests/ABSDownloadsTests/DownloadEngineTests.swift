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
        #expect(part.retryCount == failed.retryCount)
        gate.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [])
        #expect(!FileManager.default.fileExists(atPath: blob))
    }
}
