import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSCore

/// Removing servers from `CoverFileStore`: waiting for leases, and deleting off the actor (#143).
/// Serialized, like the listing tests: a blocked deletion holds a thread of the shared pool.
@Suite(.serialized, .timeLimit(.minutes(1))) struct CoverFileStoreMaintenanceTests {
    private let directory: TemporaryDirectory
    private let serverID = UUID()
    private let otherServerID = UUID()
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

    /// Writes a cover for each server with another store, as an earlier launch would have.
    private func seed(_ servers: [UUID]) async throws {
        let store = CoverFileStore(directory: images, limit: 1 << 30)
        for server in servers {
            _ = try await store.insert(
                moving: temporaryFile(), for: key("a", server: server), pathExtension: "webp", generation: 0)
        }
    }

    private func files(_ server: UUID) -> [String] {
        let folder = images.appending(path: server.uuidString)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func store(
        listing: ListingGate? = nil, deletion: ListingGate? = nil,
        leaseTimeout: @escaping @Sendable () async throws -> Void = {}
    ) -> CoverFileStore {
        CoverFileStore(
            directory: images, limit: 1 << 30, now: Date.init, listingHook: listing?.block,
            deletionHook: deletion?.block, leaseTimeout: leaseTimeout)
    }

    // MARK: - Leases

    @Test func removalWaitsForTheServersLeases() async throws {
        let waiting = Gate()
        let store = store {
            waiting.open(); await untilCancelled()
        }
        var held: LeasedFile? = try await store.insert(
            moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
        let url = try #require(held?.url)

        let removal = Task { await store.removeServer(serverID) }
        await waiting.wait()
        // Still readable while the decode holding it runs.
        #expect(try Data(contentsOf: url).count == 16_384)
        held = nil
        await removal.value
        #expect(files(serverID).isEmpty)
        #expect(await store.size == 0)
    }

    @Test func removalStopsWaitingForLeasesAfterTheTimeout() async throws {
        // The timeout has already passed.
        let store = store {}
        let held = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)

        await store.removeServer(serverID)
        #expect(files(serverID).isEmpty)
        #expect(await store.size == 0)
        withExtendedLifetime(held) {}
    }

    // MARK: - Off the actor

    @Test func removalDeletesTheFolderOffTheActor() async throws {
        try await seed([serverID, otherServerID])
        let gate = ListingGate()
        let store = store(deletion: gate)
        #expect(await store.size == 32_768)

        let removal = Task { await store.removeServer(serverID) }
        #expect(await gate.waitForEntries(1))
        let answered = Mutex(false)
        let call = Task {
            _ = await store.generation(for: otherServerID)
            answered.withLock { $0 = true }
        }
        let wasAnswered = await poll { answered.withLock { $0 } }
        gate.release()
        await removal.value
        await call.value
        #expect(wasAnswered)
        #expect(files(serverID).isEmpty)
        #expect(await store.size == 16_384)
    }

    @Test func passFinishedDuringARemovalIsNotReducedAgain() async throws {
        try await seed([serverID, otherServerID])
        let gate = ListingGate()
        let store = store(deletion: gate)
        #expect(await store.size == 32_768)

        let removal = Task { await store.removeServer(serverID) }
        #expect(await gate.waitForEntries(1))
        // The folder is already moved aside, so this pass counts only the other server.
        await store.fullPass()
        #expect(await store.size == 16_384)
        gate.release()
        await removal.value
        #expect(await store.size == 16_384)
    }

    @Test func folderLeftByAnInterruptedRemovalIsDeletedAndNotCounted() async throws {
        try await seed([serverID])
        let leftover = images.appending(path: ".\(otherServerID.uuidString).\(UUID().uuidString).removing")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporaryFile(), to: leftover.appending(path: "cover.webp"))
        let store = store()

        await store.fullPass()
        #expect(await store.size == 16_384)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(files(serverID).count == 1)
    }

}

/// Returns only when the task is cancelled: a lease timeout that never passes by itself.
private func untilCancelled() async {
    let state = Mutex<(isCancelled: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            let resumes = state.withLock { state in
                guard !state.isCancelled else { return true }
                state.continuation = continuation
                return false
            }
            if resumes { continuation.resume() }
        }
    } onCancel: {
        state.withLock { state in
            state.isCancelled = true
            defer { state.continuation = nil }
            return state.continuation
        }?.resume()
    }
}
