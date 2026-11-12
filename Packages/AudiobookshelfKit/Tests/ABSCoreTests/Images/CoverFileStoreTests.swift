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

    /// A 16 KiB file by default; whole APFS blocks, so its allocated size is exact.
    private func temporaryFile(bytes: Int = 16_384) throws -> URL {
        let url = directory.url.appending(path: UUID().uuidString)
        try Data(repeating: 7, count: bytes).write(to: url)
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

    @Test func failedFinalRenameLeavesTheInputInPlace() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        // A non-empty folder where the file belongs makes the final rename fail.
        let folder = store.directory.appending(path: serverID.uuidString)
        let blocker = folder.appending(path: "\(key("a").fileStem).jpg")
        try FileManager.default.createDirectory(at: blocker.appending(path: "x"), withIntermediateDirectories: true)
        let input = try temporaryFile()
        await #expect(throws: POSIXError.self) {
            try await store.insert(moving: input, for: key("a"), pathExtension: "jpg", generation: 0)
        }
        #expect(try Data(contentsOf: input).count == 16_384)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [blocker.lastPathComponent])
        #expect(await store.lookup(key("a")) == nil)
        #expect(await store.size == 0)
    }

    @Test func discardedLeasedFileIsSkippedThenReplacedInPlace() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        let bad = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "png", generation: 0)
        await store.discard(bad.url, version: bad.version)
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
        await store.discard(retiredURL, version: try #require(retired?.version))
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

    @Test func sameExtensionReplacementsCountTheNewSize() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)
        let larger = try await store.insert(
            moving: temporaryFile(bytes: 65_536), for: key("a"), pathExtension: "jpg", generation: 0)
        #expect(await store.size == 65_536)
        let smaller = try await store.insert(
            moving: temporaryFile(bytes: 4_096), for: key("a"), pathExtension: "jpg", generation: 0)
        #expect(await store.size == 4_096)
        await store.discard(smaller.url, version: smaller.version)
        #expect(await store.size == 0)
        withExtendedLifetime(larger) {}
    }

    @Test func staleReadersDecodeFailureKeepsTheReplacement() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)
        let first = try #require(await store.lookup(key("a")))
        let second = try await store.insert(
            moving: temporaryFile(bytes: 4_096), for: key("a"), pathExtension: "jpg", generation: 0)
        #expect(first.url == second.url)
        await store.discard(first.url, version: first.version)
        let current = try #require(await store.lookup(key("a")))
        #expect(current.version == second.version)
        #expect(try Data(contentsOf: current.url).count == 4_096)
        #expect(await store.size == 4_096)
    }

    @Test func decodeFailureWithoutAReplacementRemovesTheFile() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)
        var read = await store.lookup(key("a"))
        let url = try #require(read?.url)
        await store.discard(url, version: try #require(read?.version))
        #expect(await store.lookup(key("a")) == nil)
        #expect(await store.size == 0)
        read = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileFromAnEarlierLaunchIsDiscardedAtVersionZero() async throws {
        let images = directory.url.appending(path: "Images")
        _ = try await CoverFileStore(directory: images, limit: 1 << 20).insert(
            moving: temporaryFile(), for: key("a"), pathExtension: "jpg", generation: 0)
        let store = CoverFileStore(directory: images, limit: 1 << 20)
        let read = try #require(await store.lookup(key("a")))
        #expect(read.version == 0)
        await store.discard(read.url, version: read.version)
        #expect(await store.lookup(key("a")) == nil)
        #expect(await store.size == 0)
    }

    @Test func largerReplacementOverTheCapEvicts() async throws {
        let tick = Mutex(0.0)
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 60_000) {
            tick.withLock { value in
                value += 60
                return Date(timeIntervalSince1970: value)
            }
        }
        for id in ["a", "b"] {
            _ = try await store.insert(moving: temporaryFile(), for: key(id), pathExtension: "jpg", generation: 0)
        }
        _ = try await store.insert(
            moving: temporaryFile(bytes: 49_152), for: key("b"), pathExtension: "jpg", generation: 0)
        await store.waitForEviction()
        #expect(await store.evictionCount == 1)
        #expect(await store.size == 49_152)
        #expect(await store.lookup(key("a")) == nil)
        #expect(await store.lookup(key("b")) != nil)
    }
}
