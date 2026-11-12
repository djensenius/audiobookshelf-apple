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
    /// The standardized path of `directory`, the prefix of every lease key.
    private nonisolated let root: String
    private let limit: Int
    private let now: @Sendable () -> Date
    private let leases = LeaseCounts()
    private var totalBytes = 0
    private var isScanned = false
    private var evictionTask: Task<Void, Never>?
    /// The running pass (the first scan, a full pass or a background eviction), which later
    /// callers join, so two passes never act on the same listing.
    private var passTask: Task<Void, Never>?
    /// Whether a pass is listing the folder off the actor, so writes and touches meanwhile must
    /// be measured again once it's done.
    private var isListing = false
    /// Paths written, touched, retired or deleted while a listing ran.
    private var touchedDuringListing: Set<String> = []
    /// Bumped by ``removeServer(_:)``, so fetches started before it can't write.
    private var serverGenerations: [UUID: Int] = [:]
    /// The write each path holds, by lease key; absent (`0`) for files from an earlier launch.
    private var versions: [String: Int] = [:]
    private var nextVersion = 1
    /// The number of background evictions started, for tests.
    private(set) var evictionCount = 0
    /// The number of folder listings, for tests.
    private(set) var listingCount = 0
    /// Runs on the listing's thread once it has read the folder, for tests.
    private let listingHook: (@Sendable () -> Void)?

    static let extensions = ["webp", "jpg", "png", "heic", "gif", "img"]

    public init(directory: URL, limit: Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(directory: directory, limit: limit, now: now, listingHook: nil)
    }

    init(directory: URL, limit: Int, now: @escaping @Sendable () -> Date, listingHook: (@Sendable () -> Void)?) {
        self.directory = directory
        root = directory.standardizedFileURL.path
        self.limit = limit
        self.now = now
        self.listingHook = listingHook
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
        get async {
            await scanIfNeeded()
            return totalBytes
        }
    }

    /// Rescans the folder, resetting the size from what it finds (which picks up files the OS
    /// purged), deletes staging files left over 10 minutes ago by an interrupted write, and
    /// evicts down to 90 % of the cap if it is over. Run at launch and when the app enters the background.
    ///
    /// The folder is listed off the actor, so lookups and inserts aren't blocked meanwhile. If a
    /// pass is already running, this waits for it instead of starting another.
    // TODO(#143): call at launch and from a background maintenance task.
    public func fullPass() async {
        if let passTask { return await passTask.value }
        let task = Task {
            await self.runPass()
            self.passTask = nil
        }
        passTask = task
        await task.value
    }

    /// The file for `key` whatever its extension, leased, or `nil`.
    func lookup(_ key: ImageKey) async -> LeasedFile? {
        await scanIfNeeded()
        let folder = folder(for: key.serverID)
        for ext in Self.extensions {
            let url = folder.appending(path: "\(key.fileStem).\(ext)")
            guard !leases.isPendingDeletion(leaseKey(url)),
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                values.isRegularFile == true
            else { continue }
            if let modified = values.contentModificationDate, now().timeIntervalSince(modified) > 86_400 {
                try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
                touch(url)
            }
            return LeasedFile(url: url, lease: lease(url), version: versions[leaseKey(url), default: 0])
        }
        return nil
    }

    /// The file `locator` names, whatever its extension, in a store at `directory`, or `nil`, for a
    /// process that only reads the cache (the widget extension, ADR 0005). Unlike ``lookup(_:)``
    /// it neither leases nor touches the file, so the app may evict or replace it meanwhile:
    /// a reader that can't open it shows its placeholder.
    public static func cachedFile(for locator: CoverLocator, in directory: URL) -> URL? {
        let folder = directory.appending(path: locator.serverID.uuidString, directoryHint: .isDirectory)
        let stem = locator.fileStem
        for ext in extensions {
            let url = folder.appending(path: "\(stem).\(ext)")
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return url }
        }
        return nil
    }

    /// The current generation of `serverID`'s folder; pass it to ``insert(moving:for:pathExtension:generation:)``.
    func generation(for serverID: UUID) -> Int {
        serverGenerations[serverID, default: 0]
    }

    /// Moves `file` into the store as `key`'s file and returns it leased. Throws
    /// `CancellationError` if the server was removed since `generation` was read. On any error
    /// `file` is left where it was, so the caller can still use it.
    ///
    /// The new file replaces the old one atomically, and only once it is complete; copies under
    /// other extensions are deleted afterwards, each once its last lease is released.
    func insert(
        moving file: URL, for key: ImageKey, pathExtension: String, generation: Int
    ) async throws -> LeasedFile {
        await scanIfNeeded()
        // Checked after the scan, which may have let a removal of the server run.
        guard generation == self.generation(for: key.serverID) else { throw CancellationError() }
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
        let wasRetired = leases.cancelDeletion(leaseKey(destination))
        let replacedBytes = wasRetired ? 0 : Self.allocatedSize(destination)
        let addedBytes = Self.allocatedSize(staging)
        guard rename(staging.path, destination.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if rename(staging.path, file.path) != 0 { try? FileManager.default.removeItem(at: staging) }
            if wasRetired { leases.deleteWhenUnleased(leaseKey(destination)) }
            throw error
        }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
        touch(destination)
        let version = nextVersion
        nextVersion += 1
        versions[leaseKey(destination)] = version
        let leased = LeasedFile(url: destination, lease: lease(destination), version: version)
        totalBytes += addedBytes - replacedBytes
        for other in Self.extensions where other != ext {
            retire(folder.appending(path: "\(key.fileStem).\(other)"))
        }
        if totalBytes > limit, evictionTask == nil {
            evictionCount += 1
            evictionTask = Task(priority: .background) {
                await self.fullPass()
                self.evictionTask = nil
            }
        }
        return leased
    }

    /// Deletes one server's files, for example when its connection is removed.
    public func removeServer(_ serverID: UUID) {
        serverGenerations[serverID, default: 0] += 1
        let folder = folder(for: serverID)
        let removed = Self.listing(of: folder, root: root, leases: leases).files.reduce(0) { $0 + $1.size }
        try? FileManager.default.removeItem(at: folder)
        // A pass listing the folder meanwhile drops these files itself, by their generation.
        if isScanned { totalBytes = max(0, totalBytes - removed) }
        let prefix = "\(root)/\(serverID.uuidString)/"
        versions = versions.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Deletes a stored file that turned out not to decode, once its readers are done, but only
    /// if `url` still holds `version`: a newer write there is a healthy replacement, which a
    /// stale reader's failure must not delete.
    func discard(_ url: URL, version: Int) {
        guard
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path,
            versions[leaseKey(url), default: 0] == version
        else { return }
        retire(url)
    }

    /// Waits for a running background eviction, for tests.
    func waitForEviction() async {
        await evictionTask?.value
    }

    func isLeased(_ url: URL) -> Bool {
        leases.leasedPaths.contains(leaseKey(url))
    }

    /// Resyncs the size with the folder, which the OS may have purged since the last pass, and
    /// evicts down to 90 % of the cap if it is over. Only ``fullPass()`` runs it, one at a time.
    private func runPass() async {
        let generations = serverGenerations
        isListing = true
        listingCount += 1
        let listing = await Self.listFolder(directory, root: root, leases: leases, hook: listingHook)
        isListing = false
        let touched = touchedDuringListing
        touchedDuringListing = []
        // This store stages and renames a write within one actor call, but another process
        // sharing the App Group container could be mid-write, so only old ones are deleted.
        for (url, modified) in listing.partials where now().timeIntervalSince(modified) > 600 {
            try? FileManager.default.removeItem(at: url)
        }
        // Servers removed while the folder was listed have no files left to count.
        var files = listing.files.filter { file in
            let server = UUID(uuidString: file.url.deletingLastPathComponent().lastPathComponent)
            let wasRemoved = server.map { serverGenerations[$0, default: 0] != generations[$0, default: 0] } ?? false
            return !wasRemoved && !touched.contains(file.key)
        }
        files += touched.compactMap { Self.file(at: URL(filePath: $0), root: root, leases: leases) }
        isScanned = true
        totalBytes = files.reduce(0) { $0 + $1.size }
        guard totalBytes > limit else { return }
        // Read after the listing, so leases taken while it ran are kept.
        let leased = leases.leasedPaths
        for file in files.sorted(by: { $0.modified < $1.modified }) where totalBytes > limit * 9 / 10 {
            guard !leased.contains(file.key) else { continue }
            remove(file)
        }
    }

    /// Deletes `url` now, or once its last lease is released. Lookups skip it meanwhile, and it
    /// no longer counts towards the cap.
    private func retire(_ url: URL) {
        let path = leaseKey(url)
        guard FileManager.default.fileExists(atPath: path), !leases.isPendingDeletion(path) else { return }
        touch(url)
        totalBytes = max(0, totalBytes - Self.allocatedSize(url))
        leases.deleteWhenUnleased(path)
    }

    /// Deletes a listed file, unless it was replaced or retired since the listing. A file that
    /// is already gone stops counting too.
    private func remove(_ file: File) {
        guard !leases.isPendingDeletion(file.key) else { return }
        var url = file.url
        url.removeAllCachedResourceValues()
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            guard values.contentModificationDate == file.modified,
                (try? FileManager.default.removeItem(at: url)) != nil
            else { return }
        }
        totalBytes = max(0, totalBytes - file.size)
        versions[file.key] = nil
        if isListing { touchedDuringListing.insert(file.key) }
    }

    private func touch(_ url: URL) {
        if isListing { touchedDuringListing.insert(leaseKey(url)) }
    }

    private func lease(_ url: URL) -> FileLease {
        leases.lease(leaseKey(url))
    }

    private func scanIfNeeded() async {
        if !isScanned { await fullPass() }
    }

    private func folder(for serverID: UUID) -> URL {
        directory.appending(path: serverID.uuidString, directoryHint: .isDirectory)
    }

    private struct File: Sendable {
        var url: URL
        var key: String
        var size: Int
        var modified: Date
    }

    /// The files under a folder, and the staging files of writes, which don't count.
    private struct Listing: Sendable {
        var files: [File] = []
        var partials: [(url: URL, modified: Date)] = []
    }

    /// The whole cache, listed off the actor.
    @concurrent
    private static func listFolder(
        _ folder: URL, root: String, leases: LeaseCounts, hook: (@Sendable () -> Void)?
    ) async -> Listing {
        let listing = listing(of: folder, root: root, leases: leases)
        hook?()
        return listing
    }

    /// The cache files, without those retired and waiting for their lease to be released, which
    /// ``retire(_:)`` has already taken out of `totalBytes`, and without hidden files.
    private static func listing(of folder: URL, root: String, leases: LeaseCounts) -> Listing {
        var listing = Listing()
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: fileKeys)
        else { return listing }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(".partial") {
                    let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    listing.partials.append((url, modified ?? .distantPast))
                }
            } else if let file = file(at: url, root: root, leases: leases) {
                listing.files.append(file)
            }
        }
        return listing
    }

    private static let fileKeys: [URLResourceKey] = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// The cache file at `url`, or `nil` if it's missing or retired.
    private static func file(at url: URL, root: String, leases: LeaseCounts) -> File? {
        let key = leaseKey(url, root: root)
        guard let values = try? url.resourceValues(forKeys: Set(fileKeys)), values.isRegularFile == true,
            !leases.isPendingDeletion(key)
        else { return nil }
        return File(
            url: url, key: key, size: values.totalFileAllocatedSize ?? 0,
            modified: values.contentModificationDate ?? .distantPast)
    }

    private func leaseKey(_ url: URL) -> String {
        Self.leaseKey(url, root: root)
    }

    /// A file's key in ``LeaseCounts``, also the path it deletes. Every cache file is at
    /// `<serverID>/<name>` under the root, so the key is built from those two components and the
    /// root, never from the file system: resolving symlinks gives a different path once a file is
    /// deleted (`/private/var` versus `/var`), so keys taken before and after would differ.
    private static func leaseKey(_ url: URL, root: String) -> String {
        "\(root)/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }

    /// Measured fresh: a `URL` caches resource values, and its file may have been replaced since.
    private static func allocatedSize(_ url: URL) -> Int {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
    }
}
