import ABSCore
import ABSData
import Foundation

/// What ``DownloadJanitor/sweep()`` did.
public struct SweepReport: Sendable, Equatable {
    /// How a sweep ended.
    public enum Outcome: Sendable, Equatable {
        /// Every step ran.
        case completed
        /// Nothing ran (see ``SkipReason``).
        case skipped(SkipReason)
        /// A read failed during this step, so the sweep stopped there; what it removed before
        /// that is listed.
        case aborted(Step)
    }

    public enum SkipReason: Sendable, Equatable {
        /// The store isn't the App Group store (ADR 0003): a fallback or test store doesn't
        /// hold the app's downloads, so every file would look orphaned.
        case notAppGroupStore
        /// Another sweep is running.
        case alreadySweeping
    }

    /// The reads a sweep makes, in order.
    public enum Step: Sendable, Equatable {
        case listingFiles
        case readingRecords
        case readingLocalItems
        case readingConnections
        /// Reading an item's records and local item again while it is held, before removing
        /// its orphaned files.
        case readingItem
        /// Deleting a record or local item of a connection that no longer exists.
        case deletingOrphanedMedia
    }

    public var outcome: Outcome
    /// Files no local item or record referred to, relative to the downloads root.
    public var removedFiles: [String] = []
    /// Unreferenced files kept because they changed within ``DownloadJanitor/recentInterval``.
    public var keptRecentFiles: [String] = []
    /// Empty folders removed, relative to the downloads root.
    public var removedFolders: [String] = []
    /// Parts whose orphaned resume data was deleted.
    public var removedResumeData: [UUID] = []
    /// Download records of connections that no longer exist.
    public var removedRecords: [UUID] = []
    /// Local items of connections that no longer exist.
    public var removedItems: [UUID] = []
    /// Disconnected connections that had nothing left and were deleted.
    public var removedConnections: [UUID] = []

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

/// Removes what downloads leave behind: files nothing refers to, empty folders, resume data of
/// parts that are gone, media of connections that are gone, and disconnected connections with
/// nothing left. Run it when the app becomes active, after the engine's `activate()`.
///
/// A sweep:
/// 1. lists the files, folders and resume-data blobs first, then reads the records, the local
///    items and the connections, in that order. A file only appears after its record is saved,
///    and the engine finalises a record into a local item before it deletes the record, so
///    every listed file in use is referred to by at least one of the reads;
/// 2. removes listed files that no record part, local file or cover refers to. Files changed
///    within ``recentInterval`` stay: one a settling part moved in after its record was
///    cancelled is removed by a later sweep. Files in an item's folder are removed while the
///    ``DownloadManager`` holds the item, after reading its records and local item again, so an
///    enqueue, cancel or deletion of it (which can hand a stored cover to another record)
///    can't interleave;
/// 3. removes empty folders that are older than ``recentInterval`` or that step 2 emptied: a
///    folder the engine just created for a file it is about to move in stays;
/// 4. deletes `ResumeData/<part id>.bin` blobs whose part no record has (and that are older
///    than ``recentInterval``);
/// 5. deletes the records, then the local items, of connections that no longer exist, with
///    their files, through the ``DownloadManager``;
/// 6. calls `ServerConnectionStore.remove(id:)` again for each disconnected connection with no
///    record or local item left, which deletes it unless something else still refers to it.
///
/// When a read fails, the sweep stops and reports it: it never deletes on a partial view.
/// It only runs against the App Group store (ADR 0003); any other store location (the
/// fallback store of a process without the entitlement, or a test store) skips it, because
/// that store doesn't refer to the app's downloads.
public actor DownloadJanitor {
    /// How long a changed file or folder is left alone: 10 minutes.
    public static let recentInterval: TimeInterval = 10 * 60

    private let manager: DownloadManager
    private let connections: ServerConnectionStore
    private let storeLocation: DataStack.Location
    private let now: @Sendable () -> Date
    /// A test seam: runs before each read, and its error fails that read.
    private let beforeRead: (@Sendable (SweepReport.Step) async throws -> Void)?
    private var isSweeping = false

    /// - Parameters:
    ///   - manager: the app's manager; its store, local items and locations are swept.
    ///   - connections: the store of server connections.
    ///   - storeLocation: where the store was opened (`DataStack.resolvedLocation`); only
    ///     `.appGroup` is swept.
    ///   - now: the current time, for ``recentInterval``.
    public init(
        manager: DownloadManager,
        connections: ServerConnectionStore,
        storeLocation: DataStack.Location,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            manager: manager, connections: connections, storeLocation: storeLocation, now: now, beforeRead: nil)
    }

