import ABSCore
import ABSData
import Foundation
import SwiftData
import Synchronization

@testable import ABSDownloads

/// Records the manager's calls; the test drives its streams. Like ``DownloadEngine``, a resume
/// queues the record in the store, and nothing ever downloads. A complete record marked
/// ``settle(_:)`` is being finalised, which a stop leaves alone: ``finishSettling()`` then
/// finalises it late, as the engine does, from the record as it was read then, even if it was
/// deleted since: as a local item, deleting it by ID. Transfers that survived a relaunch
/// (``survive(_:)``) are adopted when the session is created, as by the engine's activation,
/// unless their record is paused; a pause stops an adopted one.
actor FakeDownloadEngine: DownloadEngineControlling {
    struct ResumeFailure: Error {}

    struct Stop: Equatable {
        var partIDs: [UUID]
        var keepingResumeData: Bool
    }

    enum Call: Equatable {
        case pause(UUID)
        case resume(UUID)
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
    private let localItems: LocalItemStore
    private(set) var started: [[UUID]] = []
    private(set) var stopped: [Stop] = []
    private(set) var resumed: [UUID] = []
    /// Pauses and resumes, in call order.
    private(set) var calls: [Call] = []
    /// The records being finalised, as they were read when it began.
    private var settling: [DownloadRecordDTO] = []
    /// Whether ``resume(recordID:)`` deletes the record first, as a finalise running meanwhile does.
    private var finaliseBeforeResume = false
    private var failingResumes = 0
    /// Whether a failing resume queues the record first, as the engine's guarded resume does
    /// when it then can't pause it again.
    private var failingResumesQueue = false
    private var hasSession = false
    private var sessionAvailable = true
    /// Records whose surviving transfer isn't adopted yet.
    private var survivors: Set<UUID> = []
    /// Records whose surviving transfer was adopted and still runs, with the network access it
    /// began under.
    private(set) var runningSurvivors: Set<UUID> = []
    private(set) var attaches = 0

    init(store: DownloadStore, localItems: LocalItemStore) {
        self.store = store
        self.localItems = localItems
        (updateStream, updateContinuation) = AsyncStream.makeStream()
        (progress, progressContinuation) = AsyncStream.makeStream()
    }

    func start(partIDs: [UUID]) {
        started.append(partIDs)
    }

    func stop(partIDs: [UUID], keepingResumeData: Bool) async {
        stopped.append(Stop(partIDs: partIDs, keepingResumeData: keepingResumeData))
        await afterStop?(partIDs)
    }

    /// Runs after each stop is recorded, before it returns, as a launch racing it can.
    private var afterStop: (@Sendable ([UUID]) async -> Void)?

    func onStop(_ body: @escaping @Sendable ([UUID]) async -> Void) {
        afterStop = body
    }

    /// Marks a record whose parts have all completed as being finalised, reading it now.
    ///
    /// - Throws: `incompleteDownload` when it doesn't exist or isn't complete.
    func settle(_ recordID: UUID) async throws {
        guard let record = try await store.record(id: recordID), record.isComplete else {
            throw LocalItemStore.StoreError.incompleteDownload
        }
        settling.append(record)
    }

    /// Ends the finalise of every settling record, in the order they began: makes the record
    /// read then a local item, deletes it by ID (if it is still there) and reports it complete.
    func finishSettling() async throws {
        for record in settling {
            let item = try await localItems.upsertFromDownload(record)
            try await store.deleteRecord(record.id)
            updateContinuation.yield(.recordComplete(recordID: record.id, itemID: item.id))
        }
        settling = []
    }

    /// Makes the next `count` resumes throw before they change anything.
    func failNextResumes(_ count: Int, queueingFirst: Bool = false) {
        failingResumes = count
        failingResumesQueue = queueingFirst
    }

    func finaliseOnResume() {
        finaliseBeforeResume = true
    }

    /// A transfer of `recordID` survived a relaunch; the session isn't created yet.
    func survive(_ recordID: UUID) {
        survivors.insert(recordID)
    }

    /// Makes every session creation fail, as when another process holds it.
    func makeSessionUnavailable() {
        sessionAvailable = false
    }

    func attachSurvivingTransfers() async -> Bool {
        attaches += 1
        return await ensureSession()
    }

    private func ensureSession() async -> Bool {
        guard sessionAvailable else { return false }
        guard !hasSession else { return true }
        hasSession = true
        for recordID in survivors where (try? await store.record(id: recordID))?.state != .paused {
            runningSurvivors.insert(recordID)
        }
        survivors = []
        return true
    }

    func pause(recordID: UUID) async throws -> Bool {
        calls.append(.pause(recordID))
        runningSurvivors.remove(recordID)
        return try await store.setState(.paused, forRecord: recordID)
    }

    func resume(recordID: UUID) async throws -> Bool {
        calls.append(.resume(recordID))
        if failingResumes > 0 {
            failingResumes -= 1
            if failingResumesQueue { _ = try await store.setState(.queued, forRecord: recordID) }
            throw ResumeFailure()
        }
        resumed.append(recordID)
        if finaliseBeforeResume { try await store.deleteRecord(recordID) }
        let queued = try await store.setState(.queued, forRecord: recordID)
        // Like the engine's start, which creates the session first.
        _ = await ensureSession()
        return queued
    }

    /// The quiesce generations ``hasQuiesced(connectionID:since:)`` reports as quiesced since.
    private var quiescedSince: Set<Int> = []

    /// Makes ``hasQuiesced(connectionID:since:)`` and ``resume(recordID:unlessQuiescedSince:)``
    /// treat every connection as quiesced since `generation`.
    func quiesce(since generation: Int) {
        quiescedSince.insert(generation)
    }

    /// The generations a quiesce begins since as soon as ``hasQuiesced(connectionID:since:)``
    /// is first asked about them (answering `false`), as one beginning just after that check.
    private var quiescingAfterCheck: Set<Int> = []

    func quiesce(afterNextCheckSince generation: Int) {
        quiescingAfterCheck.insert(generation)
    }

    func quiesceGeneration() -> Int { 0 }

    func hasQuiesced(connectionID: UUID, since generation: Int) -> Bool {
        if quiescingAfterCheck.remove(generation) != nil {
            quiescedSince.insert(generation)
            return false
        }
        return quiescedSince.contains(generation)
    }

    /// Runs as each guarded resume begins, before it changes anything.
    private var beforeGuardedResume: (@Sendable (UUID) async -> Void)?

    func onGuardedResume(_ body: @escaping @Sendable (UUID) async -> Void) {
        beforeGuardedResume = body
    }

    /// ``resume(recordID:)``, unless quiesced since `generation` (and not made to throw): then it
    /// changes nothing, as the engine's puts the record back to `paused`.
    func resume(recordID: UUID, unlessQuiescedSince generation: Int) async throws -> Bool {
        await beforeGuardedResume?(recordID)
        guard !quiescedSince.contains(generation) || failingResumes > 0 else {
            calls.append(.resume(recordID))
            return false
        }
        return try await resume(recordID: recordID)
    }
}

/// Records the manager's progress links and detaches; `before` runs first, and with `failing`,
/// each then throws.
final class FakeProgressLinker: LocalProgressLinking {
    enum Call: Equatable {
        case link(MediaKey, UUID)
        case detachItem(UUID)
        case detachKey(MediaKey)
    }

    struct Failure: Error {}

    private let log = Mutex<[Call]>([])
    private let failing: Bool
    private let before: (@Sendable (Call) async -> Void)?
    var calls: [Call] { log.withLock { $0 } }

    init(failing: Bool = false, before: (@Sendable (Call) async -> Void)? = nil) {
        self.failing = failing
        self.before = before
    }

    func link(key: MediaKey, itemID: UUID) async throws {
        try await record(.link(key, itemID))
    }

    func detach(itemID: UUID) async throws {
        try await record(.detachItem(itemID))
    }

    func detach(key: MediaKey) async throws {
        try await record(.detachKey(key))
    }

    private func record(_ call: Call) async throws {
        await before?(call)
        log.withLock { $0.append(call) }
        if failing { throw Failure() }
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
        /// The first refresh after ``holdRecordRead()`` read this record; it waits until
        /// ``releaseRecordRead()``.
        case recordRead(UUID)
        /// The first clean-up after ``holdUsedPaths()`` read one of the two sources of the paths
        /// still in use; it waits until ``releaseUsedPaths()`` before reading the other.
        case usedPathsReading
        /// The first cover hand-off after ``holdCoverHandOff()`` read the local item; it waits
        /// until ``releaseCoverHandOff()`` before reading the records.
        case coverHandOffReading
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "manager-\(UUID().uuidString)")
    let store: DownloadStore
    let localItems: LocalItemStore
    let connections: ServerConnectionStore
    let container: ModelContainer
    let connectionID: UUID
    let engine: FakeDownloadEngine
    let capacity: FakeCapacity
    let clock = FiringClock()
    private let startGate = Mutex<StubGate?>(nil)
    private let heldStart = Mutex<StubGate?>(nil)
    private let readGate = Mutex<StubGate?>(nil)
    private let heldRead = Mutex<StubGate?>(nil)
    private let pathsGate = Mutex<StubGate?>(nil)
    private let heldPaths = Mutex<StubGate?>(nil)
    private let handOffGate = Mutex<StubGate?>(nil)
    private let heldHandOff = Mutex<StubGate?>(nil)
    let checkpoints: AsyncStream<Checkpoint>
    private let checkpoint: AsyncStream<Checkpoint>.Continuation

    init() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Checkpoint.self)
        checkpoints = stream
        checkpoint = continuation
        capacity = FakeCapacity { continuation.yield(.capacity) }
        container = try DataStack(location: .inMemory).container
        connections = ServerConnectionStore(modelContainer: container)
        connectionID = try await connections.upsertLogin(
            address: ServerAddress("https://abs.example.com")!, userId: "usr_1", username: "reader",
            authMethod: .local, serverVersion: "2.26.0"
        ).id
        store = DownloadStore(modelContainer: container)
        localItems = LocalItemStore(modelContainer: container)
        engine = FakeDownloadEngine(store: store, localItems: localItems)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var locations: DownloadLocations { DownloadLocations(root: root) }

    func makeManager(progressLinking: (any LocalProgressLinking)? = nil) -> DownloadManager {
        DownloadManager(
            store: store, localItems: localItems, engine: engine, locations: locations, capacity: capacity,
            clock: clock, progressLinking: progressLinking,
            enqueueWaiting: { [checkpoint] in checkpoint.yield(.waiting($0)) },
            progressHandled: { [checkpoint] in checkpoint.yield(.progressHandled($0)) },
            subscriberRemoved: { [checkpoint] in checkpoint.yield(.subscriberRemoved) },
            trackingRecords: { [checkpoint, self] in
                checkpoint.yield(.trackingRecords)
                if let gate = takeStartGate() {
                    await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
                }
            },
            recordRead: { [checkpoint, self] recordID in
                guard let gate = takeReadGate() else { return }
                checkpoint.yield(.recordRead(recordID))
                await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
            },
            usedPathsReading: { [checkpoint, self] in
                guard let gate = takePathsGate() else { return }
                checkpoint.yield(.usedPathsReading)
                await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
            },
            coverHandOffReading: { [checkpoint, self] in
                guard
                    let gate = handOffGate.withLock({ gate in
                        defer { gate = nil }; return gate
                    })
                else { return }
                checkpoint.yield(.coverHandOffReading)
                await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
            })
    }

    /// Holds the next cover hand-off between its reads of the local item and the records, until
    /// ``releaseCoverHandOff()``.
    func holdCoverHandOff() {
        let gate = StubGate()
        handOffGate.withLock { $0 = gate }
        heldHandOff.withLock { $0 = gate }
    }

    func releaseCoverHandOff() {
        heldHandOff.withLock { $0 }?.open()
    }

    /// Holds the next clean-up between its reads of the paths still in use, until
    /// ``releaseUsedPaths()``.
    func holdUsedPaths() {
        let gate = StubGate()
        pathsGate.withLock { $0 = gate }
        heldPaths.withLock { $0 = gate }
    }

    private func takePathsGate() -> StubGate? {
        pathsGate.withLock { gate in
            defer { gate = nil }
            return gate
        }
    }

    func releaseUsedPaths() {
        heldPaths.withLock { $0 }?.open()
    }

    /// Holds the next refresh after it read its record, until ``releaseRecordRead()``.
    func holdRecordRead() {
        let gate = StubGate()
        readGate.withLock { $0 = gate }
        heldRead.withLock { $0 = gate }
    }

    private func takeReadGate() -> StubGate? {
        readGate.withLock { gate in
            defer { gate = nil }
            return gate
        }
    }

    func releaseRecordRead() {
        heldRead.withLock { $0 }?.open()
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
    func storeDownloaded(
        _ item: LibraryItem, episodeID: String? = nil, connectionID: UUID? = nil
    ) async throws -> LocalLibraryItemDTO {
        var record = try DownloadPlanner(locations: locations).plan(
            item: item, episodeID: episodeID, connectionID: connectionID ?? self.connectionID, existingCoverPath: nil)
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
