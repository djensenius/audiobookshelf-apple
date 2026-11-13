import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

/// An engine whose guarded resume waits until the test releases it, then finds a quiesce and
/// keeps the record paused; everything else does nothing.
private final class HeldResumeEngine: DownloadEngineControlling {
    private let quiesced = Mutex(false)
    private let entered: AsyncStream<Void>.Continuation
    /// Yields once the guarded resume is waiting.
    let resumeEntered: AsyncStream<Void>
    private let release: AsyncStream<Void>
    /// Lets the guarded resume finish.
    let releaseResume: AsyncStream<Void>.Continuation

    init() {
        (resumeEntered, entered) = AsyncStream.makeStream(of: Void.self)
        (release, releaseResume) = AsyncStream.makeStream(of: Void.self)
    }

    var updates: AsyncStream<DownloadUpdate> { AsyncStream { _ in } }
    var progress: AsyncStream<DownloadProgress> { AsyncStream { _ in } }
    func start(partIDs: [UUID]) async {}
    func stop(partIDs: [UUID], keepingResumeData: Bool) async {}
    func attachSurvivingTransfers() async -> Bool { false }
    func pause(recordID: UUID) async throws -> Bool { false }
    func resume(recordID: UUID) async throws -> Bool { false }
    func quiesceGeneration() async -> Int { 0 }
    func hasQuiesced(connectionID: UUID, since generation: Int) async -> Bool { quiesced.withLock { $0 } }

    func resume(recordID: UUID, unlessQuiescedSince generation: Int) async throws -> Bool {
        entered.yield()
        for await _ in release { break }
        // The account signed out while the resume waited.
        quiesced.withLock { $0 = true }
        return false
    }
}

private struct UnlimitedCapacity: StorageCapacityProviding {
    func availableCapacity() async throws -> Int64 { .max }
}

/// A ``DownloadsController`` over a real ``DownloadManager``: a guarded request the manager
/// discards must not stay listed by a stored-record snapshot read before the discard.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DownloadsControllerDiscardTests {
    private static func book(_ id: String) -> LibraryItem {
        let path = "/audiobooks/\(id)/01.mp3"
        let metadata = FileMetadata(filename: "01.mp3", ext: ".mp3", path: path, size: 1_000)
        let book = Book(
            id: "book-\(id)", libraryItemId: id, metadata: BookMetadata(title: id),
            audioFiles: [AudioFile(index: 1, ino: "1", metadata: metadata, duration: 60, mimeType: "audio/mpeg")],
            tracks: [
                AudioTrack(
                    index: 1, startOffset: 0, duration: 60, contentUrl: "/api/items/\(id)/file/1",
                    mimeType: "audio/mpeg", metadata: metadata)
            ])
        return LibraryItem(id: id, libraryId: "lib", mediaType: .book, media: .book(book))
    }

    @Test func aDiscardedGuardedRequestLeavesNoRowFromAnEarlierSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "discard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try DataStack(location: .inMemory).container
        let connectionID = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: ServerAddress("https://abs.example.com")!, userId: "usr_1", username: "reader",
            authMethod: .local, serverVersion: "2.26.0"
        ).id
        let store = DownloadStore(modelContainer: container)
        let engine = HeldResumeEngine()
        let manager = DownloadManager(
            store: store, localItems: LocalItemStore(modelContainer: container), engine: engine,
            locations: DownloadLocations(root: root), capacity: UnlimitedCapacity())

        let suiteName = "ABSAppModelTests.Downloads.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (snapshotRead, didRead) = AsyncStream.makeStream(of: [DownloadRecordDTO].self)
        let (snapshotGate, releaseSnapshot) = AsyncStream.makeStream(of: Void.self)
        let controller = DownloadsController(
            manager: manager, monitor: NetworkMonitor(), settings: AppSettings(defaults: defaults),
            networkAccess: DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: false),
            storedRecords: {
                // The startup snapshot, read while the guarded resume holds the new paused record.
                let stored = try await store.allRecords()
                didRead.yield(stored)
                for await _ in snapshotGate { break }
                return stored
            },
            sessions: { _ in nil })
        let (handled, handledEvent) = AsyncStream.makeStream(of: DownloadManagerEvent.self)
        controller.eventHandled = { handledEvent.yield($0) }

        // A guarded request: its record is saved paused, and the resume waits.
        let discarded = Task {
            try await manager.enqueue(
                item: Self.book("discarded"), episodeID: nil, connectionID: connectionID,
                unlessQuiescedSince: 0)
        }
        var entered = engine.resumeEntered.makeAsyncIterator()
        _ = await entered.next()

        // The controller starts and reads the stored records, which still list it.
        let start = Task { await controller.start() }
        var reads = snapshotRead.makeAsyncIterator()
        let snapshot = try #require(await reads.next())
        #expect(snapshot.map(\.key.libraryItemId) == ["discarded"])

        // The resume finds the quiesce: the manager deletes the record and fails the request.
        engine.releaseResume.yield()
        let result = await discarded.result
        #expect(throws: DownloadManagerError.downloadsStopped(connectionID)) { try result.get() }
        #expect(try await store.allRecords().isEmpty)

        // A later download's event: the controller handled everything reported before it.
        let kept = try await manager.enqueue(
            item: Self.book("kept"), episodeID: nil, connectionID: connectionID, unlessQuiescedSince: nil)
        guard case .started(let keptID) = kept else {
            Issue.record("Not started: \(kept)")
            return
        }
        for await event in handled {
            if case .recordChanged(let record) = event, record.id == keptID { break }
        }

        releaseSnapshot.yield()
        await start.value

        #expect(controller.records.map(\.id) == [keptID])
    }
}
