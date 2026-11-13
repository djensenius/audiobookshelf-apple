import Foundation
import Testing

@testable import ABSCore

/// File leases through the pipeline, with a decode queued behind a full decode cap (ADR 0005,
/// "Leases" and "Vanished files").
@Suite(.timeLimit(.minutes(1))) struct ImagePipelineLeaseTests {
    private let harness: PipelineHarness
    private let box = PixelBox(width: 512, height: 512)

    init() throws {
        harness = try PipelineHarness()
    }

    /// A pipeline with one decode slot, a memory cap a held 512 × 512 image fills, and a disk
    /// cap every stored file is over. `"a"` and `"b"` come from a downloaded cover, so the store
    /// holds only the network's.
    private struct Queued {
        let pipeline: ImagePipeline
        let store: CoverFileStore
        let host: String
        /// The image keeping `blocker` waiting for memory while it holds the decode slot.
        var held: [CoverImage]
        let blocker: Task<Void, any Error>
        let queued: Task<Int, any Error>
        /// `queued`'s stored input file.
        let file: URL
    }

    /// Starts `"c"`'s load and returns once its file is stored and its decode is queued behind
    /// `"b"`'s, which holds the only decode slot while it waits for memory `"a"` holds.
    private func queuedDecode() async throws -> Queued {
        let local = try TestImages.file(width: 512, height: 512, in: harness.directory.url)
        let cover = DownloadedCover(fileURL: local, updatedAt: 1)
        let mebibyte = 1 << 20
        let limits = ImageCacheLimits(memoryBytes: 3 * mebibyte / 2, diskBytes: 1, maxConcurrentDecodes: 1)
        let host = PipelineHarness.pngRoute(width: 512, height: 512)
        let (pipeline, store) = await harness.make(
            host: host, limits: limits, downloaded: ["a": cover, "b": cover])
        let box = box
        let held = [try await pipeline.image(for: harness.key("a"), pixelBox: box)]
        let blocker = Task { [key = harness.key("b")] in _ = try await pipeline.image(for: key, pixelBox: box) }
        try await yieldUntil { await pipeline.memoryWaiterCount > 0 }
        let key = harness.key("c")
        let queued = Task { try await pipeline.image(for: key, pixelBox: box).pixelWidth }
        try await yieldUntil { await pipeline.queuedDecodeCount > 0 }
        let file = store.directory.appending(path: "\(key.serverID.uuidString)/\(key.fileStem).png")
        return Queued(
            pipeline: pipeline, store: store, host: host, held: held, blocker: blocker, queued: queued, file: file)
    }

    /// Returns once nothing leases `file`; throws if a lease is never released.
    private func waitUntilUnleased(
        _ file: URL, in store: CoverFileStore, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await yieldUntil(sourceLocation: sourceLocation) { await !store.isLeased(file) }
    }

    @Test(arguments: [false, true])
    func anEvictionSkipsTheInputOfAQueuedDecodeUntilItEnds(cancels: Bool) async throws {
        var queued = try await queuedDecode()
        #expect(FileManager.default.fileExists(atPath: queued.file.path))

        // The store is over its cap and this is its only (so oldest) file, but it is leased.
        await queued.store.fullPass()
        #expect(FileManager.default.fileExists(atPath: queued.file.path))
        #expect(await queued.store.isLeased(queued.file))

        if cancels {
            queued.queued.cancel()
            await #expect(throws: CancellationError.self) { try await queued.queued.value }
        }
        queued.held.removeAll()
        try await queued.blocker.value
        if !cancels { #expect(try await queued.queued.value == 512) }

        // Released once the decode finished or was cancelled, so the next eviction deletes it.
        try await waitUntilUnleased(queued.file, in: queued.store)
        await queued.store.fullPass()
        #expect(!FileManager.default.fileExists(atPath: queued.file.path))
        #expect(ImageStubProtocol.route(queued.host)?.requests.count == 1)
    }

    @Test func aFileDeletedBehindTheStoresBackIsRefetchedOnceThenFails() async throws {
        var queued = try await queuedDecode()
        try FileManager.default.removeItem(at: queued.file)
        ImageStubProtocol.update(queued.host) { route in
            route.status = 404
            route.body = Data("missing".utf8)
            route.mimeType = "text/plain"
        }

        queued.held.removeAll()
        try await queued.blocker.value
        // The view shows its placeholder for the error.
        await #expect(throws: ImagePipelineError.httpStatus(404)) { try await queued.queued.value }
        #expect(ImageStubProtocol.route(queued.host)?.requests.count == 2)
        #expect(await queued.pipeline.networkFetchCount == 2)
    }
}
