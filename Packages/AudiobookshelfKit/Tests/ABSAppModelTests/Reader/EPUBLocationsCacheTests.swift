import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

@Suite struct EPUBLocationsCacheTests {
    private let root = URL.temporaryDirectory.appending(path: "EPUBLocationsCache-\(UUID().uuidString)")
    private var directory: URL { root.appending(path: "Locations") }
    private let connection = UUID()
    private let locations = #"["epubcfi(/6/2!/4/1:0)","epubcfi(/6/4!/4/2:150)"]"#

    /// A clock that moves one second on every read, so modification dates order the uses.
    private final class Clock: Sendable {
        private let ticks = Mutex(0)
        func now() -> Date {
            let tick = ticks.withLock { value in
                value += 1
                return value
            }
            return Date(timeIntervalSince1970: 1_700_000_000 + Double(tick))
        }
    }

    private func makeCache(maxEntryBytes: Int = 1_000, maxTotalBytes: Int = 100_000) -> EPUBLocationsCache {
        let clock = Clock()
        return EPUBLocationsCache(
            directory: directory, maxEntryBytes: maxEntryBytes, maxTotalBytes: maxTotalBytes, now: { clock.now() })
    }

    private func key(_ item: String = "li_1", ino: String = "100", connection: UUID? = nil) -> EPUBLocationsKey {
        EPUBLocationsKey(connectionID: connection ?? self.connection, itemID: item, ebookFileIno: ino)
    }

