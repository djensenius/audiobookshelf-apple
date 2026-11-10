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

/// Per-file lease counts, readable from any thread, and the files waiting for their last lease
/// to be released before they are deleted.
private final class LeaseCounts: Sendable {
    private struct State {
        var counts: [String: Int] = [:]
        var pendingDeletion: Set<String> = []
    }

    private let state = Mutex(State())

    var leasedPaths: Set<String> { state.withLock { Set($0.counts.keys) } }

    func isPendingDeletion(_ path: String) -> Bool {
        state.withLock { $0.pendingDeletion.contains(path) }
    }

    func lease(_ path: String) -> FileLease {
        state.withLock { $0.counts[path, default: 0] += 1 }
        return FileLease { [self] in
            state.withLock { state in
                state.counts[path, default: 1] -= 1
                guard state.counts[path] == 0 else { return }
                state.counts.removeValue(forKey: path)
                // Deleted under the lock, so an insert can't publish a new file here first.
                if state.pendingDeletion.remove(path) != nil { try? FileManager.default.removeItem(atPath: path) }
            }
        }
    }

    /// Deletes `path` now, or once its last lease is released.
    func deleteWhenUnleased(_ path: String) {
        state.withLock { state in
            if state.counts[path] != nil {
                state.pendingDeletion.insert(path)
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Keeps `path` from a pending deletion; returns whether one was pending.
    func cancelDeletion(_ path: String) -> Bool {
        state.withLock { $0.pendingDeletion.remove(path) != nil }
    }
}

/// A cache file and the lease that protects it until every decode that needs it is done.
struct LeasedFile: Sendable {
    var url: URL
    var lease: FileLease
    /// The write that produced the file at `url`; pass it to ``CoverFileStore/discard(_:version:)``.
    var version: Int
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
    /// The write each path holds, by lease key; absent (`0`) for files from an earlier launch.
    private var versions: [String: Int] = [:]
    private var nextVersion = 1
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
            guard !leases.isPendingDeletion(Self.leaseKey(url)),
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            else { continue }
            if let modified = values.contentModificationDate, now().timeIntervalSince(modified) > 86_400 {
                try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            }
            return LeasedFile(url: url, lease: lease(url), version: versions[Self.leaseKey(url), default: 0])
        }
        return nil
    }

    /// The current generation of `serverID`'s folder; pass it to ``insert(moving:for:pathExtension:generation:)``.
    func generation(for serverID: UUID) -> Int {
        serverGenerations[serverID, default: 0]
    }

    /// Moves `file` into the store as `key`'s file and returns it leased. Throws
    /// `CancellationError` if the server was removed since `generation` was read.
    ///
    /// The new file replaces the old one atomically, and only once it is complete; copies under
    /// other extensions are deleted afterwards, each once its last lease is released.
    func insert(moving file: URL, for key: ImageKey, pathExtension: String, generation: Int) throws -> LeasedFile {
        guard generation == self.generation(for: key.serverID) else { throw CancellationError() }
        scanIfNeeded()
        let folder = folder(for: key.serverID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = Self.extensions.contains(pathExtension) ? pathExtension : "img"
        let destination = folder.appending(path: "\(key.fileStem).\(ext)")
        // Staged beside the destination, so the final rename is atomic.
        let staging = folder.appending(path: ".\(UUID().uuidString).partial")
        do {
            try FileManager.default.moveItem(at: file, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        // A retired copy at the destination is replaced rather than deleted on release.
        let wasRetired = leases.cancelDeletion(Self.leaseKey(destination))
        let replacedBytes = wasRetired ? 0 : Self.allocatedSize(destination)
        let addedBytes = Self.allocatedSize(staging)
        guard rename(staging.path, destination.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: staging)
            if wasRetired { leases.deleteWhenUnleased(Self.leaseKey(destination)) }
            throw error
        }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
        let version = nextVersion
        nextVersion += 1
        versions[Self.leaseKey(destination)] = version
        let leased = LeasedFile(url: destination, lease: lease(destination), version: version)
        totalBytes += addedBytes - replacedBytes
        for other in Self.extensions where other != ext {
            retire(folder.appending(path: "\(key.fileStem).\(other)"))
        }
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
        let prefix = Self.leaseKey(folder) + "/"
        versions = versions.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Deletes a stored file that turned out not to decode, once its readers are done, but only
    /// if `url` still holds `version`: a newer write there is a healthy replacement, which a
    /// stale reader's failure must not delete.
    func discard(_ url: URL, version: Int) {
        guard
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path,
            versions[Self.leaseKey(url), default: 0] == version
        else { return }
        retire(url)
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

    /// Deletes `url` now, or once its last lease is released. Lookups skip it meanwhile, and it
    /// no longer counts towards the cap.
    private func retire(_ url: URL) {
        let path = Self.leaseKey(url)
        guard FileManager.default.fileExists(atPath: path), !leases.isPendingDeletion(path) else { return }
        totalBytes = max(0, totalBytes - Self.allocatedSize(url))
        leases.deleteWhenUnleased(path)
    }

    private func remove(_ url: URL) {
        let size = Self.allocatedSize(url)
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        totalBytes = max(0, totalBytes - size)
        versions[Self.leaseKey(url)] = nil
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

    /// The cache files, without those retired and waiting for their lease to be released, which
    /// ``retire(_:)`` has already taken out of `totalBytes`.
    private func files(in root: URL? = nil) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root ?? directory, includingPropertiesForKeys: keys)
        else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, !leases.isPendingDeletion(Self.leaseKey(url))
            else { return nil }
            return File(
                url: url, size: values.totalFileAllocatedSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private static func leaseKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Measured fresh: a `URL` caches resource values, and its file may have been replaced since.
    private static func allocatedSize(_ url: URL) -> Int {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
    }
}
