import ABSAPI
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

    /// One part fails for good while the others download: the failure's code is stored with the
    /// part (#73). The user's retry, through the manager, clears it as the part starts again,
    /// fetches it again, and the record becomes the local item.
    @Test func aRetryAfterAPartialFailureCompletesTheBook() async throws {
        let failing = Mutex(true)
        let retry = StubGate()
        let harness = try await DownloadHarness { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/api/items/li_book/cover") {
                return .status(200, body: Self.cover, contentType: "image/jpeg")
            }
            let ino = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            guard let body = Self.bodies[ino] else { return .status(404) }
            if ino == "102" {
                if failing.withLock({ $0 }) { return .status(404, body: Data("Nope".utf8)) }
                return .status(200, body: body, contentType: "audio/mpeg", gate: retry)
            }
            return .status(200, body: body, contentType: ino == "201" ? "application/epub+zip" : "audio/mpeg")
        }
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
        let failure = await events.next { if case .failed = $0 { true } else { false } }
        guard case .failed(recordID, .httpStatus, _) = failure else {
            Issue.record("Unexpected \(String(describing: failure))")
            return
        }
        let failed = try #require(try await harness.store.record(id: recordID))
        let part = try #require(failed.parts.first { $0.serverIno == "102" })
        #expect(failed.state == .failed)
        #expect(part.state == .failed && part.failureCode == .httpStatus)
        #expect(failed.failureCode == .httpStatus)

        failing.withLock { $0 = false }
        let requests = harness.requests.count
        #expect(try await manager.retry(recordID: recordID))
        #expect(try await harness.store.part(id: part.id)?.lastErrorCode == nil)
        retry.open()

        let completed = await events.next { if case .completed = $0 { true } else { false } }
        guard case .completed(recordID, let itemID, _) = completed else {
            Issue.record("Unexpected \(String(describing: completed))")
            return
        }
        let local = try #require(try await harness.localItems.item(id: itemID))
        #expect(local.files.map(\.size) == [1_000, 2_000, 3_000, 4_000])
        // The failed part was fetched again (its siblings, stopped as it failed, resume as well).
        #expect(harness.requests.dropFirst(requests).contains { $0.url?.path().contains("/file/102/") == true })
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

    /// A new request's guarded resume queues its record, then fails to read it and to pause it
    /// again, with no quiesce. An activation before the manager deletes the record pauses it
    /// rather than starting a transfer that would outlive the failed request (#520), and a
    /// later request for the item starts.
    @Test func anActivationBeforeAFailedRequestIsDiscardedStartsNothing() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        let failsRead = Mutex(false)
        let engine = harness.makeEngine(readRecord: { store, id in
            if failsRead.withLock({ $0 }) {
                failsRead.withLock { $0 = false }
                // The rollback's write fails too.
                await store.failNextCommit(with: TestError())
                throw TestError()
            }
            return try await store.record(id: id)
        })
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: ActivatingOnFailedResume(base: engine),
            locations: harness.locations, capacity: FakeCapacity(), clock: harness.clock)
        try await manager.start()
        #expect(await engine.activate())
        await engine.waitForRestart()
        let item = LibraryItemFixtures.book()

        failsRead.withLock { $0 = true }
        await #expect(throws: DownloadManagerError.storeFailure) {
            try await manager.enqueue(
                item: item, episodeID: nil, connectionID: harness.connectionID,
                unlessQuiescedSince: await manager.quiesceGeneration())
        }

        #expect(try await harness.store.allRecords().isEmpty)
        #expect(await engine.activate())
        await engine.waitForRestart()
        let tasks = await harness.session?.session.allTasks ?? []
        #expect(tasks.allSatisfy { $0.state != .running })
        #expect(harness.requests.isEmpty)

        let result = try await manager.enqueue(
            item: item, episodeID: nil, connectionID: harness.connectionID,
            unlessQuiescedSince: await manager.quiesceGeneration())
        guard case .started = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        await harness.waitForRequests(1)
        never.open()
    }

    /// A sign-out's pauses wait on each other for episodes of one podcast (the manager holds the
    /// podcast's item for each), so one whose cancellation hangs would keep the other's transfer
    /// running with the old credentials: the quiesce cancels every transfer before pausing.
    @Test func quiesceStopsEveryEpisodeEvenIfAPauseWouldHang() async throws {
        let never = StubGate()
        let harness = try await DownloadHarness { _ in .status(200, gate: never) }
        var records: [DownloadRecordDTO] = []
        for episode in ["ep_1", "ep_2"] {
            let record = DownloadRecordDTO(
                key: MediaKey(serverConnectionID: harness.connectionID, libraryItemId: "li_1", episodeId: episode),
                mediaType: .podcast, title: episode, state: .queued, relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Podcast")),
                parts: [
                    DownloadPartDTO(
                        kind: .audio, serverPath: DownloadRequests.filePath(itemID: "li_1", ino: episode),
                        filename: "\(episode).mp3", mimeType: "audio/mpeg", episodeId: episode, expectedBytes: 11,
                        destinationRelativePath: "li_1/\(episode).mp3")
                ])
            records.append(try await harness.store.upsertRecord(record).record)
        }
        // The first cancellation that keeps resume data never returns until released.
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
        await harness.waitForRequests(2)

        // The sign-out's cleanup, as DownloadsLifecycle runs it.
        let recordIDs = records.map(\.id)
        let quiescing = Task {
            await engine.quiesce(connectionID: harness.connectionID) {
                await withTaskGroup(of: Void.self) { group in
                    for recordID in recordIDs {
                        group.addTask { _ = try? await manager.pause(recordID: recordID) }
                    }
                }
            }
        }
        // Whichever comes first: the quiesce ends, or a pause hangs in its cancellation.
        let (outcomes, outcome) = AsyncStream.makeStream(of: Bool.self)
        Task {
            _ = await quiescing.value
            outcome.yield(true)
        }
        let watching = Task {
            for await _ in cancelStarted {
                outcome.yield(false)
                break
            }
        }
        let ended = await outcomes.first { _ in true } ?? false
        watching.cancel()

        let running = await harness.session?.session.allTasks.filter { $0.state == .running } ?? []
        #expect(running.isEmpty)
        #expect(ended)
        release.open()
        _ = await quiescing.value
        for record in records {
            #expect(try await harness.store.record(id: record.id)?.state == .paused)
        }
        never.open()
    }

    /// Deleting a podcast while its cover is fetched again (a cover-only record) cancels that
    /// transfer: its task completes cancelled, the record goes with its transfer marker and
    /// resume data, the request stays the only one, and no cover file is ever written for the
    /// deleted podcast.
    @Test func deletingAPodcastCancelsItsCoverRefetch() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { request in
            request.url?.path().hasSuffix("/cover") == true
                ? .status(200, body: Self.cover, contentType: "image/jpeg", gate: gate) : .status(404)
        }
        let podcast = LibraryItemFixtures.podcast()
        var episode = try DownloadPlanner(locations: harness.locations).plan(
            item: podcast, episodeID: "ep_1", connectionID: harness.connectionID, existingCoverPath: nil)
        episode.parts.removeAll { $0.kind == .cover }
        for index in episode.parts.indices {
            episode.parts[index].state = .completed
            episode.parts[index].bytesWritten = episode.parts[index].expectedBytes
        }
        let local = try await harness.localItems.upsertFromDownload(episode)
        try #require(local.coverRelativePath == nil)
        let itemKey = MediaKey(serverConnectionID: harness.connectionID, libraryItemId: podcast.id)
        let partID = UUID()
        let destination = "\(local.relativeDirectory)/cover-\(partID.uuidString.lowercased()).jpg"
        let refetch = try #require(
            try await harness.store.insertRecordIfSignedIn(
                DownloadRecordDTO(
                    key: itemKey, mediaType: .podcast, title: local.title, relativeDirectory: local.relativeDirectory,
                    media: LocalMediaSnapshot(metadata: local.media.metadata),
                    parts: [
                        DownloadPartDTO(
                            id: partID, kind: .cover,
                            serverPath: DownloadRequests.coverPath(itemID: podcast.id, updatedAt: 0),
                            filename: DownloadLayout.coverFilename, mimeType: "image/jpeg", expectedBytes: 0,
                            bytesWritten: 0, destinationRelativePath: destination, state: .queued)
                    ])))
        try #require(refetch.isCoverOnly)
        let engine = harness.makeEngine()
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: engine, locations: harness.locations,
            capacity: FakeCapacity(), clock: harness.clock)
        try await manager.start()
        let events = await manager.events()
        await engine.start(partIDs: [partID])
        await harness.waitForRequests(1)
        try #require(harness.locations.transferStart(partID: partID) != nil)

        #expect(try await manager.deleteLocalItem(id: local.id))

        // Waits for the task's completion, with the reply let through, so a transfer left
        // running would finish rather than stay pending, then for the engine to handle it.
        gate.open()
        await harness.waitForCompletions(1)
        await engine.processPendingEvents()
        #expect(harness.completionErrors.withLock { $0 } == [.cancelled])
        #expect(try await harness.store.record(id: refetch.id) == nil)
        #expect(harness.locations.transferStart(partID: partID) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path()))
        #expect(await events.next { $0 == .recordRemoved(recordID: refetch.id) } != nil)
        #expect(harness.requests.count == 1)
        #expect(!harness.fileExists(destination))
        #expect(!harness.fileExists(local.relativeDirectory))
    }
}

