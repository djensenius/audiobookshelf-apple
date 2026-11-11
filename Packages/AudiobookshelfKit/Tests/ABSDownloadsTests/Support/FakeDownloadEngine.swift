import ABSCore
import ABSData
import Foundation
import Synchronization

@testable import ABSDownloads

/// Records the manager's calls; the test drives its streams. Like ``DownloadEngine``, a resume
/// queues the record in the store, and nothing ever downloads. A record marked ``settle(_:)``
/// has a part settling, which a stop leaves alone: ``finishSettling()`` then finalises it late,
/// deleting it by ID, as the engine does.
actor FakeDownloadEngine: DownloadEngineControlling {
    struct Stop: Equatable {
        var partIDs: [UUID]
        var keepingResumeData: Bool
    }

    nonisolated var updates: AsyncStream<DownloadUpdate> {
        updateReads.withLock { $0 += 1 }
        return updateStream
    }
    /// How many times ``updates`` was read.
    nonisolated var updatesReadCount: Int { updateReads.withLock { $0 } }
    private nonisolated let updateStream: AsyncStream<DownloadUpdate>
    private nonisolated let updateReads = Mutex(0)
    nonisolated let progress: AsyncStream<DownloadProgress>
    nonisolated let updateContinuation: AsyncStream<DownloadUpdate>.Continuation
    nonisolated let progressContinuation: AsyncStream<DownloadProgress>.Continuation
    private let store: DownloadStore
    private(set) var started: [[UUID]] = []
    private(set) var stopped: [Stop] = []
    private(set) var resumed: [UUID] = []
    private var settling: Set<UUID> = []
    /// Whether ``resume(recordID:)`` deletes the record first, as a finalise running meanwhile does.
    private var finaliseBeforeResume = false

    init(store: DownloadStore) {
        self.store = store
        (updateStream, updateContinuation) = AsyncStream.makeStream()
        (progress, progressContinuation) = AsyncStream.makeStream()
    }

    func start(partIDs: [UUID]) {
        started.append(partIDs)
    }

    func stop(partIDs: [UUID], keepingResumeData: Bool) async {
        stopped.append(Stop(partIDs: partIDs, keepingResumeData: keepingResumeData))
    }

    /// Marks a record as being finalised.
    func settle(_ recordID: UUID) {
        settling.insert(recordID)
    }

    /// Ends the finalise of every settling record: deletes it by ID and reports it complete.
    func finishSettling() async throws {
        for recordID in settling {
            try await store.deleteRecord(recordID)
            updateContinuation.yield(.recordComplete(recordID: recordID, itemID: UUID()))
        }
        settling = []
    }

    func finaliseOnResume() {
        finaliseBeforeResume = true
    }

    func pause(recordID: UUID) async throws -> Bool {
        try await store.setState(.paused, forRecord: recordID)
    }

    func resume(recordID: UUID) async throws -> Bool {
        resumed.append(recordID)
        if finaliseBeforeResume { try await store.deleteRecord(recordID) }
        return try await store.setState(.queued, forRecord: recordID)
    }
}

/// A capacity that can hold every caller until ``release()``, and reports each call.
final class FakeCapacity: StorageCapacityProviding {
    struct Unreadable: Error {}

    /// `nil` makes reads throw.
    private let available: Mutex<Int64?>
    private let gate = Mutex<StubGate?>(nil)
    private let arrived: (@Sendable () -> Void)?

    init(available: Int64 = .max, arrived: (@Sendable () -> Void)? = nil) {
        self.available = Mutex(Optional(available))
        self.arrived = arrived
    }

    func set(_ bytes: Int64?) {
        available.withLock { $0 = bytes }
    }

    /// Holds every later call until ``release()``.
    func hold() {
        gate.withLock { $0 = StubGate() }
    }

    func release() {
        gate.withLock { $0 }?.open()
    }

    func availableCapacity() async throws -> Int64 {
        arrived?()
        if let gate = gate.withLock({ $0 }) {
            await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
        }
        guard let bytes = available.withLock({ $0 }) else { throw Unreadable() }
        return bytes
    }
}

