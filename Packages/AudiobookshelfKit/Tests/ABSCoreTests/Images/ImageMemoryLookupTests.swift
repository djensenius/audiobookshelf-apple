import CoreGraphics
import Foundation
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
        var held = pipeline.cachedImage(for: harness.key(), pixelBox: box)
        let cost = try #require(held?.cost)
        await pipeline.trimMemory(toFraction: 0)
        let trimmed = await pipeline.memoryCost
        #expect(trimmed.lru == 0 && trimmed.combined == cost)
        held = nil
        try await yieldUntil { await pipeline.memoryCost.combined == 0 }
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
