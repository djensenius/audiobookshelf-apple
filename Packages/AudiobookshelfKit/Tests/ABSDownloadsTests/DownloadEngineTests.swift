import ABSAPI
import ABSData
import Foundation
import Testing

@testable import ABSDownloads

@Suite(.timeLimit(.minutes(1))) struct DownloadEngineTests {
    @Test func movesFinishedFileToContainerRelativeDestination() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() == .recordComplete(recordID: record.id))
        #expect(try Data(contentsOf: harness.fileURL("li_1/1.mp3")) == Data("audio-bytes".utf8))
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .completed)
        #expect(part.destinationRelativePath == "li_1/1.mp3")
        #expect(part.bytesWritten == 11)
        #expect(part.taskIdentifier == nil)
        #expect(try await harness.store.record(id: record.id)?.state == .downloading)
        let request = try #require(harness.requests.first)
        #expect(harness.requests.count == 1)
        #expect(request.url?.absoluteString == "https://\(harness.host)/abs/api/items/li_1/file/1/download")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "proxy-secret")
        #expect(harness.credentials.calls == [nil])
    }

    @Test func errorStatusNeverReachesMediaLocation() async throws {
        let harness = try await DownloadHarness { _ in .status(404, body: Data("Not Found".utf8)) }
        let partID = UUID()
        let record = try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        let message = "The server returned HTTP 404."
        #expect(
            await engine.nextPermanentFailure()
                == .partFailed(partID: partID, recordID: record.id, message: message, willRetry: false))
        #expect(!FileManager.default.fileExists(atPath: harness.fileURL("li_1/1.mp3").path(percentEncoded: false)))
        let part = try #require(try await harness.store.part(id: partID))
        #expect(part.state == .failed)
        #expect(part.lastError == message)
        #expect(try await harness.store.record(id: record.id)?.state == .failed)
        #expect(harness.requests.count == 1)
    }

    @Test func retriesServerErrorsWithBackoff() async throws {
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
        #expect(try await harness.store.part(id: partID)?.retryCount == 2)
        #expect(FileManager.default.fileExists(atPath: harness.fileURL("li_1/1.mp3").path(percentEncoded: false)))
    }

    @Test func recreatesTaskOnceAfterUnauthorized() async throws {
        let harness = try await DownloadHarness {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" ? .status(401) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.credentials.calls == [nil, "token-1"])
        #expect(
            harness.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer token-1", "Bearer token-2",
            ])
        #expect(harness.clock.sleeps.isEmpty)
        #expect(try Data(contentsOf: harness.fileURL("li_1/1.mp3")) == Data("audio-bytes".utf8))
    }

    @Test func failsAfterSecondUnauthorized() async throws {
        let harness = try await DownloadHarness { _ in .status(401) }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextPermanentFailure() != nil)
        #expect(harness.requests.count == 2)
        #expect(harness.credentials.calls == [nil, "token-1"])
        #expect(!FileManager.default.fileExists(atPath: harness.fileURL("li_1/1.mp3").path(percentEncoded: false)))
    }

    private static let resumeData = Data("resume: Bearer token-1, X-Proxy: proxy-secret".utf8)

    /// Fails the part's first transfer with resume data and no retries left.
    private func failWithResumeData() async throws -> (DownloadHarness, DownloadEngine, UUID) {
        let harness = try await DownloadHarness {
            $0.stubCount == 1 ? .failure(resumeData: Self.resumeData) : .status(200)
        }
        let partID = UUID()
        try await harness.addRecord(parts: [partID])
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: [partID])
        #expect(await engine.nextPermanentFailure() != nil)
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
        #expect(harness.credentials.calls == [nil])
        #expect(!FileManager.default.fileExists(atPath: blobURL.path(percentEncoded: false)))
        #expect(try await harness.store.part(id: partID)?.hasResumeData == false)
    }

    @Test func credentialChangeDiscardsResumeData() async throws {
        let (harness, engine, partID) = try await failWithResumeData()
        harness.credentials.rotate()

        await engine.start(partIDs: [partID])

        #expect(await engine.nextRecordComplete() != nil)
        #expect(harness.session?.resumedData == [])
        #expect(harness.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
        #expect(
            !FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false)))
    }

    @Test func reattachesToSurvivingTasksAndRestartsOrphans() async throws {
        let harness = try await DownloadHarness { request in
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer previous": .status(200, delay: 0.5)
            case nil: .status(200, delay: 30)
            default: .status(200)
            }
        }
        let running = UUID()
        let orphan = UUID()
        let record = try await harness.addRecord(parts: [running, orphan], state: .downloading, partState: .running)
        let base = "https://\(harness.host)/abs"
        // What a previous launch left in the session: the running part's transfer and one the
        // engine doesn't know.
        let engine = harness.makeEngine { stub in
            var request = URLRequest(url: URL(string: base + DownloadRequests.filePath(itemID: "li_1", ino: "1"))!)
            request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
            stub.leaveTask(request, description: running.uuidString)
            stub.leaveTask(URLRequest(url: URL(string: base + "/unknown")!), description: "not a part")
        }

        await engine.activate()

        #expect(await engine.nextRecordComplete() == .recordComplete(recordID: record.id))
        let downloads = harness.requests.filter { $0.url?.path().hasSuffix("/download") == true }
        let authorization = Dictionary(
            uniqueKeysWithValues: downloads.map { ($0.url?.path(), $0.value(forHTTPHeaderField: "Authorization")) })
        #expect(downloads.count == 2)
        #expect(authorization["/abs/api/items/li_1/file/1/download"] == "Bearer previous")
        #expect(authorization["/abs/api/items/li_1/file/2/download"] == "Bearer token-1")
        #expect(harness.credentials.calls == [nil])
        let unknown = try #require(harness.session?.leftovers.withLock { $0.last })
        #expect(unknown.state != .running)
        #expect(FileManager.default.fileExists(atPath: harness.fileURL("li_1/1.mp3").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: harness.fileURL("li_1/2.mp3").path(percentEncoded: false)))
    }
}