    /// Every file under `root`, relative to it.
    private func files() -> Set<String> {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: Set<String> = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                paths.insert(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            }
        }
        return paths
    }

    @Test func roundTrips() async {
        let cache = makeCache()
        #expect(await cache.locations(for: key()) == nil)
        await cache.store(locations, for: key())
        #expect(await cache.locations(for: key()) == locations)
        await cache.store(#"["epubcfi(/6/8)"]"#, for: key())
        #expect(await cache.locations(for: key()) == #"["epubcfi(/6/8)"]"#)
    }

    @Test func survivesANewCacheInstance() async {
        await makeCache().store(locations, for: key())
        #expect(await makeCache().locations(for: key()) == locations)
    }

    @Test func entriesAreSeparatePerConnectionItemAndFile() async {
        let cache = makeCache()
        let other = UUID()
        await cache.store(#"["a"]"#, for: key())
        await cache.store(#"["b"]"#, for: key("li_2"))
        await cache.store(#"["c"]"#, for: key(ino: "101"))
        await cache.store(#"["d"]"#, for: key(connection: other))

        #expect(await cache.locations(for: key()) == #"["a"]"#)
        #expect(await cache.locations(for: key("li_2")) == #"["b"]"#)
        #expect(await cache.locations(for: key(ino: "101")) == #"["c"]"#)
        #expect(await cache.locations(for: key(connection: other)) == #"["d"]"#)
        #expect(await cache.locations(for: key("li_1100", ino: "")) == nil)
    }

    @Test func fileNamesAreHashesInsideTheConnectionFolder() async throws {
        let cache = makeCache()
        await cache.store(locations, for: key())
        let file = try #require(files().first)
        let name = try #require(file.split(separator: "/").last)
        #expect(file.hasPrefix("Locations/\(connection.uuidString)/"))
        #expect(name.count == 64 + ".json".count)
        #expect(!file.contains("li_1"))
    }

    @Test(arguments: ["../../x", "/etc/passwd", "a/b", "..", "%2e%2e%2fx", "\u{0}"])
    func hostileIDsStayInsideTheDirectory(id: String) async throws {
        let cache = makeCache()
        await cache.store(locations, for: key(id, ino: id))
        #expect(await cache.locations(for: key(id, ino: id)) == locations)
        let file = try #require(files().first)
        #expect(files().count == 1)
        #expect(file.hasPrefix("Locations/\(connection.uuidString)/"))
        #expect(file.split(separator: "/").count == 3)
    }

    @Test func corruptEntriesAreDeleted() async throws {
        let cache = makeCache()
        await cache.store(locations, for: key())
        let url = await cache.fileURL(for: key())
        try Data("{not json".utf8).write(to: url)

        #expect(await cache.locations(for: key()) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await cache.store(locations, for: key())
        #expect(await cache.locations(for: key()) == locations)
    }

    @Test func anEntryForAnotherKeyIsDeleted() async throws {
        let cache = makeCache()
        await cache.store(locations, for: key("li_2"))
        let other = await cache.fileURL(for: key("li_2"))
        let url = await cache.fileURL(for: key())
        try FileManager.default.copyItem(at: other, to: url)

        #expect(await cache.locations(for: key()) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func oversizedEntriesOnDiskAreDeleted() async throws {
        let cache = makeCache()
        await cache.store(locations, for: key())
        let url = await cache.fileURL(for: key())
        try Data(count: cache.maxFileBytes + 1).write(to: url)

        #expect(await cache.locations(for: key()) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: ["not json", #"{"a":1}"#, "[1,2]", ""])
    func locationsThatAreNotAnArrayOfStringsAreNotStored(value: String) async {
        let cache = makeCache()
        await cache.store(locations, for: key())
        await cache.store(value, for: key())
        #expect(await cache.locations(for: key()) == nil)
        #expect(files().isEmpty)
    }

    @Test func locationsOverTheEntryLimitAreNotStored() async {
        let cache = makeCache(maxEntryBytes: 100)
        let big = "[" + Array(repeating: #""epubcfi(/6/2)""#, count: 10).joined(separator: ",") + "]"
        await cache.store(big, for: key())
        #expect(await cache.locations(for: key()) == nil)
        #expect(files().isEmpty)
    }

    /// Locations just under the entry limit, every character of whose CFIs JSON escapes, are
    /// stored and read back rather than deleted as oversized.
    @Test func locationsNearTheEntryLimitRoundTrip() async throws {
        let cache = makeCache(
            maxEntryBytes: EPUBLocationsCache.defaultMaxEntryBytes,
            maxTotalBytes: EPUBLocationsCache.defaultMaxTotalBytes)
        let cfi = #""epubcfi(/6/4!/4/2:300)""#
        let count = (cache.maxEntryBytes - 2) / (cfi.utf8.count + 1)
        let near = "[" + Array(repeating: cfi, count: count).joined(separator: ",") + "]"
        #expect(near.utf8.count > cache.maxEntryBytes - cfi.utf8.count - 1)
        #expect(near.utf8.count <= cache.maxEntryBytes)

        await cache.store(near, for: key())

        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: await cache.fileURL(for: key()).path)[.size] as? Int)
        #expect(size > cache.maxEntryBytes + (64 << 10))
        #expect(await cache.locations(for: key()) == near)
        #expect(await cache.locations(for: key()) == near)
    }

    /// An entry whose file would be over the read limit (here, a huge item ID) isn't stored, so
    /// nothing is written that a read would delete.
    @Test func anEntryWhoseFileWouldBeTooLargeIsNotStored() async {
        let cache = makeCache(maxEntryBytes: 100)
        let huge = key(String(repeating: "x", count: cache.maxFileBytes))

        await cache.store(locations, for: huge)

        #expect(files().isEmpty)
        #expect(await cache.locations(for: huge) == nil)
    }

    @Test func theLeastRecentlyUsedEntriesAreEvicted() async throws {
        // Measure one entry's file, then allow two. Every entry here has the same size.
        let probe = makeCache()
        await probe.store(locations, for: key("li_1"))
        let path = await probe.fileURL(for: key("li_1")).path
        let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        await probe.removeAll()

        let lru = makeCache(maxEntryBytes: 100, maxTotalBytes: 2 * size)
        await lru.store(locations, for: key("li_1"))
        await lru.store(locations, for: key("li_2"))
        #expect(await lru.locations(for: key("li_1")) == locations)
        await lru.store(locations, for: key("li_3"))

        #expect(await lru.locations(for: key("li_2")) == nil)
        #expect(await lru.locations(for: key("li_1")) == locations)
        #expect(await lru.locations(for: key("li_3")) == locations)
        #expect(files().count == 2)
    }

    @Test func removesOneEntryAConnectionOrEverything() async {
        let cache = makeCache()
        let other = UUID()
        await cache.store(locations, for: key("li_1"))
        await cache.store(locations, for: key("li_2"))
        await cache.store(locations, for: key(connection: other))

        await cache.remove(key("li_1"))
        #expect(await cache.locations(for: key("li_1")) == nil)
        #expect(await cache.locations(for: key("li_2")) == locations)

        await cache.remove(itemsOf: connection)
        #expect(await cache.locations(for: key("li_2")) == nil)
        #expect(await cache.locations(for: key(connection: other)) == locations)

        await cache.removeAll()
        #expect(await cache.locations(for: key(connection: other)) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
