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
        /// Callers of ``waitUntilUnleased(under:)``, by id, with the path prefix they wait for.
        var waiters: [Int: (prefix: String, continuation: CheckedContinuation<Void, Never>)] = [:]
        var nextWaiter = 0

        func isLeased(under prefix: String) -> Bool {
            counts.keys.contains { $0.hasPrefix(prefix) }
        }
    }

    private let state = Mutex(State())

    var leasedPaths: Set<String> { state.withLock { Set($0.counts.keys) } }

    func isPendingDeletion(_ path: String) -> Bool {
        state.withLock { $0.pendingDeletion.contains(path) }
    }

    func isLeased(under prefix: String) -> Bool {
        state.withLock { $0.isLeased(under: prefix) }
    }

    /// The files under `prefix` waiting for their last lease before they are deleted.
    func pendingDeletions(under prefix: String) -> Set<String> {
        state.withLock { $0.pendingDeletion.filter { $0.hasPrefix(prefix) } }
    }

    func lease(_ path: String) -> FileLease {
        state.withLock { $0.counts[path, default: 0] += 1 }
        return FileLease { [self] in
            let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.counts[path, default: 1] -= 1
                guard state.counts[path] == 0 else { return [] }
                state.counts.removeValue(forKey: path)
                // Deleted under the lock, so an insert can't publish a new file here first.
                if state.pendingDeletion.remove(path) != nil { try? FileManager.default.removeItem(atPath: path) }
                let done = state.waiters.filter { !state.isLeased(under: $0.value.prefix) }
                for id in done.keys { state.waiters[id] = nil }
                return done.values.map(\.continuation)
            }
            for waiter in ready { waiter.resume() }
        }
    }

    /// Returns once no file under `prefix` is leased, or when the task is cancelled.
    func waitUntilUnleased(under prefix: String) async {
        let id = state.withLock { state in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumesNow = state.withLock { state in
                    // Checked under the lock the cancellation handler takes, so one of them resumes.
                    guard !Task.isCancelled, state.isLeased(under: prefix) else { return true }
                    state.waiters[id] = (prefix, continuation)
                    return false
                }
                if resumesNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
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
    /// Bumped by ``removeServer(_:)`` once it has moved the server's folder aside. Until then
    /// (through the lease wait) the folder's files stay counted, so a pass drops a server's files
    /// only if its folder moved while the pass ran, and ``retire(_:)`` subtracts a file exactly
    /// once whenever it runs.
    private var folderMoves: [UUID: Int] = [:]
    /// The write each path holds, by lease key; absent (`0`) for files from an earlier launch.
    private var versions: [String: Int] = [:]
    private var nextVersion = 1
    /// The number of background evictions started, for tests.
    private(set) var evictionCount = 0
    /// The number of folder listings, for tests.
    private(set) var listingCount = 0
    /// The ``folderMoves`` the last pass to set the size finished with (it dropped the files of
    /// each server whose count changed while it listed). A removal subtracts its folder only if
    /// it moved it after that pass finished.
    private var lastPassMoves: [UUID: Int]?
    /// Folders moved aside by ``removeServer(_:)`` and still being deleted, which a pass leaves
    /// alone; any other is left over from a removal the app was terminated in.
    private var removingFolders: Set<String> = []
    /// Runs on the listing's thread once it has read the folder, for tests.
    private let listingHook: (@Sendable () -> Void)?
    /// Runs on the deleting thread before a removed server's folder is measured, for tests.
    private let deletionHook: (@Sendable () -> Void)?
    /// Awaited at the start of every ``insert(moving:for:pathExtension:generation:)``, for tests.
    private let insertHook: (@Sendable () async -> Void)?
    /// How long ``removeServer(_:)`` waits for the server's leases: it returns when the leases
    /// are released or this returns, whichever comes first.
    private let leaseTimeout: @Sendable () async throws -> Void

    static let extensions = ["webp", "jpg", "png", "heic", "gif", "img"]

    public init(directory: URL, limit: Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(directory: directory, limit: limit, now: now, listingHook: nil)
    }

    init(
        directory: URL, limit: Int, now: @escaping @Sendable () -> Date, listingHook: (@Sendable () -> Void)?,
        deletionHook: (@Sendable () -> Void)? = nil, insertHook: (@Sendable () async -> Void)? = nil,
        leaseTimeout: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }
    ) {
        self.directory = directory
        root = directory.standardizedFileURL.path
        self.limit = limit
        self.now = now
        self.listingHook = listingHook
        self.deletionHook = deletionHook
        self.insertHook = insertHook
        self.leaseTimeout = leaseTimeout
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
        await insertHook?()
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
    ///
    /// Writes started before this call are refused at once. It then waits for the server's
    /// leases (decodes reading its files) to be released, for at most a few seconds, so a decode
    /// in progress isn't left without its input; past that the files are deleted anyway, which
    /// open readers survive. The folder is then moved aside, so later lookups miss and later
    /// writes start a fresh folder, and is measured and deleted off the actor. A folder that
    /// can't be moved aside isn't deleted.
    public func removeServer(_ serverID: UUID) async {
        serverGenerations[serverID, default: 0] += 1
        let prefix = "\(root)/\(serverID.uuidString)/"
        await waitForLeases(under: prefix)
        let folder = folder(for: serverID)
        let removing = directory.appending(path: ".\(serverID.uuidString).\(UUID().uuidString).removing")
        // Read before the move: `retire` has already subtracted these, and a lease released
        // after the move would forget them while the file is still in the moved folder.
        let retired = leases.pendingDeletions(under: prefix)
        let isMoved = rename(folder.path, removing.path) == 0
        // Refuses writes whose generation was read during the lease wait.
        serverGenerations[serverID, default: 0] += 1
        versions = versions.filter { !$0.key.hasPrefix(prefix) }
        // Only a folder moved aside is deleted. If the move failed (no folder, or refused), the
        // path is still the live one, which a fresh-generation write may recreate and lease while
        // a deletion is suspended. Files left behind stay counted, and `removeServers(keepingOnly:)`
        // sweeps them in a later launch.
        guard isMoved else { return }
        // A pass listing the folder meanwhile drops these files itself, by their move count.
        folderMoves[serverID, default: 0] += 1
        let moved = folderMoves[serverID, default: 0]
        removingFolders.insert(removing.lastPathComponent)
        let removed = await Self.deleteFolder(
            removing, as: serverID, root: root, excluding: retired, hook: deletionHook)
        removingFolders.remove(removing.lastPathComponent)
        // Only if the size still counts these files: the last pass finished before this move
        // (even during the lease wait). A pass that finished after it dropped them for the move,
        // or never listed them. One that spanned an earlier move dropped only that folder's
        // files; those written since are counted.
        if let lastPassMoves, lastPassMoves[serverID, default: 0] < moved {
            totalBytes = max(0, totalBytes - removed)
        }
    }

    /// Deletes the folder of every server not in `kept`, for example of connections removed in
    /// an earlier launch whose covers weren't deleted then (#421). Lists the folder off the actor
    /// first; `willRemove` is asked about each server just before its folder is deleted, and
    /// keeps it by returning `false`. Returns the servers removed.
    @discardableResult
    public func removeServers(
        keepingOnly kept: Set<UUID>, willRemove: @Sendable (UUID) async -> Bool = { _ in true }
    ) async -> Set<UUID> {
        var removed: Set<UUID> = []
        for serverID in await servers(notIn: kept) {
            guard await willRemove(serverID) else { continue }
            await removeServer(serverID)
            removed.insert(serverID)
        }
        return removed
    }

    /// The servers with a folder here that aren't in `kept`, listed off the actor.
    public func servers(notIn kept: Set<UUID>) async -> Set<UUID> {
        await Self.serverFolders(in: directory, hook: listingHook).subtracting(kept)
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
        let moves = folderMoves
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
        // Servers whose folder was moved aside while the folder was listed have no files left to
        // count; a path touched before the move no longer exists, so it isn't measured again.
        var files = listing.files.filter { file in
            moveCount(of: file.key) == moveCount(of: file.key, in: moves) && !touched.contains(file.key)
        }
        files += touched.compactMap { Self.file(at: URL(filePath: $0), root: root, leases: leases) }
        isScanned = true
        totalBytes = files.reduce(0) { $0 + $1.size }
        lastPassMoves = folderMoves
        if totalBytes > limit {
            // Read after the listing, so leases taken while it ran are kept.
            let leased = leases.leasedPaths
            for file in files.sorted(by: { $0.modified < $1.modified }) where totalBytes > limit * 9 / 10 {
                guard !leased.contains(file.key) else { continue }
                remove(file)
            }
        }
        // Folders a removal moved aside but was terminated before deleting. Last, so nothing
        // waits between the listing and the size.
        let leftovers = listing.removing.filter { !removingFolders.contains($0.lastPathComponent) }
        if !leftovers.isEmpty { await Self.deleteFolders(leftovers) }
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

    /// Waits until no file under `prefix` is leased, or until ``leaseTimeout`` returns.
    private func waitForLeases(under prefix: String) async {
        guard leases.isLeased(under: prefix) else { return }
        let (leases, timeout) = (self.leases, leaseTimeout)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await leases.waitUntilUnleased(under: prefix) }
            group.addTask { try? await timeout() }
            await group.next()
            group.cancelAll()
        }
    }

    private func touch(_ url: URL) {
        if isListing { touchedDuringListing.insert(leaseKey(url)) }
    }

    /// The ``folderMoves`` count (or `moves`') of the server whose folder holds the file at
    /// lease key `path`; `0` for a file outside a server folder.
    private func moveCount(of path: String, in moves: [UUID: Int]? = nil) -> Int {
        let folder = URL(filePath: path).deletingLastPathComponent().lastPathComponent
        guard let server = UUID(uuidString: folder) else { return 0 }
        return (moves ?? folderMoves)[server, default: 0]
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

    /// The files under a folder, the staging files of writes, which don't count, and the folders
    /// of removed servers moved aside for deletion.
    private struct Listing: Sendable {
        var files: [File] = []
        var partials: [(url: URL, modified: Date)] = []
        var removing: [URL] = []
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

    /// The servers with a folder in the cache, listed off the actor.
    @concurrent
    private static func serverFolders(in directory: URL, hook: (@Sendable () -> Void)?) async -> Set<UUID> {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        hook?()
        return Set(
            urls.compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return UUID(uuidString: url.lastPathComponent)
            })
    }

    /// Measures and deletes a removed server's folder off the actor. The `retired` files, waiting
    /// for their lease, aren't counted: ``retire(_:)`` has already taken them out of `totalBytes`.
    @concurrent
    private static func deleteFolder(
        _ folder: URL, as serverID: UUID, root: String, excluding retired: Set<String>,
        hook: (@Sendable () -> Void)?
    ) async -> Int {
        hook?()
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: fileKeys)) ?? []
        let size = urls.reduce(0) { total, url in
            // Keyed by the server's own folder, where its leases were taken.
            let key = "\(root)/\(serverID.uuidString)/\(url.lastPathComponent)"
            guard !url.lastPathComponent.hasPrefix("."), !retired.contains(key),
                let values = try? url.resourceValues(forKeys: Set(fileKeys)), values.isRegularFile == true
            else { return total }
            return total + (values.totalFileAllocatedSize ?? 0)
        }
        try? FileManager.default.removeItem(at: folder)
        return size
    }

    @concurrent
    private static func deleteFolders(_ folders: [URL]) async {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    /// The cache files, without those retired and waiting for their lease to be released, which
    /// ``retire(_:)`` has already taken out of `totalBytes`, and without hidden files or folders.
    private static func listing(of folder: URL, root: String, leases: LeaseCounts) -> Listing {
        var listing = Listing()
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: fileKeys)
        else { return listing }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                // A removed server's folder, moved aside, is deleted whole and never counted.
                enumerator.skipDescendants()
                if name.hasSuffix(".partial") {
                    let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    listing.partials.append((url, modified ?? .distantPast))
                } else if name.hasSuffix(".removing") {
                    listing.removing.append(url)
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