/// A ``DownloadManager`` over a ``FakeDownloadEngine``, an in-memory store with one connection,
/// and a temporary download root.
final class ManagerFixture: Sendable {
    /// Points the manager reports reaching, in order.
    enum Checkpoint: Equatable {
        /// An enqueue is waiting for another enqueue of the same item.
        case waiting(MediaKey)
        /// An enqueue is reading the capacity.
        case capacity
        /// The manager handled this progress event.
        case progressHandled(DownloadProgress)
        /// An ``DownloadManager/events()`` subscriber was removed.
        case subscriberRemoved
        /// ``DownloadManager/start()`` is about to track the stored records; the first call
        /// after ``holdStart()`` waits there until ``releaseStart()``.
        case trackingRecords
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "manager-\(UUID().uuidString)")
    let store: DownloadStore
    let localItems: LocalItemStore
    let connectionID: UUID
    let engine: FakeDownloadEngine
    let capacity: FakeCapacity
    let clock = FiringClock()
    private let startGate = Mutex<StubGate?>(nil)
    private let heldStart = Mutex<StubGate?>(nil)
    let checkpoints: AsyncStream<Checkpoint>
    private let checkpoint: AsyncStream<Checkpoint>.Continuation

    init() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Checkpoint.self)
        checkpoints = stream
        checkpoint = continuation
        capacity = FakeCapacity { continuation.yield(.capacity) }
        let container = try DataStack(location: .inMemory).container
        connectionID = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: ServerAddress("https://abs.example.com")!, userId: "usr_1", username: "reader",
            authMethod: .local, serverVersion: "2.26.0"
        ).id
        store = DownloadStore(modelContainer: container)
        localItems = LocalItemStore(modelContainer: container)
        engine = FakeDownloadEngine(store: store)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var locations: DownloadLocations { DownloadLocations(root: root) }

    func makeManager() -> DownloadManager {
        DownloadManager(
            store: store, localItems: localItems, engine: engine, locations: locations, capacity: capacity,
            clock: clock, enqueueWaiting: { [checkpoint] in checkpoint.yield(.waiting($0)) },
            progressHandled: { [checkpoint] in checkpoint.yield(.progressHandled($0)) },
            subscriberRemoved: { [checkpoint] in checkpoint.yield(.subscriberRemoved) },
            trackingRecords: { [checkpoint, self] in
                checkpoint.yield(.trackingRecords)
                if let gate = takeStartGate() {
                    await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
                }
            })
    }

    /// Holds the next ``DownloadManager/start()`` before it tracks the stored records, until
    /// ``releaseStart()``.
    func holdStart() {
        let gate = StubGate()
        startGate.withLock { $0 = gate }
        heldStart.withLock { $0 = gate }
    }

    /// The gate the next start waits at; only the first call after ``holdStart()`` gets it.
    private func takeStartGate() -> StubGate? {
        startGate.withLock { gate in
            defer { gate = nil }
            return gate
        }
    }

    func releaseStart() {
        heldStart.withLock { $0 }?.open()
    }

    /// The next checkpoint; the suite's time limit bounds the wait.
    func nextCheckpoint() async -> Checkpoint? {
        await checkpoints.first { _ in true }
    }

    func key(_ item: LibraryItem, episodeID: String? = nil) -> MediaKey {
        MediaKey(serverConnectionID: connectionID, libraryItemId: item.id, episodeId: episodeID)
    }

    /// Stores `item` (or its episode) as downloaded, as the engine does when a record completes.
    @discardableResult
    func storeDownloaded(_ item: LibraryItem, episodeID: String? = nil) async throws -> LocalLibraryItemDTO {
        var record = try DownloadPlanner(locations: locations).plan(
            item: item, episodeID: episodeID, connectionID: connectionID, existingCoverPath: nil)
        for index in record.parts.indices {
            record.parts[index].state = .completed
            record.parts[index].bytesWritten = record.parts[index].expectedBytes
        }
        return try await localItems.upsertFromDownload(record)
    }
}

extension AsyncStream<DownloadManagerEvent> {
    /// The next event matching `predicate`; the suite's time limit bounds the wait.
    func next(where predicate: (DownloadManagerEvent) -> Bool) async -> DownloadManagerEvent? {
        for await event in self where predicate(event) {
            return event
        }
        return nil
    }

    func nextProgress() async -> DownloadManagerEvent? {
        await next {
            if case .progress = $0 { true } else { false }
        }
    }
}
