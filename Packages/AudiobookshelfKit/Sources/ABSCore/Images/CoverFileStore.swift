import Foundation
import Synchronization

/// Keeps a cache file from eviction while it is alive. Released when the last holder drops it.
final class FileLease: Sendable {
    private let release: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    deinit {
        release()
    }
}

/// Per-file lease counts, readable from any thread.
private final class LeaseCounts: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    var leasedPaths: Set<String> { counts.withLock { Set($0.keys) } }

    func lease(_ path: String) -> FileLease {
        counts.withLock { $0[path, default: 0] += 1 }
        return FileLease { [counts = self] in
            counts.counts.withLock { counts in
                counts[path, default: 1] -= 1
                if counts[path] == 0 { counts.removeValue(forKey: path) }
            }
        }
    }
}

/// A cache file and the lease that protects it until every decode that needs it is done.
struct LeasedFile: Sendable {
    var url: URL
    var lease: FileLease
}

/// The encoded image file cache (ADR 0005, "`CoverFileStore`").
///
/// Files live at `<directory>/<serverID>/<ImageKey.fileStem>.<ext>`. Only
/// the app process writes and evicts. Eviction is least recently used by modification date
/// (touched on hits at most once a day), skips leased files, and brings the total to 90 % of
/// the cap.
public actor CoverFileStore {
    public nonisolated let directory: URL
    private let limit: Int
    private let now: @Sendable () -> Date
    private let leases = LeaseCounts()
    private var totalBytes = 0
    private var isScanned = false
    private var evictionTask: Task<Void, Never>?
    /// Bumped by ``removeServer(_:)``, so fetches started before it can't write.
    private var serverGenerations: [UUID: Int] = [:]
    /// The number of background evictions started, for tests.
    private(set) var evictionCount = 0

    static let extensions = ["webp", "jpg", "png", "heic", "gif", "img"]

    public init(directory: URL, limit: Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.limit = limit
        self.now = now
    }

    /// `Library/Caches/Images` in the App Group container, so the widget can read it, or the
    /// app's own caches directory when the App Group container is missing or not writable (as
    /// on an unsigned macOS build).
    public static func defaultDirectory(appGroup: String = AppSettings.appGroupIdentifier) -> URL {
        let fallback = URL.cachesDirectory.appending(path: "Images", directoryHint: .isDirectory)
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return fallback }
        let directory = container.appending(path: "Library/Caches/Images", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
            FileManager.default.isWritableFile(atPath: directory.path)
        else { return fallback }
        return directory
    }

    /// The total size of the cache files, in bytes.
    public var size: Int {
        scanIfNeeded()
        return totalBytes
    }

    /// Rescans the folder, resetting the size from what it finds (which picks up files the OS
    /// purged), and evicts down to 90 % of the cap if it is over. Run at launch and when the app
    /// enters the background.
    // TODO(#143): call at launch and from a background maintenance task.
    public func fullPass() {
        isScanned = true
        totalBytes = files().reduce(0) { $0 + $1.size }
        if totalBytes > limit { evict(toBytes: limit * 9 / 10) }
    }

    /// The file for `key` whatever its extension, leased, or `nil`.
    func lookup(_ key: ImageKey) -> LeasedFile? {
        scanIfNeeded()
        let folder = folder(for: key.serverID)
        for ext in Self.extensions {
            let url = folder.appending(path: "\(key.fileStem).\(ext)")
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else { continue }
            if let modified = values.contentModificationDate, now().timeIntervalSince(modified) > 86_400 {
                try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            }
            return LeasedFile(url: url, lease: lease(url))
        }
        return nil
    }

    /// The current generation of `serverID`'s folder; pass it to ``insert(moving:for:pathExtension:generation:)``.
    func generation(for serverID: UUID) -> Int {
        serverGenerations[serverID, default: 0]
    }

    /// Moves `file` into the store as `key`'s file and returns it leased. Throws
    /// `CancellationError` if the server was removed since `generation` was read.
    func insert(moving file: URL, for key: ImageKey, pathExtension: String, generation: Int) throws -> LeasedFile {
        guard generation == self.generation(for: key.serverID) else { throw CancellationError() }
        scanIfNeeded()
        let folder = folder(for: key.serverID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = Self.extensions.contains(pathExtension) ? pathExtension : "img"
        let destination = folder.appending(path: "\(key.fileStem).\(ext)")
        for other in Self.extensions {
            remove(folder.appending(path: "\(key.fileStem).\(other)"))
        }
        try FileManager.default.moveItem(at: file, to: destination)
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
        let leased = LeasedFile(url: destination, lease: lease(destination))
        totalBytes += Self.allocatedSize(destination)
        if totalBytes > limit, evictionTask == nil {
            evictionCount += 1
            evictionTask = Task(priority: .background) {
                self.evict(toBytes: self.limit * 9 / 10)
                self.evictionTask = nil
            }
        }
        return leased
    }

    /// Deletes one server's files, for example when its connection is removed.
    public func removeServer(_ serverID: UUID) {
        serverGenerations[serverID, default: 0] += 1
        scanIfNeeded()
        let folder = folder(for: serverID)
        let removed = files(in: folder).reduce(0) { $0 + $1.size }
        try? FileManager.default.removeItem(at: folder)
        totalBytes = max(0, totalBytes - removed)
    }

    /// Deletes a stored file that turned out not to decode.
    func discard(_ url: URL) {
        guard
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path
        else { return }
        remove(url)
    }

    /// Waits for a running background eviction, for tests.
    func waitForEviction() async {
        await evictionTask?.value
    }

    func isLeased(_ url: URL) -> Bool {
        leases.leasedPaths.contains(Self.leaseKey(url))
    }

    private func evict(toBytes target: Int) {
        let leased = leases.leasedPaths
        let listing = files()
        // Resync with the folder, which the OS may have purged since the last pass.
        totalBytes = listing.reduce(0) { $0 + $1.size }
        for file in listing.sorted(by: { $0.modified < $1.modified }) where totalBytes > target {
            guard !leased.contains(Self.leaseKey(file.url)) else { continue }
            remove(file.url)
        }
    }

    private func remove(_ url: URL) {
        let size = Self.allocatedSize(url)
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        totalBytes = max(0, totalBytes - size)
    }

    private func lease(_ url: URL) -> FileLease {
        leases.lease(Self.leaseKey(url))
    }

    private func scanIfNeeded() {
        if !isScanned { fullPass() }
    }

    private func folder(for serverID: UUID) -> URL {
        directory.appending(path: serverID.uuidString, directoryHint: .isDirectory)
    }

    private struct File {
        var url: URL
        var size: Int
        var modified: Date
    }

    private func files(in root: URL? = nil) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root ?? directory, includingPropertiesForKeys: keys)
        else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { return nil }
            return File(
                url: url, size: values.totalFileAllocatedSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private static func leaseKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private static func allocatedSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
    }
}
