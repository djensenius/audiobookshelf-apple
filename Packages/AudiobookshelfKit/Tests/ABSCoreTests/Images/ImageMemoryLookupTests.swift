import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSCore

/// `ImagePipeline.cachedImage(for:pixelBox:)`, the synchronous memory lookup views read before
/// their first frame: it must see exactly the actor's LRU and hold its hits like async ones.
@Suite(.timeLimit(.minutes(1))) struct ImageMemoryLookupTests {
    private let harness: PipelineHarness
    /// A 512 × 512 cover decodes to 1 MiB in this box.
    private let box = PixelBox(width: 512, height: 512)

    init() throws {
        harness = try PipelineHarness()
    }

    /// A pipeline whose every cover is a local 512 × 512 file, with room for `mebibytes`.
    private func makePipeline(mebibytes: Double = 64) async throws -> ImagePipeline {
        let file = try TestImages.file(width: 512, height: 512, in: harness.directory.url)
        let limits = ImageCacheLimits(
            memoryBytes: Int(mebibytes * Double(1 << 20)), diskBytes: 1 << 20, maxConcurrentDecodes: 2)
        return await harness.make(limits: limits, local: file).0
    }

    @Test func missesUntilLoadedThenHitsTheLoadedBitmap() async throws {
        let pipeline = try await makePipeline()
        let key = harness.key()
        #expect(pipeline.cachedImage(for: key, pixelBox: box) == nil)
        // A miss loads nothing.
        #expect(await pipeline.memoryCost.combined == 0)
        let loaded = try await pipeline.image(for: key, pixelBox: box)
        let hit = try #require(pipeline.cachedImage(for: key, pixelBox: box))
        #expect(hit.cgImage === loaded.cgImage)
    }

    @Test func onlyTheSameKeyAndRoundedBoxHit() async throws {
        let pipeline = try await makePipeline()
        let key = harness.key()
        let image = try await pipeline.image(for: key, pixelBox: box)
        // Boxes are rounded up to 32 px, so this is the same entry.
        #expect(pipeline.cachedImage(for: key, pixelBox: PixelBox(width: 500, height: 490))?.cgImage === image.cgImage)
        let misses: [(ImageKey, PixelBox)] = [
            (key, PixelBox(width: 192, height: 288)),
            (key.with(bucket: .large), box),
            (harness.key(updatedAt: 2), box),
            (harness.key(updatedAt: nil), box),
            (harness.key("item-2"), box),
            (harness.key(url: URL(string: "https://covers.example/1.jpg")), box),
            (ImageKey(serverID: UUID(), kind: .itemCover, entityID: "item-1", updatedAt: 1), box),
            (ImageKey(serverID: harness.serverID, kind: .authorImage, entityID: "item-1", updatedAt: 1), box),
        ]
        for (other, otherBox) in misses {
            #expect(pipeline.cachedImage(for: other, pixelBox: otherBox) == nil, "\(other) \(otherBox)")
        }
    }

    @Test func trimmedEntriesMiss() async throws {
        let pipeline = try await makePipeline()
        _ = try await pipeline.image(for: harness.key(), pixelBox: box)
        await pipeline.trimMemory(toFraction: 0)
        #expect(pipeline.cachedImage(for: harness.key(), pixelBox: box) == nil)
    }

    @Test func aHitCountsAsRecentlyUsed() async throws {
        let pipeline = try await makePipeline(mebibytes: 4)
        let (first, second) = (harness.key("a"), harness.key("b"))
        _ = try await pipeline.image(for: first, pixelBox: box)
        _ = try await pipeline.image(for: second, pixelBox: box)
        _ = pipeline.cachedImage(for: first, pixelBox: box)
        // Room for one image: the least recently used, now `second`, goes.
        await pipeline.trimMemory(toFraction: 0.4)
        #expect(pipeline.cachedImage(for: first, pixelBox: box) != nil)
        #expect(pipeline.cachedImage(for: second, pixelBox: box) == nil)
    }

    @Test func evictionSkipsAHeldHitAndEvictedEntriesMiss() async throws {
        // Room for two images, so loading a third evicts one.
        let pipeline = try await makePipeline(mebibytes: 2.5)
        let (first, second, third) = (harness.key("a"), harness.key("b"), harness.key("c"))
        _ = try await pipeline.image(for: first, pixelBox: box)
        _ = try await pipeline.image(for: second, pixelBox: box)
        let held = try #require(pipeline.cachedImage(for: first, pixelBox: box))
        // `first` is now the least recently used, but held.
        _ = pipeline.cachedImage(for: second, pixelBox: box)
        _ = try await pipeline.image(for: third, pixelBox: box)
        #expect(pipeline.cachedImage(for: second, pixelBox: box) == nil)
        #expect(pipeline.cachedImage(for: first, pixelBox: box)?.cgImage === held.cgImage)
        #expect(pipeline.cachedImage(for: third, pixelBox: box) != nil)
        #expect(await pipeline.memoryCost.combined <= Int(2.5 * Double(1 << 20)))
    }

    @Test func aHeldHitCountsAgainstTheCapUntilReleased() async throws {
        let pipeline = try await makePipeline()
        _ = try await pipeline.image(for: harness.key(), pixelBox: box)
        do {
            let held = try #require(pipeline.cachedImage(for: harness.key(), pixelBox: box))
            await pipeline.trimMemory(toFraction: 0)
            let trimmed = await pipeline.memoryCost
            #expect(trimmed.lru == 0 && trimmed.combined == held.cost)
            withExtendedLifetime(held) {}
        }
        try await yieldUntil { await pipeline.memoryCost.combined == 0 }
    }

    @Test func aDecodeFinishingAfterItsServerIsRemovedIsNotCached() async throws {
        let pipeline = try await makePipeline()
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = DecodedBitmap(try #require(context.makeImage()), ledger: nil)
        let memoryKey = MemoryKey(key: harness.key(), box: box)
        await pipeline.removeServer(harness.serverID)
        await #expect(throws: ImagePipelineError.noRequest) { try await pipeline.cache(bitmap, for: memoryKey) }
        #expect(pipeline.cachedImage(for: harness.key(), pixelBox: box) == nil)
        // Setting a builder again re-enables the server.
        await pipeline.setRequestBuilder(TestRequestBuilder(host: "unused.images.test"), for: harness.serverID)
        try await pipeline.cache(bitmap, for: memoryKey)
        #expect(pipeline.cachedImage(for: harness.key(), pixelBox: box)?.cgImage === bitmap.cgImage)
    }

    /// A counter shared by the stress test's tasks.
    private final class Counter: Sendable {
        private let value = Mutex(0)

        var current: Int { value.withLock { $0 } }

        func advance() {
            value.withLock { $0 += 1 }
        }
    }

    /// Counts the trims and server removals that start or end, so a reader can tell whether one
    /// overlapped its lookups.
    private final class Disruptions: Sendable {
        private let state = Mutex((running: 0, changes: 0))

        /// The change count if none is running, else `nil`.
        var quiet: Int? { state.withLock { $0.running == 0 ? $0.changes : nil } }
        var changes: Int { state.withLock { $0.changes } }

        func during(_ body: () async -> Void) async {
            state.withLock {
                $0.running += 1
                $0.changes += 1
            }
            await body()
            state.withLock {
                $0.running -= 1
                $0.changes += 1
            }
        }
    }

    @Test func concurrentLookupsLoadsTrimsAndRemovalsKeepTheCapAndHeldHits() async throws {
        let limit = 6 << 20
        let pipeline = try await makePipeline(mebibytes: 6)
        let removable = UUID()
        let keys =
            (0..<12).map { harness.key("item-\($0)") }
            + (0..<4).map { ImageKey(serverID: removable, kind: .itemCover, entityID: "item-\($0)", updatedAt: 1) }
        for key in keys.prefix(4) {
            _ = try await pipeline.image(for: key, pixelBox: box)
        }
        // Everything but the loaders runs until they finish.
        let disruptions = Disruptions()
        let (loadersDone, hits, checkedHits) = (Counter(), Counter(), Counter())
        let loaders = 4
        let box = box
        try await withThrowingTaskGroup(of: Void.self) { group in
            for loader in 0..<loaders {
                group.addTask {
                    defer { loadersDone.advance() }
                    for step in 0..<30 {
                        let key = keys[(loader * 7 + step * 5) % keys.count]
                        do {
                            let image = try await pipeline.image(for: key, pixelBox: box)
                            await Task.yield()
                            withExtendedLifetime(image) {}
                        } catch  where key.serverID == removable {
                            // Removed meanwhile.
                        }
                    }
                }
            }
            for reader in 0..<8 {
                group.addTask {
                    var step = reader * 3
                    while loadersDone.current < loaders {
                        step += 1
                        let key = keys[step % keys.count]
                        let before = disruptions.quiet
                        guard let hit = pipeline.cachedImage(for: key, pixelBox: box) else {
                            await Task.yield()
                            continue
                        }
                        hits.advance()
                        #expect(hit.pixelWidth == 512)
                        await Task.yield()
                        let again = pipeline.cachedImage(for: key, pixelBox: box)
                        // Only a trim or removal drops a held hit from the LRU, never eviction.
                        if let before, disruptions.changes == before {
                            checkedHits.advance()
                            #expect(again?.cgImage === hit.cgImage)
                        }
                    }
                }
            }
            group.addTask {
                var step = 0
                while loadersDone.current < loaders {
                    step += 1
                    await disruptions.during { await pipeline.trimMemory(toFraction: [0, 0.25, 0.5][step % 3]) }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            group.addTask {
                while loadersDone.current < loaders {
                    await disruptions.during {
                        await pipeline.removeServer(removable)
                        await pipeline.setRequestBuilder(TestRequestBuilder(host: "unused.images.test"), for: removable)
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            group.addTask {
                while loadersDone.current < loaders {
                    let cost = await pipeline.memoryCost
                    // Held hits are charged once, like every other live image.
                    #expect(cost.lru <= cost.combined && cost.combined <= limit)
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
        // The race was exercised, not skipped.
        #expect(hits.current > 0 && checkedHits.current > 0)
        await pipeline.trimMemory(toFraction: 0)
        try await yieldUntil { await pipeline.memoryCost == (0, 0) }
    }

    @Test func removedServersImagesMiss() async throws {
        let pipeline = try await makePipeline()
        _ = try await pipeline.image(for: harness.key(), pixelBox: box)
        await pipeline.removeServer(harness.serverID)
        #expect(pipeline.cachedImage(for: harness.key(), pixelBox: box) == nil)
    }

    @Test func staleDownloadedCoverHitsOnlyUnderItsOwnVersion() async throws {
        let file = try TestImages.file(width: 100, height: 160, in: harness.directory.url)
        let (pipeline, _) = await harness.make(
            downloaded: ["item-1": DownloadedCover(fileURL: file, updatedAt: 1)], isOnline: { false })
        let stale = try await pipeline.image(for: harness.key(updatedAt: 3), pixelBox: box)
        #expect(pipeline.cachedImage(for: harness.key(updatedAt: 3), pixelBox: box) == nil)
        #expect(pipeline.cachedImage(for: harness.key(updatedAt: 1), pixelBox: box)?.cgImage === stale.cgImage)
    }
}
