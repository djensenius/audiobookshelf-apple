import ABSAPI
import Foundation
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
}
