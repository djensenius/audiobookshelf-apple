import CryptoKit
import Foundation

/// Identifies an EPUB's cached locations: the book file of an item on one connection.
public struct EPUBLocationsKey: Sendable, Hashable, Codable {
    public var connectionID: UUID
    public var itemID: String
    /// The ebook file's `ino`; a replaced file gets new locations.
    public var ebookFileIno: String

    public init(connectionID: UUID, itemID: String, ebookFileIno: String) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.ebookFileIno = ebookFileIno
    }
}

/// The epub.js `book.locations.save()` strings of opened EPUBs, on disk (ADR 0008 §1).
///
/// Generating locations walks the whole book, so the reader keeps them per book file instead of
/// in `localStorage`. Each connection has a folder named by its UUID, and each entry a file named
/// by a SHA-256 of its item ID and `ino`, so server IDs never become path components.
///
/// An entry over `maxEntryBytes` isn't stored. After each store, the least recently used entries
/// (by modification date, which reads update) are deleted until the files total at most
/// `maxTotalBytes`. An entry that doesn't decode, belongs to another key, isn't a JSON array of
/// strings or is over the limit is deleted when read.
public actor EPUBLocationsCache {
    public static let defaultMaxEntryBytes = 2 << 20
    public static let defaultMaxTotalBytes = 32 << 20

    public nonisolated let directory: URL
    public nonisolated let maxEntryBytes: Int
    public nonisolated let maxTotalBytes: Int
    private let now: @Sendable () -> Date

    /// `directory` belongs to the cache, for example a folder in the caches directory.
    public init(
        directory: URL, maxEntryBytes: Int = defaultMaxEntryBytes, maxTotalBytes: Int = defaultMaxTotalBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = max(maxTotalBytes, maxEntryBytes)
        self.now = now
    }

    /// The cached locations of `key`, or `nil`.
    public func locations(for key: EPUBLocationsKey) -> String? {
        let url = fileURL(for: key)
        guard let size = Self.size(of: url) else { return nil }
        guard size <= maxEntryBytes + Self.entryOverhead, let data = try? Data(contentsOf: url),
            let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.key == key,
            isValid(entry.locations)
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return entry.locations
    }

    /// Saves `locations` for `key`, replacing an older entry. Locations that are too large or
    /// aren't a JSON array of strings are not saved, and the older entry is removed.
    public func store(_ locations: String, for key: EPUBLocationsKey) {
        let url = fileURL(for: key)
        guard isValid(locations), let data = try? JSONEncoder().encode(Entry(key: key, locations: locations)) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return
        }
        evict()
    }

    public func remove(_ key: EPUBLocationsKey) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Removes every entry of a connection, for example when it is signed out.
    public func remove(itemsOf connectionID: UUID) {
        try? FileManager.default.removeItem(at: folder(of: connectionID))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func fileURL(for key: EPUBLocationsKey) -> URL {
        // JSON keeps the two IDs apart: no pair of IDs encodes like another.
        let identity = (try? JSONEncoder().encode([key.itemID, key.ebookFileIno])) ?? Data()
        let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return folder(of: key.connectionID).appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    private func folder(of connectionID: UUID) -> URL {
        directory.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
    }

    /// Room for the key fields and JSON escaping around the locations.
    private static let entryOverhead = 64 << 10

    private func isValid(_ locations: String) -> Bool {
        let data = Data(locations.utf8)
        return data.count <= maxEntryBytes && (try? JSONSerialization.jsonObject(with: data)) is [String]
    }

    /// Deletes the least recently used entries until the cache fits `maxTotalBytes`.
    private func evict() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        let oldestFirst = files.sorted { ($0.date, $0.url.path) < ($1.date, $1.url.path) }
        for file in oldestFirst where total > maxTotalBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private struct Entry: Codable {
        var key: EPUBLocationsKey
        var locations: String
    }
}