    init(
        manager: DownloadManager,
        connections: ServerConnectionStore,
        storeLocation: DataStack.Location,
        now: @escaping @Sendable () -> Date,
        beforeRead: (@Sendable (SweepReport.Step) async throws -> Void)?
    ) {
        self.manager = manager
        self.connections = connections
        self.storeLocation = storeLocation
        self.now = now
        self.beforeRead = beforeRead
    }

    /// Runs one sweep (see ``DownloadJanitor``). A call while another runs is skipped.
    public func sweep() async -> SweepReport {
        guard storeLocation == .appGroup else { return SweepReport(outcome: .skipped(.notAppGroupStore)) }
        guard !isSweeping else { return SweepReport(outcome: .skipped(.alreadySweeping)) }
        isSweeping = true
        defer { isSweeping = false }
        var report = SweepReport(outcome: .completed)
        do throws(SweepAbort) {
            try await run(&report)
        } catch {
            report.outcome = .aborted(error.step)
        }
        return report
    }

    // MARK: - Steps

    private func run(_ report: inout SweepReport) async throws(SweepAbort) {
        let locations = manager.locations
        let cutoff = now().addingTimeInterval(-Self.recentInterval)
        // 1. Files first, then the store. Connections last: a record of a connection created
        // after this read of the records isn't read, so it can't look orphaned.
        let listing = try await read(.listingFiles) { try Self.list(locations) }
        let records = try await read(.readingRecords) { try await self.manager.store.allRecords() }
        let items = try await read(.readingLocalItems) { try await self.manager.localItems.allItems() }
        let connections = try await read(.readingConnections) { try await self.connections.allConnections() }

        // 2. Orphaned files.
        var referenced = Set(records.flatMap(\.parts).map { DownloadLayout.collisionKey($0.destinationRelativePath) })
        for item in items {
            referenced.formUnion(item.files.map { DownloadLayout.collisionKey($0.relativePath) })
            if let cover = item.coverRelativePath { referenced.insert(DownloadLayout.collisionKey(cover)) }
        }
        // The folders of items the store knows, whose files are removed while the item is held.
        var itemFolders: [String: MediaKey] = [:]
        let itemKeys =
            records.map { MediaKey(serverConnectionID: $0.key.serverConnectionID, libraryItemId: $0.key.libraryItemId) }
            + items.map { MediaKey(serverConnectionID: $0.serverConnectionID, libraryItemId: $0.libraryItemId) }
        for key in itemKeys {
            guard
                let folder = try? DownloadLayout(
                    connectionID: key.serverConnectionID, libraryItemID: key.libraryItemId, locations: locations
                ).folder
            else { continue }
            itemFolders[DownloadLayout.collisionKey(folder)] = key
        }
        var unheld: [String] = []
        var byItem: [MediaKey: [String]] = [:]
        for file in listing.files where !referenced.contains(DownloadLayout.collisionKey(file.path)) {
            guard let modified = file.modified, modified < cutoff else {
                report.keptRecentFiles.append(file.path)
                continue
            }
            if let key = itemFolders[DownloadLayout.collisionKey(Self.itemFolder(of: file.path))] {
                byItem[key, default: []].append(file.path)
            } else {
                unheld.append(file.path)
            }
        }
        report.removedFiles += unheld.filter { Self.remove(try? locations.fileURL(forRelativePath: $0)) }
        for (key, paths) in byItem.sorted(by: { $0.value[0] < $1.value[0] }) {
            report.removedFiles += try await read(.readingItem) { try await self.manager.removeUnused(paths, of: key) }
        }

        // 3. Empty folders.
        report.removedFolders = Self.removeEmptyFolders(
            listing.directories, emptied: report.removedFiles, before: cutoff, locations: locations)

        // 4. Resume data of parts that are gone.
        let parts = Set(records.flatMap(\.parts).map(\.id))
        for blob in listing.blobs where !parts.contains(blob.partID) {
            guard let modified = blob.modified, modified < cutoff else { continue }
            if Self.remove(blob.url) { report.removedResumeData.append(blob.partID) }
        }

        // 5. Media of connections that are gone: records first, so a deleted item's cover isn't
        // handed to a record about to go.
        let connectionIDs = Set(connections.map(\.id))
        for record in records where !connectionIDs.contains(record.key.serverConnectionID) {
            if try await read(.deletingOrphanedMedia, { try await self.manager.purgeRecord(id: record.id) }) {
                report.removedRecords.append(record.id)
            }
        }
        for item in items where !connectionIDs.contains(item.serverConnectionID) {
            if try await read(.deletingOrphanedMedia, { try await self.manager.deleteLocalItem(id: item.id) }) {
                report.removedItems.append(item.id)
            }
        }

        // 6. Disconnected connections with nothing left.
        let inUse = Set(records.map(\.key.serverConnectionID)).union(items.map(\.serverConnectionID))
        for connection in connections where connection.isDisconnected && !inUse.contains(connection.id) {
            do {
                if try await self.connections.remove(id: connection.id) == .deleted {
                    report.removedConnections.append(connection.id)
                }
            } catch {
                Log.downloads.error(
                    "Couldn't remove a disconnected connection: \(Log.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }

    private struct SweepAbort: Error {
        var step: SweepReport.Step
    }

    /// Runs a read; any error stops the sweep.
    private func read<T: Sendable>(
        _ step: SweepReport.Step, _ body: () async throws -> T
    ) async throws(SweepAbort) -> T {
        do {
            try await beforeRead?(step)
            return try await body()
        } catch {
            Log.downloads.error(
                "The download sweep stopped: \(String(describing: step), privacy: .public): \(Log.redact(String(describing: error)), privacy: .public)"
            )
            throw SweepAbort(step: step)
        }
    }

    // MARK: - Files

    private struct Entry: Sendable {
        /// Relative to the downloads root.
        var path: String
        var modified: Date?
    }

    private struct Blob: Sendable {
        var partID: UUID
        var url: URL
        var modified: Date?
    }

    private struct Listing: Sendable {
        var files: [Entry] = []
        var directories: [Entry] = []
        var blobs: [Blob] = []
    }

    /// Everything below the downloads root, and the resume-data blobs. A root that doesn't exist
    /// is empty; any other error throws.
    private static func list(_ locations: DownloadLocations) throws -> Listing {
        var listing = Listing()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        for (url, values) in try contents(of: locations.downloadsRoot, recursive: true, keys: keys) {
            let rootComponents = locations.downloadsRoot.standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count, components.starts(with: rootComponents) else { continue }
            let entry = Entry(
                path: components.dropFirst(rootComponents.count).joined(separator: "/"),
                modified: values.contentModificationDate)
            if values.isDirectory == true {
                listing.directories.append(entry)
            } else {
                listing.files.append(entry)
            }
        }
        for (url, values) in try contents(of: locations.resumeDataRoot, recursive: false, keys: keys)
        where values.isDirectory != true && url.pathExtension == "bin" {
            guard let partID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            listing.blobs.append(Blob(partID: partID, url: url, modified: values.contentModificationDate))
        }
        return listing
    }

    private static func contents(
        of directory: URL, recursive: Bool, keys: [URLResourceKey]
    ) throws -> [(URL, URLResourceValues)] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        var failure: (any Error)?
        let options: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
        guard
            let enumerator = manager.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: options,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw CocoaError(.fileReadUnknown) }
        var entries: [(URL, URLResourceValues)] = []
        for case let url as URL in enumerator {
            entries.append((url, try url.resourceValues(forKeys: Set(keys))))
        }
        if let failure { throw failure }
        return entries
    }

    /// `<connectionID>/<libraryItemID>` of a path in an item's folder.
    private static func itemFolder(of path: String) -> String {
        path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).prefix(2).joined(separator: "/")
    }

    /// Removes the file at `url`; whether it was removed (or already gone).
    private static func remove(_ url: URL?) -> Bool {
        guard let url else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            Log.downloads.error(
                "Couldn't remove an orphaned download: \(Log.redact(String(describing: error)), privacy: .public)")
            return false
        }
    }

