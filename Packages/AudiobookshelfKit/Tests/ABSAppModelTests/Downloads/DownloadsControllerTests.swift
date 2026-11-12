import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

/// A path source that reports one path as soon as it is monitored.
private struct FixedPathSource: NetworkPathSource {
    let path: NetworkPath

    func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in continuation.yield(path) }
    }
}

/// A hand-driven ``DownloadManaging`` that records its calls.
private actor FakeDownloadManager: DownloadManaging {
    struct Enqueue: Equatable {
        let itemID: String
        let episodeID: String?
        let connectionID: UUID
    }

    private(set) var enqueues: [Enqueue] = []
    /// Calls to `restartActiveTransfers()`, including those that failed.
    private(set) var restarts = 0
    /// How many of the next restarts throw.
    private var failingRestarts = 0
    private var result: Result<DownloadManager.EnqueueResult, DownloadManagerError>
    private var subscribers: [AsyncStream<DownloadManagerEvent>.Continuation] = []

    init(result: Result<DownloadManager.EnqueueResult, DownloadManagerError> = .success(.started(UUID()))) {
        self.result = result
    }

    func events() -> AsyncStream<DownloadManagerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadManagerEvent.self)
        subscribers.append(continuation)
        return stream
    }

    func send(_ event: DownloadManagerEvent) {
        for subscriber in subscribers { subscriber.yield(event) }
    }

    func enqueue(
        item: LibraryItem, episodeID: String?, connectionID: UUID, replacingExisting: Bool
    ) async throws(DownloadManagerError) -> DownloadManager.EnqueueResult {
        enqueues.append(Enqueue(itemID: item.id, episodeID: episodeID, connectionID: connectionID))
        return try result.get()
    }

    func failRestarts(_ count: Int) {
        failingRestarts = count
    }

    func restartActiveTransfers() async throws(DownloadManagerError) {
        restarts += 1
        if failingRestarts > 0 {
            failingRestarts -= 1
            throw .storeFailure
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DownloadsControllerTests {
    nonisolated static let connectionID = UUID()
    nonisolated static let item = LibraryItem(
        id: "li1", libraryId: "lib", mediaType: .book,
        media: .book(Book(id: "book-li1", metadata: BookMetadata(title: "Title"), numTracks: 1)))
    nonisolated static let lowDataWifi = NetworkPath(isOnline: true, isConstrained: true, interface: .wifi)
    nonisolated static let hotspot = NetworkPath(isOnline: true, isExpensive: true, interface: .wifi)
    nonisolated static let expensiveOther = NetworkPath(isOnline: true, isExpensive: true, interface: .other)

    /// A controller over a fresh settings store and a path that is known before the first request.
    private func makeController(
        path: NetworkPath = .wifi, policy: CellularPolicy = .always, treatsExpensiveAsCellular: Bool = false,
        manager: FakeDownloadManager = FakeDownloadManager(),
        storedRecords: @escaping @Sendable () async throws -> [DownloadRecordDTO] = { [] }
    ) throws -> (DownloadsController, AppSettings, cleanUp: () -> Void) {
        let suiteName = "ABSAppModelTests.Downloads.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.downloadUsingCellular = policy
        let monitor = NetworkMonitor(source: FixedPathSource(path: path))
        monitor.start()
        let access = DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
        let controller = DownloadsController(
            manager: manager, monitor: monitor, settings: settings, networkAccess: access,
            storedRecords: storedRecords, pathTimeout: .seconds(30))
        return (controller, settings, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private static func record(
        _ title: String, createdAt: Date, state: DownloadState = .queued, id: UUID = UUID()
    ) -> DownloadRecordDTO {
        DownloadRecordDTO(
            id: id, key: MediaKey(serverConnectionID: connectionID, libraryItemId: title), mediaType: .book,
            title: title,
            state: state, relativeDirectory: title, createdAt: createdAt,
            media: LocalMediaSnapshot(metadata: .init(title: title)))
    }

    // MARK: - Policy and path

    struct PathCase: Sendable, CustomTestStringConvertible {
        let name: String
        let path: NetworkPath
        let treatsExpensiveAsCellular: Bool
        /// Why the path is metered, or `nil` if every policy allows it.
        let reason: MeteredReason?

        var testDescription: String { name }
    }

    nonisolated static let pathCases: [PathCase] = [
        PathCase(name: "wifi", path: .wifi, treatsExpensiveAsCellular: false, reason: nil),
        PathCase(name: "wired", path: .wired, treatsExpensiveAsCellular: true, reason: nil),
        PathCase(name: "offline", path: .offline, treatsExpensiveAsCellular: true, reason: nil),
        PathCase(name: "cellular", path: .cellular, treatsExpensiveAsCellular: false, reason: .cellular),
        PathCase(name: "low data wifi", path: lowDataWifi, treatsExpensiveAsCellular: false, reason: .lowDataMode),
        PathCase(name: "ios hotspot", path: hotspot, treatsExpensiveAsCellular: false, reason: nil),
        PathCase(name: "mac hotspot", path: hotspot, treatsExpensiveAsCellular: true, reason: .expensive),
        PathCase(name: "expensive other", path: expensiveOther, treatsExpensiveAsCellular: false, reason: .expensive),
    ]

    @Test(arguments: pathCases, CellularPolicy.allCases)
    func requestFollowsThePolicyOnThePath(_ testCase: PathCase, policy: CellularPolicy) async throws {
        let recordID = UUID()
        let manager = FakeDownloadManager(result: .success(.started(recordID)))
        let (controller, _, cleanUp) = try makeController(
            path: testCase.path, policy: policy, treatsExpensiveAsCellular: testCase.treatsExpensiveAsCellular,
            manager: manager)
        defer { cleanUp() }

        let outcome = await controller.request(item: Self.item, episodeID: nil, connectionID: Self.connectionID)

        let expected: DownloadRequestOutcome =
            switch (testCase.reason, policy) {
            case (nil, _), (_, .always): .started(.started(recordID))
            case (let reason?, .ask): .needsConfirmation(reason)
            case (let reason?, .never): .denied(reason)
            }
        #expect(outcome == expected)
        let enqueued = if case .started = expected { 1 } else { 0 }
        #expect(await manager.enqueues.count == enqueued)
    }

    @Test func askThenConfirmStartsTheDownload() async throws {
        let recordID = UUID()
        let manager = FakeDownloadManager(result: .success(.started(recordID)))
        let (controller, _, cleanUp) = try makeController(path: .cellular, policy: .ask, manager: manager)
        defer { cleanUp() }

        #expect(
            await controller.request(item: Self.item, episodeID: "ep1", connectionID: Self.connectionID)
                == .needsConfirmation(.cellular))
        #expect(await manager.enqueues.isEmpty)

        let outcome = await controller.confirmMeteredDownload(
            item: Self.item, episodeID: "ep1", connectionID: Self.connectionID)

        #expect(outcome == .started(.started(recordID)))
        #expect(
            await manager.enqueues == [.init(itemID: "li1", episodeID: "ep1", connectionID: Self.connectionID)])
    }

    @Test func confirmIsDeniedOnceThePolicyBecameNever() async throws {
        let manager = FakeDownloadManager()
        let (controller, settings, cleanUp) = try makeController(path: .cellular, policy: .ask, manager: manager)
        defer { cleanUp() }
        #expect(
            await controller.request(item: Self.item, episodeID: nil, connectionID: Self.connectionID)
                == .needsConfirmation(.cellular))

        settings.downloadUsingCellular = .never

        #expect(
            await controller.confirmMeteredDownload(item: Self.item, episodeID: nil, connectionID: Self.connectionID)
                == .denied(.cellular))
        #expect(await manager.enqueues.isEmpty)
    }

    @Test func managerResultsAndErrorsAreReturned() async throws {
        let itemID = UUID()
        let downloaded = FakeDownloadManager(result: .success(.alreadyDownloaded(itemID)))
        let (first, _, cleanUpFirst) = try makeController(manager: downloaded)
        defer { cleanUpFirst() }
        #expect(
            await first.request(item: Self.item, episodeID: nil, connectionID: Self.connectionID)
                == .started(.alreadyDownloaded(itemID)))

        let full = FakeDownloadManager(result: .failure(.insufficientStorage(required: 10, available: 1)))
        let (second, _, cleanUpSecond) = try makeController(manager: full)
        defer { cleanUpSecond() }
        #expect(
            await second.request(item: Self.item, episodeID: nil, connectionID: Self.connectionID)
                == .failed(.insufficientStorage(required: 10, available: 1)))
    }

    // MARK: - Policy changes

    @Test(arguments: [
        (CellularPolicy.always, CellularPolicy.never, true),
        (.ask, .never, true),
        (.never, .always, false),
        (.never, .ask, false),
        (.always, .ask, false),
        (.ask, .always, false),
    ])
    func aStricterPolicyRestartsTransfers(from old: CellularPolicy, to new: CellularPolicy, restarts: Bool)
        async throws
    {
        let manager = FakeDownloadManager()
        let (controller, settings, cleanUp) = try makeController(policy: old, manager: manager)
        defer { cleanUp() }
        let (handled, report) = AsyncStream.makeStream(of: CellularPolicy.self)
        controller.policyHandled = { report.yield($0) }
        var policies = handled.makeAsyncIterator()
        await controller.start()
        #expect(await policies.next() == old)
        // Starting under `never` restarts what may have run before the controller existed.
        #expect(await manager.restarts == (old == .never ? 1 : 0))
        let before = await manager.restarts

        settings.downloadUsingCellular = new

        #expect(await policies.next() == new)
        #expect(await manager.restarts - before == (restarts ? 1 : 0))
    }

    /// The engine created a task under `always` between two writes of `never` that Observation
    /// reports as one `never`: the transfers still restart.
    @Test func coalescedNeverAlwaysNeverStillRestarts() async throws {
        let manager = FakeDownloadManager()
        let (controller, settings, cleanUp) = try makeController(policy: .never, manager: manager)
        defer { cleanUp() }
        let (handled, report) = AsyncStream.makeStream(of: CellularPolicy.self)
        controller.policyHandled = { report.yield($0) }
        var policies = handled.makeAsyncIterator()
        await controller.start()
        #expect(await policies.next() == .never)
        #expect(await manager.restarts == 1)

        settings.downloadUsingCellular = .always
        #expect(controller.networkAccess.current().allowsCellularAccess)
        settings.downloadUsingCellular = .never

        while await policies.next() != .never {}
        #expect(await manager.restarts == 2)
    }

    @Test func aFailedRestartIsRetriedUntilItSucceeds() async throws {
        let manager = FakeDownloadManager()
        await manager.failRestarts(2)
        let (controller, settings, cleanUp) = try makeController(policy: .always, manager: manager)
        defer { cleanUp() }
        let (handled, report) = AsyncStream.makeStream(of: CellularPolicy.self)
        controller.policyHandled = { report.yield($0) }
        var policies = handled.makeAsyncIterator()
        await controller.start()
        #expect(await policies.next() == .always)

        settings.downloadUsingCellular = .never
        #expect(await policies.next() == .never)
        #expect(await manager.restarts == 1)

        // Retried at the next policy change (it fails again), then at the next start.
        settings.downloadUsingCellular = .always
        #expect(await policies.next() == .always)
        settings.downloadUsingCellular = .never
        #expect(await policies.next() == .never)
        #expect(await manager.restarts == 2)
        await controller.start()
        #expect(await manager.restarts == 3)

        // Done: nothing metered was handed out since.
        settings.downloadUsingCellular = .always
        #expect(await policies.next() == .always)
        settings.downloadUsingCellular = .never
        #expect(await policies.next() == .never)
        await controller.start()
        #expect(await manager.restarts == 3)
    }

    @Test func neverBeforeStartRestartsAtStart() async throws {
        let manager = FakeDownloadManager()
        let (controller, settings, cleanUp) = try makeController(policy: .always, manager: manager)
        defer { cleanUp() }
        let (handled, report) = AsyncStream.makeStream(of: CellularPolicy.self)
        controller.policyHandled = { report.yield($0) }
        var policies = handled.makeAsyncIterator()

        settings.downloadUsingCellular = .never
        await controller.start()

        #expect(await policies.next() == .never)
        #expect(await manager.restarts == 1)
    }

    // MARK: - Records and progress

    @Test func recordsAndProgressFollowManagerEvents() async throws {
        let manager = FakeDownloadManager()
        let (controller, _, cleanUp) = try makeController(manager: manager)
        defer { cleanUp() }
        let (handled, report) = AsyncStream.makeStream(of: Void.self)
        controller.eventHandled = { _ in report.yield() }
        var events = handled.makeAsyncIterator()
        await controller.start()
        let now = Date.now
        let older = Self.record("older", createdAt: now.addingTimeInterval(-60))
        let newer = Self.record("newer", createdAt: now)

        for event in [DownloadManagerEvent.recordChanged(newer), .recordChanged(older)] {
            await manager.send(event)
            _ = await events.next()
        }
        #expect(controller.records.map(\.title) == ["older", "newer"])

        var downloading = newer
        downloading.state = .downloading
        await manager.send(.recordChanged(downloading))
        await manager.send(.progress(recordID: newer.id, fraction: 0.5, bytes: 50))
        _ = await events.next()
        _ = await events.next()
        #expect(controller.records.map(\.state) == [.queued, .downloading])
        #expect(controller.progress[newer.id] == .init(fraction: 0.5, bytes: 50))

        await manager.send(
            .completed(recordID: newer.id, itemID: UUID(), key: newer.key))
        await manager.send(.recordRemoved(recordID: older.id))
        // A late progress event of a completed record.
        await manager.send(.progress(recordID: newer.id, fraction: 1, bytes: 100))
        for _ in 0..<3 { _ = await events.next() }
        #expect(controller.records.isEmpty)
        #expect(controller.progress.isEmpty)
    }

    /// A record that only fetches a podcast's cover again (#326).
    private static func coverOnlyRecord(createdAt: Date) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connectionID, libraryItemId: "podcast"), mediaType: .podcast,
            title: "Podcast", relativeDirectory: "podcast", createdAt: createdAt,
            media: LocalMediaSnapshot(metadata: .init(title: "Podcast")),
            parts: [
                DownloadPartDTO(
                    kind: .cover, serverPath: "/api/items/podcast/cover", filename: "cover.jpg",
                    mimeType: "image/jpeg", expectedBytes: 0, bytesWritten: 0,
                    destinationRelativePath: "podcast/cover.jpg", state: .queued)
            ])
    }

    @Test func coverOnlyRecordsAreNotListed() async throws {
        let manager = FakeDownloadManager()
        let now = Date.now
        let stored = Self.coverOnlyRecord(createdAt: now.addingTimeInterval(-120))
        let (controller, _, cleanUp) = try makeController(manager: manager) { [stored] }
        defer { cleanUp() }
        let (handled, report) = AsyncStream.makeStream(of: Void.self)
        controller.eventHandled = { _ in report.yield() }
        var events = handled.makeAsyncIterator()
        await controller.start()
        #expect(controller.records.isEmpty)

        let refetch = Self.coverOnlyRecord(createdAt: now)
        let book = Self.record("book", createdAt: now)
        var downloading = refetch
        downloading.state = .downloading
        let sequence: [DownloadManagerEvent] = [
            .recordChanged(refetch), .recordChanged(book), .recordChanged(downloading),
            .progress(recordID: refetch.id, fraction: 0.5, bytes: 50),
        ]
        for event in sequence {
            await manager.send(event)
            _ = await events.next()
        }
        #expect(controller.records.map(\.title) == ["book"])
        #expect(controller.progress.isEmpty)

        // The manager reports a refetch that completed, was discarded by the engine
        // (`DownloadUpdate.recordDiscarded`) or was cancelled as `recordRemoved`.
        for id in [refetch.id, stored.id] {
            await manager.send(.recordRemoved(recordID: id))
            _ = await events.next()
        }
        #expect(controller.records.map(\.title) == ["book"])
        #expect(controller.progress.isEmpty)
    }

    @Test func storedRecordsDoNotOverrideEventsDuringTheirRead() async throws {
        let manager = FakeDownloadManager()
        let now = Date.now
        let removed = Self.record("removed", createdAt: now.addingTimeInterval(-120))
        let changed = Self.record("changed", createdAt: now.addingTimeInterval(-60))
        let kept = Self.record("kept", createdAt: now)
        let downloading = Self.record("changed", createdAt: changed.createdAt, state: .downloading, id: changed.id)
        let (handled, signal) = AsyncStream.makeStream(of: Void.self)
        let (controller, _, cleanUp) = try makeController(manager: manager) {
            // Events that arrive while the store is read win over what it read.
            await manager.send(.recordRemoved(recordID: removed.id))
            await manager.send(.recordChanged(downloading))
            var iterator = handled.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
            return [removed, changed, kept]
        }
        defer { cleanUp() }
        controller.eventHandled = { _ in signal.yield() }

        await controller.start()

        #expect(controller.records.map(\.title) == ["changed", "kept"])
        #expect(controller.records.map(\.state) == [.downloading, .queued])
    }

    @Test func aSecondStartWaitsForTheStoredRecords() async throws {
        let kept = Self.record("kept", createdAt: .now)
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let (controller, _, cleanUp) = try makeController {
            for await _ in gate { break }
            return [kept]
        }
        defer { cleanUp() }

        let first = Task { await controller.start() }
        let second = Task {
            await controller.start()
            return controller.records.map(\.title)
        }
        // Main-actor jobs run in order: both starts are under way before the read is let through.
        Task { open.yield() }

        #expect(await second.value == ["kept"])
        await first.value
    }

    @Test func aFailedStoredReadIsRetriedOnce() async throws {
        let kept = Self.record("kept", createdAt: .now)
        let reads = Locked(0)
        let (controller, _, cleanUp) = try makeController {
            reads.value += 1
            if reads.value == 1 { throw CocoaError(.fileReadUnknown) }
            return [kept]
        }
        defer { cleanUp() }

        await controller.start()

        #expect(reads.value == 2)
        #expect(controller.records.map(\.title) == ["kept"])
        #expect(controller.loadError == nil)
    }

    @Test func aStoredReadThatKeepsFailingIsReported() async throws {
        let reads = Locked(0)
        let (controller, _, cleanUp) = try makeController {
            reads.value += 1
            throw CocoaError(.fileReadUnknown)
        }
        defer { cleanUp() }

        await controller.start()

        #expect(reads.value == 2)
        #expect(controller.records.isEmpty)
        #expect((controller.loadError as? CocoaError)?.code == .fileReadUnknown)
    }
}
