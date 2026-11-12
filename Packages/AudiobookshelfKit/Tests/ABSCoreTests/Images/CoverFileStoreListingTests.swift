import Foundation
import Synchronization
import Testing

@testable import ABSCore

/// `CoverFileStore` passes, which list the folder off the actor while writes go on.
/// Serialized: a blocked listing holds a thread of the shared pool, and several at once could
/// starve the tasks that release them.
@Suite(.serialized, .timeLimit(.minutes(1))) struct CoverFileStoreListingTests {
    private let directory: TemporaryDirectory
    private let serverID = UUID()
    private let otherServerID = UUID()
    private let clock = Clock()
    private var images: URL { directory.url.appending(path: "Images") }

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// A 16 KiB file: whole APFS blocks, so its allocated size is exact.
    private func temporaryFile() throws -> URL {
        let url = directory.url.appending(path: UUID().uuidString)
        try Data(repeating: 7, count: 16_384).write(to: url)
        return url
    }

    private func key(_ id: String, server: UUID? = nil) -> ImageKey {
        ImageKey(serverID: server ?? serverID, kind: .itemCover, entityID: id, updatedAt: 1)
    }

    /// Writes covers for `ids` a minute apart, oldest first, with another store, as an earlier
    /// launch would have.
    private func seed(_ ids: [String], server: UUID? = nil) async throws {
        let store = CoverFileStore(directory: images, limit: 1 << 30) { clock.now() }
        for id in ids {
            clock.advance(60)
            _ = try await store.insert(
                moving: temporaryFile(), for: key(id, server: server), pathExtension: "webp", generation: 0)
        }
    }

    private func makeStore(limit: Int = 1 << 30, gate: ListingGate) -> CoverFileStore {
        CoverFileStore(directory: images, limit: limit, now: { clock.now() }, listingHook: gate.block)
    }

    /// A store that has finished its first scan and blocks its next listing.
    private func scannedStore(limit: Int = 1 << 30, gate: ListingGate) async -> CoverFileStore {
        let store = makeStore(limit: limit, gate: gate)
        gate.release()
        _ = await store.size
        gate.blocksAgain()
        return store
    }

    private func files(server: UUID? = nil) -> [String] {
        let folder = images.appending(path: (server ?? serverID).uuidString)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func listingTheFolderDoesNotBlockTheActor() async throws {
        try await seed(["a"])
        let gate = ListingGate()
        let store = makeStore(gate: gate)

        let scan = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(1))
        // Blocks the listing's thread: if the listing ran on the actor, this call would wait.
        let answered = Mutex(false)
        let call = Task {
            _ = await store.generation(for: serverID)
            answered.withLock { $0 = true }
        }
        let wasAnswered = await poll { answered.withLock { $0 } }
        gate.release()
        await scan.value
        await call.value
        #expect(wasAnswered)
        #expect(await store.size == 16_384)
    }

    @Test func fileInsertedWhileTheFolderIsListedIsCounted() async throws {
        try await seed(["a"])
        let gate = ListingGate()
        let store = await scannedStore(gate: gate)

        let scan = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(2))
        try await completes(gate) {
            _ = try await store.insert(moving: temporaryFile(), for: key("b"), pathExtension: "webp", generation: 0)
        }
        await scan.value
        #expect(await store.size == 32_768)
    }

    @Test func firstScanIsSharedByConcurrentCallers() async throws {
        try await seed(["a"])
        let gate = ListingGate()
        let store = makeStore(gate: gate)

        let size = Task { await store.size }
        #expect(await gate.waitForEntries(1))
        let lookup = Task { await store.lookup(key("a")) != nil }
        let pass = Task { await store.fullPass() }
        // A second listing would start within this window.
        try await Task.sleep(for: .milliseconds(200))
        gate.release()
        #expect(await size.value == 16_384)
        #expect(await lookup.value)
        await pass.value
        #expect(gate.entries == 1)
        #expect(await store.listingCount == 1)
    }

    @Test func concurrentPassesEvictOnce() async throws {
        try await seed(["a", "b", "c", "d"])
        let gate = ListingGate()
        // 4 × 16 KiB is over the cap; evicting the two oldest brings it under 90 %.
        let store = makeStore(limit: 50_000, gate: gate)

        let first = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(1))
        let second = Task { await store.fullPass() }
        try await Task.sleep(for: .milliseconds(200))
        gate.release()
        await first.value
        await second.value
        #expect(files() == [key("c").fileStem + ".webp", key("d").fileStem + ".webp"])
        #expect(await store.size == 32_768)
        #expect(await store.listingCount == 1)
    }

    @Test func removingAServerDuringTheFirstScanCountsItsFilesOnce() async throws {
        try await seed(["a"])
        try await seed(["b"], server: otherServerID)
        let gate = ListingGate()
        let store = makeStore(gate: gate)

        let size = Task { await store.size }
        #expect(await gate.waitForEntries(1))
        try await completes(gate) { await store.removeServer(serverID) }
        #expect(await size.value == 16_384)
        #expect(files().isEmpty)
        #expect(files(server: otherServerID).count == 1)
    }

    @Test func removingAServerDuringAFullPassDropsItsFiles() async throws {
        try await seed(["a"])
        try await seed(["b"], server: otherServerID)
        let gate = ListingGate()
        let store = await scannedStore(gate: gate)
        #expect(await store.size == 32_768)

        let pass = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(2))
        try await completes(gate) { await store.removeServer(serverID) }
        await pass.value
        #expect(await store.size == 16_384)
    }

    @Test func fileDiscardedWhileTheFolderIsListedIsNotCounted() async throws {
        let gate = ListingGate()
        let store = await scannedStore(gate: gate)
        // Unleased once this returns, so the discard deletes the file at once.
        let (url, version) = try await { () async throws -> (URL, Int) in
            let written = try await store.insert(
                moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
            return (written.url, written.version)
        }()

        let pass = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(2))
        try await completes(gate) { await store.discard(url, version: version) }
        await pass.value
        #expect(await store.size == 0)
        #expect(files().isEmpty)
    }

    @Test func copyRetiredByAReplacementWhileTheFolderIsListedIsNotCounted() async throws {
        try await seed(["a"])
        let gate = ListingGate()
        let store = await scannedStore(gate: gate)

        let pass = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(2))
        try await completes(gate) {
            _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)
        }
        await pass.value
        #expect(await store.size == 16_384)
        #expect(files() == [key("a").fileStem + ".jpg"])
    }

    @Test func coverLookedUpWhileTheFolderIsListedIsNotEvictedAsOld() async throws {
        try await seed(["a", "b", "c"])
        let gate = ListingGate()
        // 3 × 16 KiB is under the cap; a fourth cover takes it over.
        let store = await scannedStore(limit: 50_000, gate: gate)
        clock.advance(2 * 86_400)

        let pass = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(2))
        try await completes(gate) {
            // A day old, so the hit refreshes its date: it's now among the newest.
            _ = await store.lookup(key("a"))
            _ = try await store.insert(moving: temporaryFile(), for: key("d"), pathExtension: "webp", generation: 0)
        }
        await pass.value
        await store.waitForEviction()
        #expect(files() == [key("a").fileStem + ".webp", key("d").fileStem + ".webp"])
        #expect(await store.size == 32_768)
    }

    @Test func evictionSkipsAFileChangedSinceTheListing() async throws {
        try await seed(["a", "b", "c", "d"])
        let gate = ListingGate()
        let store = makeStore(limit: 50_000, gate: gate)

        let scan = Task { await store.fullPass() }
        #expect(await gate.waitForEntries(1))
        let oldest = images.appending(path: serverID.uuidString).appending(path: key("a").fileStem + ".webp")
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: oldest.path)
        gate.release()
        await scan.value
        #expect(files() == [key("a").fileStem + ".webp", key("d").fileStem + ".webp"])
        #expect(await store.size == 32_768)
    }

    @Test func stagingFilesAreNotCountedAndLeftoversAreDeleted() async throws {
        try await seed(["a"])
        let folder = images.appending(path: serverID.uuidString)
        let (old, fresh) = (folder.appending(path: ".old.partial"), folder.appending(path: ".fresh.partial"))
        try FileManager.default.moveItem(at: temporaryFile(), to: old)
        try FileManager.default.moveItem(at: temporaryFile(), to: fresh)
        try FileManager.default.setAttributes([.modificationDate: clock.now() - 601], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: clock.now() - 60], ofItemAtPath: fresh.path)
        let gate = ListingGate()
        let store = makeStore(gate: gate)
        gate.release()

        #expect(await store.size == 16_384)
        // A recent one may be another process's write in progress.
        #expect(files() == [".fresh.partial", key("a").fileStem + ".webp"])
    }

    /// Runs `operation` while a listing is blocked, then releases it. Expects `operation` to
    /// finish first; it's given two seconds, so a wrong implementation fails rather than hangs.
    private func completes(
        _ gate: ListingGate, _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let done = Mutex(false)
        let task = Task {
            try await operation()
            done.withLock { $0 = true }
        }
        let finishedFirst = await poll { done.withLock { $0 } }
        gate.release()
        try await task.value
        #expect(finishedFirst)
    }
}

/// A settable time for the store's `now`.
private final class Clock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_000_000))

    func now() -> Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// Blocks the store's folder listings on their own threads until released.
final class ListingGate: Sendable {
    private let state = Mutex((entries: 0, blocked: 0, isBlocking: true))
    private let semaphore = DispatchSemaphore(value: 0)

    /// The listings that have reached the gate.
    var entries: Int { state.withLock { $0.entries } }

    @Sendable func block() {
        let blocks = state.withLock { state in
            state.entries += 1
            guard state.isBlocking else { return false }
            state.blocked += 1
            return true
        }
        if blocks { semaphore.wait() }
    }

    func waitForEntries(_ count: Int) async -> Bool {
        await poll { self.entries >= count }
    }

    /// Lets every blocked listing go, and the later ones through.
    func release() {
        let blocked = state.withLock { state in
            state.isBlocking = false
            defer { state.blocked = 0 }
            return state.blocked
        }
        for _ in 0..<blocked { semaphore.signal() }
    }

    func blocksAgain() {
        state.withLock { $0.isBlocking = true }
    }
}

/// Waits up to two seconds for `condition`.
func poll(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
