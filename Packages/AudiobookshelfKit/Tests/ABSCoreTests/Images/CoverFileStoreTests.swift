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
        let oldestButLeased = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "webp")
        for id in ["b", "c"] {
            _ = try await store.insert(moving: temporaryFile(), for: key(id), pathExtension: "webp")
        }
        #expect(await store.evictionCount == 0)
        _ = try await store.insert(moving: temporaryFile(), for: key("d"), pathExtension: "webp")
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
        var file: LeasedFile? = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "jpg")
        let url = try #require(file?.url)
        #expect(url.pathExtension == "jpg")
        #expect(await store.isLeased(url))
        file = nil
        #expect(await store.isLeased(url) == false)
    }

    @Test func fullPassRescansAndRemovingAServerDeletesItsFolder() async throws {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        _ = try await store.insert(moving: temporaryFile(), for: key("a"), pathExtension: "webp")
        let reopened = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: 1 << 20)
        #expect(await reopened.size == 16_384)
        await reopened.removeServer(serverID)
        #expect(await reopened.size == 0)
        #expect(await reopened.lookup(key("a")) == nil)
    }
}
