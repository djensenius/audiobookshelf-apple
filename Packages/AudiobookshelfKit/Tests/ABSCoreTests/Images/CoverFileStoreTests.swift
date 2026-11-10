import Foundation
import Synchronization
import Testing

@testable import ABSCore

@Suite struct CoverFileStoreTests {
    private let directory: TemporaryDirectory
    private let serverID = UUID()

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// A 16 KiB file (whole APFS blocks, so its allocated size is exact).
    private func temporaryFile() throws -> URL {
        let url = directory.url.appending(path: UUID().uuidString)
        try Data(repeating: 7, count: 16_384).write(to: url)
        return url
    }

    private func key(_ id: String) -> ImageKey {
        ImageKey(serverID: serverID, kind: .itemCover, entityID: id, updatedAt: 1)
    }

    @Test func evictsOldestUnleasedFilesToNinetyPercentOnce() async throws {
        let tick = Mutex(0.0)
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 50_000) {
            tick.withLock { value in
                value += 60
                return Date(timeIntervalSince1970: value)
            }
        }
        let oldestButLeased = try await store.insert(
            moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
        for id in ["b", "c"] {
            _ = try await store.insert(moving: temporaryFile(), for: key(id), pathExtension: "webp", generation: 0)
        }
        #expect(await store.evictionCount == 0)
        _ = try await store.insert(moving: temporaryFile(), for: key("d"), pathExtension: "webp", generation: 0)
        await store.waitForEviction()

        #expect(await store.evictionCount == 1)
        #expect(await store.size <= 45_000)
        #expect(await store.lookup(key("a"))?.url == oldestButLeased.url)
        #expect(await store.lookup(key("b")) == nil)
        #expect(await store.lookup(key("c")) == nil)
        #expect(await store.lookup(key("d")) != nil)
        #expect(await store.isLeased(oldestButLeased.url))
    }

    @Test func leaseIsReleasedWithItsLastHolder() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        var file: LeasedFile? = try await store.insert(
            moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)
        let url = try #require(file?.url)
        #expect(url.pathExtension == "jpg")
        #expect(await store.isLeased(url))
        file = nil
        #expect(await store.isLeased(url) == false)
    }

    @Test func fullPassRescansAndRemovingAServerDeletesItsFolder() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
        let reopened = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        #expect(await reopened.size == 16_384)
        await reopened.removeServer(serverID)
        #expect(await reopened.size == 0)
        #expect(await reopened.lookup(key("a")) == nil)
    }

    @Test func writesStartedBeforeAServerRemovalAreRefused() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        let generation = await store.generation(for: serverID)
        await store.removeServer(serverID)
        await #expect(throws: CancellationError.self) {
            try await store.insert(
                moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: generation)
        }
        #expect(await store.size == 0)
        let current = await store.generation(for: serverID)
        _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: current)
        #expect(await store.size == 16_384)
    }

    @Test func replacingALeasedCopyKeepsItReadableUntilReleased() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        var webp: LeasedFile? = try await store.insert(
            moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
        let webpURL = try #require(webp?.url)
        let jpg = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)

        #expect(try Data(contentsOf: webpURL).count == 16_384)
        #expect(await store.lookup(key("a"))?.url == jpg.url)
        #expect(await store.size == 16_384)
        webp = nil
        #expect(!FileManager.default.fileExists(atPath: webpURL.path))
        #expect(FileManager.default.fileExists(atPath: jpg.url.path))
    }

    @Test func failedReplacementKeepsTheOldCopy() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        let old = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
        let missing = directory.url.appending(path: "missing")
        await #expect(throws: (any Error).self) {
            try await store.insert(moving: missing, for: key("a"), pathExtension: "jpg", generation: 0)
        }
        #expect(await store.lookup(key("a"))?.url == old.url)
        #expect(try Data(contentsOf: old.url).count == 16_384)
        #expect(await store.size == 16_384)
    }

    @Test func discardedLeasedFileIsSkippedThenReplacedInPlace() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        let bad = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "png", generation: 0)
        await store.discard(bad.url)
        #expect(await store.lookup(key("a")) == nil)
        #expect(await store.size == 0)
        let good = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "png", generation: 0)
        withExtendedLifetime(bad) {}
        #expect(FileManager.default.fileExists(atPath: good.url.path))
        #expect(await store.lookup(key("a"))?.url == good.url)
        #expect(await store.size == 16_384)
    }

    @Test func retiredLeasedFileIsNotCountedAgainByARescan() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 40_000)
        var retired: LeasedFile? = try await store.insert(
            moving: temporaryFile(), for: key("a"), pathExtension: "webp", generation: 0)
        let retiredURL = try #require(retired?.url)
        await store.discard(retiredURL)
        for id in ["b", "c"] {
            _ = try await store.insert(moving: temporaryFile(), for: key(id), pathExtension: "webp", generation: 0)
        }
        await store.fullPass()
        #expect(await store.size == 32_768)
        retired = nil
        #expect(!FileManager.default.fileExists(atPath: retiredURL.path))
        await store.fullPass()
        #expect(await store.size == 32_768)
        #expect(await store.lookup(key("b")) != nil)
        #expect(await store.lookup(key("c")) != nil)
    }
}