    /// Removes empty folders, deepest first, that changed before `cutoff` or held a file or
    /// folder removed in this sweep. `rmdir` refuses a folder that isn't empty, so a file moved
    /// in meanwhile is never removed with it.
    private static func removeEmptyFolders(
        _ directories: [Entry], emptied removed: [String], before cutoff: Date, locations: DownloadLocations
    ) -> [String] {
        func parent(_ path: String) -> String {
            DownloadLayout.collisionKey(path.split(separator: "/").dropLast().joined(separator: "/"))
        }
        var emptied = Set(removed.map(parent))
        var removedFolders: [String] = []
        let deepestFirst = directories.sorted {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }
        for directory in deepestFirst {
            let isOld = directory.modified.map { $0 < cutoff } ?? false
            guard isOld || emptied.contains(DownloadLayout.collisionKey(directory.path)),
                let url = try? locations.fileURL(forRelativePath: directory.path),
                rmdir(url.path(percentEncoded: false)) == 0
            else { continue }
            removedFolders.append(directory.path)
            emptied.insert(parent(directory.path))
        }
        return removedFolders
    }
}

extension DownloadManager {
    /// Removes `paths`, files in the folder of the item of `key`, that no record of its
    /// connection or its local item uses, read again while the item is held. Returns the paths
    /// removed (or already gone).
    func removeUnused(_ paths: [String], of key: MediaKey) async throws(DownloadManagerError) -> [String] {
        try await holdingItem(key) { () async throws(DownloadManagerError) -> [String] in
            let used = Set(try await usedPaths(of: key).map(DownloadLayout.collisionKey))
            var removed: [String] = []
            for path in paths where !used.contains(DownloadLayout.collisionKey(path)) {
                guard let url = try? locations.fileURL(forRelativePath: path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    removed.append(path)
                } catch CocoaError.fileNoSuchFile {
                    removed.append(path)
                } catch {
                    logError("Couldn't remove an orphaned download", error)
                }
            }
            return removed
        }
    }

    /// Deletes a record whose connection is gone, complete or not, while its item is held: the
    /// engine stops its transfers and deletes their resume data, then the record goes, then its
    /// files that nothing else uses. A complete record of a removed connection never becomes a
    /// local item (the connection is gone), so it isn't left for the engine as
    /// ``cancel(recordID:)`` would.
    ///
    /// - Returns: whether the record was deleted.
    func purgeRecord(id: UUID) async throws(DownloadManagerError) -> Bool {
        guard let first = try await read({ try await self.store.record(id: id) }) else { return false }
        return try await holdingItem(first.key) { () async throws(DownloadManagerError) -> Bool in
            guard let record = try await read({ try await self.store.record(id: id) }) else { return false }
            await engine.stop(partIDs: record.parts.map(\.id), keepingResumeData: false)
            guard let deleted = try await read({ try await self.store.deleteRecord(id) }) else { return false }
            reportRemoved(id)
            for part in deleted.parts { locations.clearTransferMarker(partID: part.id) }
            await cleanUp(
                after: deleted.key, removing: deleted.parts.map(\.destinationRelativePath), folder: nil, cover: nil)
            return true
        }
    }
}