/// The real engine, which runs an activation (and its restart) when a new record's guarded
/// resume fails, before the manager handles the error.
private struct ActivatingOnFailedResume: DownloadEngineControlling {
    let base: DownloadEngine

    var updates: AsyncStream<DownloadUpdate> { base.updates }
    var progress: AsyncStream<DownloadProgress> { base.progress }

    func start(partIDs: [UUID]) async { await base.start(partIDs: partIDs) }
    func stop(partIDs: [UUID], keepingResumeData: Bool) async {
        await base.stop(partIDs: partIDs, keepingResumeData: keepingResumeData)
    }
    func attachSurvivingTransfers() async -> Bool { await base.attachSurvivingTransfers() }
    func pause(recordID: UUID) async throws -> Bool { try await base.pause(recordID: recordID) }
    func resume(recordID: UUID) async throws -> Bool { try await base.resume(recordID: recordID) }
    func resume(recordID: UUID, unlessQuiescedSince generation: Int) async throws -> Bool {
        try await base.resume(recordID: recordID, unlessQuiescedSince: generation)
    }
    func resumeNewRecord(recordID: UUID, unlessQuiescedSince generation: Int) async throws -> Bool {
        do {
            return try await base.resumeNewRecord(recordID: recordID, unlessQuiescedSince: generation)
        } catch {
            _ = await base.activate()
            await base.waitForRestart()
            throw error
        }
    }
    func quiesceGeneration() async -> Int { await base.quiesceGeneration() }
    func hasQuiesced(connectionID: UUID, since generation: Int) async -> Bool {
        await base.hasQuiesced(connectionID: connectionID, since: generation)
    }
}
