import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSCore

/// Removing servers from `CoverFileStore` and `ImagePipeline`: waiting for leases, deleting off
/// the actor, and sweeping the folders of connections removed in an earlier launch (#143, #421).
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

    @Test func passFinishedDuringTheLeaseWaitIsNotReducedAgain() async throws {
        try await seed([serverID, otherServerID])
        let listing = ListingGate()
        listing.release()
        let waiting = Gate()
        let store = store(listing: listing) {
            waiting.open(); await untilCancelled()
        }
        #expect(await store.size == 32_768)
        var held: LeasedFile? = try await store.insert(
            moving: temporaryFile(), for: key("b"), pathExtension: "webp", generation: 0)
        #expect(await store.size == 49_152)

        // A pass lists the folder, then the removal starts and waits for the lease.
        listing.blocksAgain()
        let pass = Task { await store.fullPass() }
        #expect(await listing.waitForEntries(2))
        let removal = Task { await store.removeServer(serverID) }
        await waiting.wait()
        // The pass drops the removed server's files.
        listing.release()
        await pass.value
        #expect(await store.size == 16_384)
        held = nil
        await removal.value
        #expect(files(serverID).isEmpty)
        #expect(await store.size == 16_384)
    }

    @Test func fileRetiredBeforeTheRemovalIsNotSubtractedAgain() async throws {
        try await seed([serverID, otherServerID])
        let gate = ListingGate()
        // The lease wait times out at once.
        let store = store(deletion: gate)
        #expect(await store.size == 32_768)
        var held: LeasedFile? = try await store.insert(
            moving: temporaryFile(), for: key("b"), pathExtension: "webp", generation: 0)
        let (url, version) = try #require(held.map { ($0.url, $0.version) })
        await store.discard(url, version: version)
        #expect(await store.size == 32_768)

        let removal = Task { await store.removeServer(serverID) }
        #expect(await gate.waitForEntries(1))
        // Released after the move, before the moved folder is measured.
        held = nil
        gate.release()
        await removal.value
        #expect(files(serverID).isEmpty)
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

    // MARK: - Sweep (#421)

    @Test func sweepDeletesUnknownServersFoldersAndKeepsSavedOnes() async throws {
        let saved = UUID()
        try await seed([saved, serverID, otherServerID])
        let store = store()
        #expect(await store.size == 49_152)

        let removed = await store.removeServers(keepingOnly: [saved])
        #expect(removed == [serverID, otherServerID])
        #expect(files(serverID).isEmpty)
        #expect(files(otherServerID).isEmpty)
        #expect(files(saved).count == 1)
        #expect(await store.size == 16_384)
    }

    @Test func pipelineSweepKeepsAConnectionSavedDuringIt() async throws {
        let saved = UUID()
        try await seed([saved, serverID, otherServerID])
        let gate = ListingGate()
        let store = store(listing: gate)
        let pipeline = ImagePipeline(
            limits: .iPhone, fileStore: store, sessionConfiguration: ImageStubProtocol.configuration())

        // Read before `otherServerID` was saved; it signs in while the folders are listed.
        let sweep = Task { await pipeline.removeServers(keepingOnly: [saved]) }
        #expect(await gate.waitForEntries(1))
        await pipeline.setRequestBuilder(TestRequestBuilder(host: "unused.images.test"), for: otherServerID)
        gate.release()
        await sweep.value

        #expect(files(serverID).isEmpty)
        #expect(files(otherServerID).count == 1)
        #expect(files(saved).count == 1)
    }

    @Test func pipelineSweepClearsMemoryAndBlocksTheRemovedServers() async throws {
        try await seed([serverID])
        let store = store()
        let pipeline = ImagePipeline(
            limits: .iPhone, fileStore: store, sessionConfiguration: ImageStubProtocol.configuration())
        let box = PixelBox(width: 4, height: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = DecodedBitmap(try #require(context.makeImage()), ledger: nil)
        // Cached in memory for a server with no session, as from a downloaded cover.
        try await pipeline.cache(bitmap, for: MemoryKey(key: key("b", server: otherServerID), box: box))

        await pipeline.removeServers(keepingOnly: [])

        #expect(files(serverID).isEmpty)
        #expect(pipeline.cachedImage(for: key("b", server: otherServerID), pixelBox: box) == nil)
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.image(for: key("a"), pixelBox: box)
        }
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.cache(bitmap, for: MemoryKey(key: key("b", server: otherServerID), box: box))
        }
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
