import ABSAPI
import Foundation
import Synchronization
import Testing

@testable import ABSData
@testable import ABSDownloads

/// Connections with custom headers download in the foreground session, whose delegate keeps the
/// headers on the server (#467).
@Suite(.timeLimit(.minutes(1))) struct DownloadEngineForegroundTests {
    private static let header = "CF-Access-Client-Secret"
    private static let headers = [header: "proxy-secret"]
    private static let resumeData = Data("resume: Bearer token-1, CF-Access-Client-Secret: proxy-secret".utf8)

    /// A host the stub answers, to see what a redirect off the server would send it.
    private static func otherOrigin() -> String {
        let host = "\(UUID().uuidString.lowercased()).elsewhere.test"
        StubDownloadProtocol.register(host: host) { _ in .status(200) }
        return host
    }

    @Test func customHeadersDownloadInTheForegroundSession() async throws {
        let harness = try await DownloadHarness(customHeaders: Self.headers) { _ in .status(200) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(hasForegroundSession: true)

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        let request = try #require(harness.requests.first)
        #expect(harness.requests.count == 1)
        #expect(request.authorization == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
        #expect(harness.foregroundSessions.withLock { $0.count } == 1)
        let background = try #require(harness.session)
        #expect(await background.allTasks.isEmpty)
    }

    /// A same-origin hop is followed with the headers, `Authorization` included.
    @Test func aSameOriginRedirectKeepsTheHeaders() async throws {
        let harness = try await DownloadHarness(customHeaders: Self.headers) { _ in .status(200) }
        let base = harness.base
        StubDownloadProtocol.register(host: harness.host) { request in
            request.url?.path().hasPrefix("/abs/media/") == true
                ? .status(200) : .redirect(to: URL(string: "\(base)/media/1.mp3")!)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(hasForegroundSession: true)

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        let hop = try #require(harness.requests.last)
        #expect(harness.requests.count == 2)
        #expect(hop.url?.path() == "/abs/media/1.mp3")
        #expect(hop.authorization == "Bearer token-1")
        #expect(hop.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
    }

    /// A redirect off the server is refused before anything is sent there, and the part fails
    /// for good, as a preflight's off-origin finding does.
    @Test func aCrossOriginRedirectIsRefused() async throws {
        let other = Self.otherOrigin()
        let harness = try await DownloadHarness(customHeaders: Self.headers) { _ in
            .redirect(to: URL(string: "https://\(other)/1.mp3")!)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(hasForegroundSession: true)

        await engine.start(partIDs: [partID])

        #expect(
            await engine.nextPermanentFailure()
                == .partFailed(
                    partID: partID, recordID: record.id, code: .offOrigin,
                    message: "The download was redirected to another server.", willRetry: false))
        #expect(StubDownloadProtocol.requests(host: other).isEmpty)
        #expect(
            !StubDownloadProtocol.requests(host: other).contains { $0.value(forHTTPHeaderField: Self.header) != nil })
        #expect(harness.requests.count == 1)
        #expect(!harness.fileExists("li_1/1.mp3"))
    }

    /// A transfer resumed from its resume data (a `Range` request) is checked the same way.
    @Test func aCrossOriginRedirectOfAResumeIsRefused() async throws {
        let other = Self.otherOrigin()
        let harness = try await DownloadHarness(customHeaders: Self.headers) {
            $0.stubCount == 1
                ? .failure(resumeData: Self.resumeData) : .redirect(to: URL(string: "https://\(other)/1.mp3")!)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0), hasForegroundSession: true)
        await engine.start(partIDs: [partID])
        #expect(await engine.nextPermanentFailure() != nil)
        #expect(try await harness.store.part(id: partID)?.hasResumeData == true)
        try await harness.store.setState(.queued, forRecord: record.id)

        await engine.start(partIDs: [partID])

        #expect(
            await engine.nextPermanentFailure()
                == .partFailed(
                    partID: partID, recordID: record.id, code: .offOrigin,
                    message: "The download was redirected to another server.", willRetry: false))
        #expect(harness.foregroundSessions.withLock { $0.last?.resumedData } == [Self.resumeData])
        #expect(StubDownloadProtocol.requests(host: other).isEmpty)
        #expect(
            !StubDownloadProtocol.requests(host: other).contains { $0.value(forHTTPHeaderField: Self.header) != nil })
        #expect(harness.requests.count == 2)
    }

    /// Going to the background pauses a foreground transfer, keeping its resume data, and
    /// nothing starts one until the next activation, which continues it.
    @Test func backgroundingPausesForegroundTransfersUntilTheNextActivation() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness(customHeaders: Self.headers) {
            $0.stubCount == 1 ? .status(200, gate: never) : .status(200)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(
            cancel: { task in
                task.cancel()
                return Self.resumeData
            }, hasForegroundSession: true)
        #expect(await engine.activate())
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)

        await engine.deactivate()

        let paused = try #require(try await harness.store.part(id: partID))
        #expect(paused.state == .queued)
        #expect(paused.hasResumeData)
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        // Nothing starts it while the app is in the background.
        await engine.start(partIDs: [partID])
        #expect(harness.requests.count == 1)
        #expect(try await harness.store.part(id: partID)?.state == .queued)

        #expect(await engine.activate())

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 2)
        #expect(harness.foregroundSessions.withLock { $0.last?.resumedData } == [Self.resumeData])
    }

    /// Backgrounded while a foreground launch saves its part as running: the stop queues the
    /// part, and the launch's later save would leave it running with no transfer, which no
    /// activation restarts. The launch queues it again, so the next activation continues it.
    @Test func aForegroundLaunchStoppedWhileSavingStartsOnTheNextActivation() async throws {
        let harness = try await DownloadHarness(customHeaders: Self.headers) { _ in .status(200) }
        let partID = UUID()
        // One-shot: the next activation's launch passes the same seam.
        let current = Mutex<(engine: DownloadEngine?, deactivates: Bool)>((nil, true))
        let engine = harness.makeEngine(
            beforeSavingRunning: { _ in
                let (engine, deactivates) = current.withLock { state in
                    defer { state.deactivates = false }
                    return (state.engine, state.deactivates)
                }
                if deactivates { await engine?.deactivate() }
            }, hasForegroundSession: true)
        current.withLock { $0.engine = engine }
        // Activated before the record exists, so only this start launches the part.
        #expect(await engine.activate())
        await engine.waitForRestart()
        try await harness.addRecord(parts: [partID])

        await engine.start(partIDs: [partID])

        try #require(try await harness.store.part(id: partID)?.state == .queued)
        #expect(harness.requests.isEmpty)
        #expect(await engine.activate())
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 1)
    }

    /// The same for a launch continuing from resume data: the stop seals it again, and the part
    /// is queued with its resume data still flagged, so a relaunched engine continues it rather
    /// than downloading the file again.
    @Test func aForegroundResumeStoppedWhileSavingKeepsItsResumeData() async throws {
        let harness = try await DownloadHarness(customHeaders: Self.headers) {
            $0.stubCount == 1 ? .failure(resumeData: Self.resumeData) : .status(200)
        }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let current = Mutex<(engine: DownloadEngine?, deactivates: Bool)>((nil, false))
        let engine = harness.makeEngine(
            retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0),
            cancel: { task in
                task.cancel()
                return Self.resumeData
            },
            beforeSavingRunning: { _ in
                let (engine, deactivates) = current.withLock { state in
                    defer { state.deactivates = false }
                    return (state.engine, state.deactivates)
                }
                if deactivates { await engine?.deactivate() }
            }, hasForegroundSession: true)
        current.withLock { $0.engine = engine }
        // The first transfer fails, leaving resume data.
        await engine.start(partIDs: [partID])
        #expect(await engine.nextPermanentFailure() != nil)
        try #require(try await harness.store.part(id: partID)?.hasResumeData == true)
        try await harness.store.setState(.queued, forRecord: record.id)
        current.withLock { $0.deactivates = true }

        await engine.start(partIDs: [partID])

        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .queued)
        #expect(part.hasResumeData)
        #expect(harness.requests.count == 1)
        let request = try #require(harness.requests.first)
        let relaunched = harness.makeEngine(
            registry: DownloadEngineRegistry(), hasForegroundSession: true, prepareForeground: { $0.remember(request) })
        #expect(await relaunched.activate())
        #expect(await relaunched.nextRecordComplete() != nil)
        #expect(harness.requests.count == 2)
        #expect(harness.foregroundSessions.withLock { $0.last?.resumedData } == [Self.resumeData])
    }

    /// Reactivated after the stopped launch's late save but before it queues the part again:
    /// the activation skipped the part as running, so the launch starts it once it is queued.
    @Test func reactivationWhileAStoppedForegroundLaunchRequeuesStartsThePart() async throws {
        let gate = StubGate()
        // Held until the part is checked, so the transfer can't complete before the read.
        let harness = try await DownloadHarness(customHeaders: Self.headers) { _ in .status(200, gate: gate) }
        let partID = UUID()
        // One-shot hooks: the launch that follows passes the same seams.
        let current = Mutex<(engine: DownloadEngine?, deactivates: Bool, activates: Bool)>((nil, true, true))
        let engine = harness.makeEngine(
            beforeSavingRunning: { _ in
                let (engine, deactivates) = current.withLock { state in
                    defer { state.deactivates = false }
                    return (state.engine, state.deactivates)
                }
                if deactivates { await engine?.deactivate() }
            },
            beforeRequeueingInactive: { _ in
                let (engine, activates) = current.withLock { state in
                    defer { state.activates = false }
                    return (state.engine, state.activates)
                }
                guard activates, let engine else { return }
                #expect(await engine.activate())
                await engine.waitForRestart()
            }, hasForegroundSession: true)
        current.withLock { $0.engine = engine }
        // Activated before the record exists, so only this start launches the part.
        #expect(await engine.activate())
        await engine.waitForRestart()
        try await harness.addRecord(parts: [partID])

        await engine.start(partIDs: [partID])

        try #require(try await harness.store.part(id: partID)?.state == .running)
        gate.open()
        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.requests.count == 1)
    }

    /// Backgrounded after a foreground transfer finished but before the engine handled its
    /// completion: the finished task isn't stopped, so its moved file completes the part rather
    /// than the part being queued to download again.
    @Test func backgroundingLeavesAFinishedForegroundTransferToItsCompletion() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness(customHeaders: Self.headers) {
            $0.url?.path().contains("li_2") == true ? .status(200, gate: gate) : .status(200)
        }
        let first = UUID()
        let second = UUID()
        let record = try await harness.addRecord(parts: [first])
        let other = try await harness.store.upsertRecord(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: harness.connectionID, libraryItemId: "li_2"),
                mediaType: .book, title: "The Other Book", state: .queued, relativeDirectory: "li_2",
                media: LocalMediaSnapshot(metadata: .init(title: "The Other Book")),
                parts: [
                    DownloadPartDTO(
                        id: second, kind: .audio, serverPath: DownloadRequests.filePath(itemID: "li_2", ino: "1"),
                        filename: "1.mp3", mimeType: "audio/mpeg", serverIno: "1", trackIndex: 1, expectedBytes: 11,
                        bytesWritten: 0, destinationRelativePath: "li_2/1.mp3", state: .queued)
                ])
        ).record
        let (handled, finished) = AsyncStream.makeStream(of: Void.self)
        let current = Mutex<DownloadEngine?>(nil)
        // Holds the event loop on the first record's finalisation until the second transfer has
        // finished, so its completion is still waiting when the app goes to the background.
        let engine = harness.makeEngine(
            afterUpsertingLocalItem: { recordID in
                guard recordID == record.id, let engine = current.withLock({ $0 }) else { return }
                gate.open()
                await harness.waitForCompletions(2)
                await engine.deactivate()
                finished.yield()
            }, hasForegroundSession: true)
        current.withLock { $0 = engine }
        // The activation starts both queued parts.
        #expect(await engine.activate())

        for await _ in handled { break }
        await engine.waitForRestart()

        // Completed and finalised: the record is gone, not queued to download again.
        #expect(try await harness.store.record(id: other.id) == nil)
        #expect(try await harness.store.part(id: second) == nil)
        #expect(harness.requests.count == 2)
    }

    /// The foreground session keeps `Authorization` on a same-origin hop, so a 401 there is the
    /// token's: it is refreshed and the part downloads, rather than failing as a redirect that
    /// dropped the sign-in.
    @Test func anUnauthorizedAnswerAfterASameOriginRedirectRefreshesTheToken() async throws {
        let harness = try await DownloadHarness(customHeaders: Self.headers) { _ in .status(200) }
        let base = harness.base
        StubDownloadProtocol.register(host: harness.host) { request in
            guard request.url?.path().hasPrefix("/abs/media/") == true else {
                return .redirect(to: URL(string: "\(base)/media/1.mp3")!)
            }
            return request.authorization == "Bearer token-1" ? .status(401) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(hasForegroundSession: true)

        await engine.start(partIDs: [partID])

        let update = await engine.next {
            switch $0 {
            case .recordComplete, .partFailed: true
            default: false
            }
        }
        guard case .recordComplete = update else {
            Issue.record("Expected the download to complete, got \(String(describing: update))")
            return
        }
        #expect(harness.credentials.calls == [nil, "token-1"])
        #expect(
            harness.requests.map(\.authorization) == [
                "Bearer token-1", "Bearer token-1", "Bearer token-2", "Bearer token-2",
            ])
    }
}
