import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``DownloadManager`` with the real ``DownloadEngine`` over ``StubDownloadSession``.
@Suite(.timeLimit(.minutes(1))) struct DownloadManagerIntegrationTests {
    /// Each fixture file's body, sized as the server reported it.
    static let bodies: [String: Data] = [
        "101": Data(repeating: 1, count: 1_000), "102": Data(repeating: 2, count: 2_000),
        "103": Data(repeating: 3, count: 3_000), "201": Data(repeating: 4, count: 4_000),
    ]
    static let cover = Data("jpeg-bytes".utf8)

    @Test func aQueuedBookBecomesALocalItem() async throws {
        let harness = try await DownloadHarness { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/api/items/li_book/cover") {
                return .status(200, body: Self.cover, contentType: "image/jpeg")
            }
            let ino = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            guard let body = Self.bodies[ino] else { return .status(404) }
            return .status(200, body: body, contentType: ino == "201" ? "application/epub+zip" : "audio/mpeg")
        }
        let engine = harness.makeEngine()
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: engine, locations: harness.locations,
            capacity: FakeCapacity(), clock: harness.clock)
        try await manager.start()
        let events = await manager.events()
        let item = LibraryItemFixtures.book()

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: harness.connectionID)

        guard case .started(let recordID) = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        let completed = await events.next {
            if case .completed = $0 { true } else { false }
        }
        guard case .completed(recordID, let itemID, let key) = completed else {
            Issue.record("Unexpected \(String(describing: completed))")
            return
        }
        #expect(key == MediaKey(serverConnectionID: harness.connectionID, libraryItemId: "li_book"))
        #expect(try await harness.store.record(id: recordID) == nil)
        let local = try #require(try await harness.localItems.item(id: itemID))
        let folder = "\(harness.connectionID.uuidString)/li_book"
        #expect(local.relativeDirectory == folder)
        #expect(local.files.map(\.kind) == [.audio, .audio, .audio, .ebook])
        #expect(
            local.files.map(\.relativePath) == [
                "\(folder)/01 - Part One.mp3", "\(folder)/02 - Part Two.mp3", "\(folder)/03 - Part Three.mp3",
                "\(folder)/Dune.epub",
            ])
        #expect(local.files.map(\.size) == [1_000, 2_000, 3_000, 4_000])
        #expect(local.coverRelativePath == "\(folder)/cover.jpg")
        let coverUpdatedAt = try #require(local.coverUpdatedAt)
        #expect(abs(coverUpdatedAt.timeIntervalSince1970 - 1_700_000_000.123) < 0.000_1)
        #expect(try Data(contentsOf: harness.fileURL("\(folder)/cover.jpg")) == Self.cover)
        #expect(try Data(contentsOf: harness.fileURL("\(folder)/Dune.epub")) == Self.bodies["201"])
        let coverRequest = try #require(harness.requests.first { $0.url?.path().hasSuffix("/cover") == true })
        #expect(coverRequest.url?.query() == "width=1200&format=jpeg&ts=1700000000123")
    }

    /// Once a transfer starts, the record is reported downloading, before any part completes.
    @Test func aStartedTransferIsReportedDownloading() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: gate) }
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: harness.makeEngine(),
            locations: harness.locations, capacity: FakeCapacity(), clock: harness.clock)
        try await manager.start()
        let events = await manager.events()

        let result = try await manager.enqueue(
            item: LibraryItemFixtures.book(), episodeID: nil, connectionID: harness.connectionID)

        guard case .started(let recordID) = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        let started = await events.next {
            if case .recordChanged(let record) = $0 { record.state == .downloading } else { false }
        }
        guard case .recordChanged(let record) = started else {
            Issue.record("Unexpected \(String(describing: started))")
            return
        }
        #expect(record.id == recordID)
        #expect(record.parts.allSatisfy { $0.state != .completed })
        gate.open()
    }

    /// A restart for a stricter cellular policy pauses a downloading record, then resumes it. A
    /// sign-out's cleanup that begins in between (here, while the pause stops the transfer)
    /// passes over the paused record, so the resume starts nothing: no transfer runs on with
    /// the old credentials, and the record stays paused like the rest.
    @Test func restartDoesNotResumeARecordWhoseServerIsQuiescedMeanwhile() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let record = try await harness.addRecord(parts: [UUID()])
        let (cancelStarted, cancelContinuation) = AsyncStream.makeStream(of: Void.self)
        let release = StubGate()
        let held = Mutex(false)
        let engine = harness.makeEngine(cancel: { task in
            if !held.withLock({ held in
                defer { held = true }
                return held
            }) {
                cancelContinuation.yield()
                await withCheckedContinuation { continuation in release.run { continuation.resume() } }
            }
            return await task.cancelByProducingResumeData()
        })
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: engine, locations: harness.locations,
            capacity: FakeCapacity(), clock: harness.clock)
        try await manager.start()
        #expect(await engine.activate())
        await harness.waitForRequests(1)
        try #require(try await harness.store.record(id: record.id)?.state == .downloading)

        let restart = Task { try await manager.restartActiveTransfers() }
        for await _ in cancelStarted { break }
        // The sign-out's cleanup, as DownloadsLifecycle runs it.
        let (paused, pausedContinuation) = AsyncStream.makeStream(of: Void.self)
        let store = harness.store
        let connectionID = harness.connectionID
        let cleanup = Task {
            await engine.quiesce(connectionID: connectionID) {
                for record in (try? await store.records(serverConnectionID: connectionID)) ?? []
                where [.queued, .downloading].contains(record.state) {
                    _ = try? await manager.pause(recordID: record.id)
                }
                pausedContinuation.yield()
            }
        }
        for await _ in paused { break }
        release.open()
        _ = await cleanup.value
        try await restart.value

        #expect(try await harness.store.record(id: record.id)?.state == .paused)
        let tasks = await harness.session?.session.allTasks ?? []
        #expect(tasks.allSatisfy { $0.state != .running })
        never.open()
    }
}
