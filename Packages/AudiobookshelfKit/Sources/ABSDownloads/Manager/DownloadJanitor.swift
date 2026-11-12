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
        /// A read or deletion failed during this step, so the sweep stopped there. A failure in
        /// the first four steps (the snapshot) comes before anything is deleted; one at
        /// ``Step/readingItem`` or ``Step/deletingOrphanedMedia`` comes after some removals,
        /// which the report lists.
        case aborted(Step)
    }

    public enum SkipReason: Sendable, Equatable {
        /// The store isn't the App Group store (ADR 0003): a fallback or test store doesn't
        /// hold the app's downloads, so every file would look orphaned.
        case notAppGroupStore
        /// Another sweep is running.
        case alreadySweeping
    }

    /// The reads (and deletions) that can stop a sweep, in order. The first four make the
    /// snapshot every deletion is decided from.
    public enum Step: Sendable, Equatable {
        case listingFiles
        case readingRecords
        case readingLocalItems
        case readingConnections
        /// Reading an item's records and local item again while it is held, before removing
        /// its orphaned files and empty folders.
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
    /// Parts whose orphaned `Transfers/` marker was deleted.
    public var removedTransferMarkers: [UUID] = []
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

/// Removes what downloads leave behind: files nothing refers to, empty folders, resume data and
/// transfer markers of parts that are gone, media of connections that are gone, and disconnected connections with
/// nothing left. Run it when the app becomes active, after the engine's `activate()`.
///
/// A sweep:
/// 1. lists the files, folders, resume-data blobs and transfer markers first, then reads the records, the local
///    items and the connections, in that order. A file only appears after its record is saved,
///    and the engine finalises a record into a local item before it deletes the record, so
///    every listed file in use is referred to by at least one of the reads;
/// 2. removes listed files that no record part, local file or cover refers to. Files changed
///    within ``recentInterval`` stay: one a settling part moved in after its record was
///    cancelled is removed by a later sweep. Any file in an item's folder
///    (`<connection id>/<escaped item id>/…`, known to the snapshot or not) is removed while
///    the ``DownloadManager`` holds the item, after reading its records and local item again
///    and checking its date again, so a download of it enqueued meanwhile (whose file can
///    replace one at the same path), or a cancel or deletion of it (which can hand a stored
///    cover to another record) can't interleave. Any other file's date is checked again just
///    before it is removed;
/// 3. removes empty folders that step 2 emptied, or that are older than ``recentInterval``
///    when listed and still are just before removal, but never one that holds a path a record
///    or local item refers to: the engine creates a destination's folder, then moves the file
///    in. An item's folders (with orphaned files or not) are removed in the same hold as its
///    files, from the paths read again in it, so a download of it enqueued after the snapshot
///    keeps its folder. A connection's own folder (`<connection id>/`) stays while the
///    connection exists, so a download creating an item's folder in it can't lose it midway;
/// 4. deletes `ResumeData/<part id>.bin` blobs and `Transfers/<part id>` markers whose part no
///    record has (and that are older than ``recentInterval``). A part's marker is written only
///    once its record is saved, so a listed marker of a part in use is in the read; a part that
///    exists in any state keeps its marker, which the engine reads to tell its transfer's files;
/// 5. deletes the records, then the local items, of connections that no longer exist, with
///    their files, through the ``DownloadManager``;
/// 6. calls `ServerConnectionStore.removeIfDisconnected(id:disconnectedAt:)` for each
///    disconnected connection with no record or local item left, which deletes it unless
///    something else still refers to it or it was logged in to (or removed again) since it was
///    read.
///
/// When a read fails, the sweep stops and reports it (``SweepReport/Outcome/aborted(_:)``).
/// A failure while taking the snapshot (listing the files, reading the records, local items
/// or connections) comes before anything is deleted, so nothing is ever decided from a partial
/// snapshot; a failure rereading an item (step 2) or deleting media of a removed connection
/// (step 5) comes after the removals before it.
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
    ///   - dataStack: the stack the stores use; only a store opened in the App Group
    ///     (`resolvedLocation == .appGroup`) is swept.
    ///   - now: the current time, for ``recentInterval``.
    public init(
        manager: DownloadManager,
        connections: ServerConnectionStore,
        dataStack: DataStack,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            manager: manager, connections: connections, storeLocation: dataStack.resolvedLocation, now: now,
            beforeRead: nil)
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
        var unheld: [String] = []
        var filesByItem: [MediaKey: [String]] = [:]
        for file in listing.files where !referenced.contains(DownloadLayout.collisionKey(file.path)) {
            guard let modified = file.modified, modified < cutoff else {
                report.keptRecentFiles.append(file.path)
                continue
            }
            if let key = Self.itemKey(ofPath: file.path) {
                filesByItem[key, default: []].append(file.path)
            } else {
                unheld.append(file.path)
            }
        }
        report.removedFiles += unheld.filter {
            guard let url = try? locations.fileURL(forRelativePath: $0) else { return false }
            // Checked again: the snapshot was read since the listing.
            return Self.isModified(url, before: cutoff) && Self.remove(url)
        }
        // Every item folder, even one without orphaned files, so its folders are only removed
        // while it is held (step 3).
        var foldersByItem: [MediaKey: [Entry]] = [:]
        var otherFolders: [Entry] = []
        for directory in listing.directories {
            if let key = Self.itemKey(ofFolder: directory.path) {
                foldersByItem[key, default: []].append(directory)
            } else {
                otherFolders.append(directory)
            }
        }
        let itemKeys = Set(filesByItem.keys).union(foldersByItem.keys).sorted {
            ($0.serverConnectionID.uuidString, $0.libraryItemId) < ($1.serverConnectionID.uuidString, $1.libraryItemId)
        }
        // The folders holding a referenced path, once per sweep; each item adds its own paths
        // read in its hold.
        var protected: Set<String> = []
        Self.addFolders(holding: referenced, to: &protected)
        for key in itemKeys {
            let snapshotProtected = protected
            let result = try await read(.readingItem) {
                try await self.manager.sweepItem(
                    key, files: filesByItem[key] ?? [], folders: foldersByItem[key] ?? [],
                    protecting: snapshotProtected, changedBefore: cutoff)
            }
            report.removedFiles += result.removedFiles
            report.removedFolders += result.removedFolders
            Self.addFolders(holding: result.used, to: &protected)
        }

        // 3. Empty folders outside item folders (an item's went with its files). A connection's
        // own folder stays while the connection exists: the engine creates it, then the item's
        // folder in it, outside any hold.
        let connectionFolders = Set(connections.map { DownloadLayout.collisionKey($0.id.uuidString) })
        report.removedFolders += Self.removeEmptyFolders(
            otherFolders, emptied: report.removedFiles + report.removedFolders, protecting: protected,
            alsoProtecting: connectionFolders, before: cutoff, locations: locations)

        // 4. Resume data of parts that are gone.
        let parts = Set(records.flatMap(\.parts).map(\.id))
        for blob in listing.blobs where !parts.contains(blob.partID) {
            guard let modified = blob.modified, modified < cutoff else { continue }
            if Self.remove(blob.url) { report.removedResumeData.append(blob.partID) }
        }
        // Transfer markers of parts that are gone, by the same rule.
        for marker in listing.markers where !parts.contains(marker.partID) {
            guard let modified = marker.modified, modified < cutoff else { continue }
            if Self.remove(marker.url) { report.removedTransferMarkers.append(marker.partID) }
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
                if try await self.connections.removeIfDisconnected(
                    id: connection.id, disconnectedAt: connection.disconnectedAt)
                {
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

    struct Entry: Sendable {
        /// Relative to the downloads root.
        var path: String
        var modified: Date?
    }

    /// A resume-data blob or a transfer marker, named for its part.
    private struct Blob: Sendable {
        var partID: UUID
        var url: URL
        var modified: Date?
    }

    private struct Listing: Sendable {
        var files: [Entry] = []
        var directories: [Entry] = []
        var blobs: [Blob] = []
        /// `Transfers/<part id>` markers (see ``DownloadLocations/markTransferStart(partID:)``).
        var markers: [Blob] = []
    }

    /// Everything below the downloads root, the resume-data blobs and the transfer markers. A root
    /// that doesn't exist is empty; any other error throws.
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
        for (url, values) in try contents(of: locations.transfersRoot, recursive: false, keys: keys)
        where values.isDirectory != true {
            guard let partID = UUID(uuidString: url.lastPathComponent) else { continue }
            listing.markers.append(Blob(partID: partID, url: url, modified: values.contentModificationDate))
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

    /// The item whose folder (``DownloadLayout/folder``, `<connection id>/<escaped item id>`)
    /// holds the file at `path`, whether the store knows the item or not; `nil` for a path
    /// outside any item folder.
    static func itemKey(ofPath path: String) -> MediaKey? {
        itemKey(pathComponents(path), minimumCount: 3)
    }

    /// The item whose folder is, or holds, the folder at `path`; `nil` for any other folder.
    static func itemKey(ofFolder path: String) -> MediaKey? {
        itemKey(pathComponents(path), minimumCount: 2)
    }

    private static func itemKey(_ components: [String], minimumCount: Int) -> MediaKey? {
        guard components.count >= minimumCount, let connectionID = UUID(uuidString: components[0]),
            let itemID = components[1].removingPercentEncoding,
            (try? DownloadLayout.escapedIdentifier(itemID)) == components[1]
        else { return nil }
        return MediaKey(serverConnectionID: connectionID, libraryItemId: itemID)
    }

    /// The components of a relative path, split on scalars, not Characters, as
    /// ``DownloadLocations/fileURL(forRelativePath:)`` does: a `/` followed by a combining mark
    /// is one Character, but the file system still sees the `/`.
    static func pathComponents(_ path: String) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// The collision key of the folder holding `path`; empty for a path at the root.
    static func parentKey(of path: String) -> String {
        DownloadLayout.collisionKey(pathComponents(path).dropLast().joined(separator: "/"))
    }

    /// Whether the file or folder at `url` exists and was last changed before `cutoff`, read now.
    static func isModified(_ url: URL, before cutoff: Date) -> Bool {
        // A fresh URL, so no cached values are read.
        let modified = try? URL(filePath: url.path(percentEncoded: false))
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return modified.map { $0 < cutoff } ?? false
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

    /// Adds the collision keys of the folders holding each of `paths` (collision keys), up to
    /// the root, to `folders`.
    static func addFolders(holding paths: some Sequence<String>, to folders: inout Set<String>) {
        for path in paths {
            var folder = parentKey(of: path)
            while !folder.isEmpty, folders.insert(folder).inserted { folder = parentKey(of: folder) }
        }
    }

    /// Removes empty folders, deepest first, that held a file or folder removed in this sweep,
    /// or that changed before `cutoff` both when listed and just before removal. A folder in
    /// `protected` or `alsoProtected` (collision keys of folders holding a referenced path, see
    /// ``addFolders(holding:to:)``) stays: the engine creates a destination's folder before it
    /// moves the file in. `rmdir` refuses a folder that isn't empty, so a file moved in
    /// meanwhile is never removed with it.
    static func removeEmptyFolders(
        _ directories: [Entry], emptied removed: [String], protecting protected: Set<String>,
        alsoProtecting alsoProtected: Set<String> = [], before cutoff: Date, locations: DownloadLocations
    ) -> [String] {
        let parent = parentKey(of:)
        var emptied = Set(removed.map(parent))
        var removedFolders: [String] = []
        let deepestFirst = directories.sorted {
            pathComponents($0.path).count > pathComponents($1.path).count
        }
        for directory in deepestFirst {
            let key = DownloadLayout.collisionKey(directory.path)
            let wasEmptied = emptied.contains(key)
            guard !protected.contains(key), !alsoProtected.contains(key),
                wasEmptied || directory.modified.map({ $0 < cutoff }) == true,
                let url = try? locations.fileURL(forRelativePath: directory.path),
                wasEmptied || isModified(url, before: cutoff),
                rmdir(url.path(percentEncoded: false)) == 0
            else { continue }
            removedFolders.append(directory.path)
            emptied.insert(parent(directory.path))
        }
        return removedFolders
    }
}

extension DownloadManager {
    /// What ``sweepItem(_:files:folders:protecting:changedBefore:)`` did.
    struct ItemSweep: Sendable {
        /// Files removed (or already gone).
        var removedFiles: [String] = []
        var removedFolders: [String] = []
        /// The collision keys of the paths in use in the item's folder that were read.
        var used: Set<String> = []
    }

    /// While the item of `key` is held: removes `files`, in its folder, that no record of its
    /// connection or its local item uses, read again in the hold, and that were still last
    /// changed before `cutoff` just before removal; then removes its empty `folders` as
    /// ``DownloadJanitor`` does, keeping those in `protected` (the sweep's, built once) or that
    /// hold a path in the item's folder read in the hold. A download of the item enqueued after
    /// the sweep's snapshot is read here, so its folder stays; one enqueued later waits for the
    /// hold.
    func sweepItem(
        _ key: MediaKey, files paths: [String], folders: [DownloadJanitor.Entry], protecting protected: Set<String>,
        changedBefore cutoff: Date
    ) async throws(DownloadManagerError) -> ItemSweep {
        try await holdingItem(key) { () async throws(DownloadManagerError) -> ItemSweep in
            let used = Set(try await usedPaths(of: key).map(DownloadLayout.collisionKey))
            // Only the item's own paths: the read covers its whole connection. Compared as
            // scalars, so a name starting with a combining mark still matches.
            let itemFolder = DownloadLayout.collisionKey(
                "\(key.serverConnectionID.uuidString)/\((try? DownloadLayout.escapedIdentifier(key.libraryItemId)) ?? "")/"
            )
            let usedHere = used.filter { $0.unicodeScalars.starts(with: itemFolder.unicodeScalars) }
            var itemProtected: Set<String> = []
            DownloadJanitor.addFolders(holding: usedHere, to: &itemProtected)
            var removed: [String] = []
            for path in paths where !used.contains(DownloadLayout.collisionKey(path)) {
                guard let url = try? locations.fileURL(forRelativePath: path),
                    DownloadJanitor.isModified(url, before: cutoff)
                else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    removed.append(path)
                } catch CocoaError.fileNoSuchFile {
                    removed.append(path)
                } catch {
                    logError("Couldn't remove an orphaned download", error)
                }
            }
            let removedFolders = DownloadJanitor.removeEmptyFolders(
                folders, emptied: removed, protecting: protected, alsoProtecting: itemProtected, before: cutoff,
                locations: locations)
            return ItemSweep(removedFiles: removed, removedFolders: removedFolders, used: usedHere)
        }
    }

    /// Deletes a record whose connection is gone, complete or not, while its item is held: it is
    /// paused first, as ``cancel(recordID:)`` does, so nothing restarts a part the engine stops
    /// (a stop queues a part again), then the engine stops its transfers and deletes their
    /// resume data, then the record goes, then its
    /// files that nothing else uses. A complete record of a removed connection never becomes a
    /// local item (the connection is gone), so it isn't left for the engine as
    /// ``cancel(recordID:)`` would.
    ///
    /// - Returns: whether the record was deleted.
    func purgeRecord(id: UUID) async throws(DownloadManagerError) -> Bool {
        guard let first = try await read({ try await self.store.record(id: id) }) else { return false }
        return try await holdingItem(first.key) { () async throws(DownloadManagerError) -> Bool in
            guard let record = try await read({ try await self.store.record(id: id) }),
                try await read({ try await self.store.setState(.paused, forRecord: id) })
            else { return false }
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
