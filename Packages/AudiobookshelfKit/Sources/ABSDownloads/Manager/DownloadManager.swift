import ABSCore
import ABSData
import Foundation

/// Turns server items and podcast episodes into downloads, and reports what happens to them.
///
/// - ``enqueue(item:episodeID:connectionID:replacingExisting:)`` plans a ``DownloadRecordDTO``
///   (``DownloadPlanner``), skips media that is already queued or downloaded, checks the disk
///   space, saves the record and starts its parts on the engine.
/// - ``start()`` makes the manager the only reader of the engine's streams; ``events()`` passes
///   what it reads on to any number of subscribers.
///
/// How many parts download at once is capped by the background session
/// (`httpMaximumConnectionsPerHost`, see `URLSessionConfiguration.absDownloads`), not here.
/// Failed downloads are never retried on their own: the user retries them.
///
/// Share the ``DownloadStore`` with the engine (one actor, so its compare-and-set holds), and
/// call ``start()`` before the engine's first `activate()`.
public actor DownloadManager {
    /// What ``enqueue(item:episodeID:connectionID:replacingExisting:)`` did.
    public enum EnqueueResult: Sendable, Equatable {
        /// A new download record was saved and its parts started.
        case started(UUID)
        /// A record for the media already exists; a paused or failed one was resumed.
        case alreadyQueued(UUID)
        /// The media is already downloaded, as the local item with this ID.
        case alreadyDownloaded(UUID)
    }

    /// Bytes that must stay free on top of a download's size: 200 MB.
    public static let storageHeadroom: Int64 = 200_000_000
    /// The shortest time between two progress events of one record (unless it reaches the end).
    static let progressInterval: Duration = .seconds(1)

    /// A record's key and its parts' bytes, for progress across the record.
    private struct TrackedRecord {
        var key: MediaKey
        var parts: [UUID: (written: Int64, expected: Int64)]

        var bytes: Int64 { parts.values.reduce(0) { $0 + $1.written } }

        var fraction: Double {
            let expected = parts.values.reduce(Int64(0)) { $0 + max($1.expected, 0) }
            guard expected > 0 else { return 0 }
            return min(1, Double(bytes) / Double(expected))
        }
    }

    private let store: DownloadStore
    private let localItems: LocalItemStore
    private let engine: any DownloadEngineControlling
    private let locations: DownloadLocations
    private let planner: DownloadPlanner
    private let capacity: any StorageCapacityProviding
    private let clock: any Clock<Duration>
    /// Test seams, optional so production makes no actor hop for them.
    private let enqueueWaiting: (@Sendable (MediaKey) -> Void)?
    private let progressHandled: (@Sendable (DownloadProgress) -> Void)?

    /// Items with an enqueue under way, by their item-level key (no episode). Every enqueue of
    /// one item runs alone, so two calls for the same media can't both plan a record across
    /// the actor's suspension points, and two episodes of one podcast can't both plan the
    /// shared cover.
    private var enqueuing: Set<MediaKey> = []
    private var enqueueWaiters: [MediaKey: [CheckedContinuation<Void, Never>]] = [:]
    private var subscribers: [UUID: AsyncStream<DownloadManagerEvent>.Continuation] = [:]
    private var readers: [Task<Void, Never>] = []
    private var tracked: [UUID: TrackedRecord] = [:]
    /// Records whose progress window is open: one event was just sent, so the next waits.
    private var progressWindows: [UUID: Task<Void, Never>] = [:]
    /// Records whose progress changed during their window.
    private var pendingProgress: Set<UUID> = []

    /// - Parameters:
    ///   - store: the same actor the engine uses.
    ///   - capacity: ``VolumeStorageCapacity`` in the app.
    ///   - clock: paces progress events.
    public init(
        store: DownloadStore,
        localItems: LocalItemStore,
        engine: any DownloadEngineControlling,
        locations: DownloadLocations,
        capacity: any StorageCapacityProviding,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(
            store: store, localItems: localItems, engine: engine, locations: locations, capacity: capacity,
            clock: clock, enqueueWaiting: nil, progressHandled: nil)
    }

    init(
        store: DownloadStore,
        localItems: LocalItemStore,
        engine: any DownloadEngineControlling,
        locations: DownloadLocations,
        capacity: any StorageCapacityProviding,
        clock: any Clock<Duration>,
        enqueueWaiting: (@Sendable (MediaKey) -> Void)?,
        progressHandled: (@Sendable (DownloadProgress) -> Void)?
    ) {
        self.store = store
        self.localItems = localItems
        self.engine = engine
        self.locations = locations
        planner = DownloadPlanner(locations: locations)
        self.capacity = capacity
        self.clock = clock
        self.enqueueWaiting = enqueueWaiting
        self.progressHandled = progressHandled
    }

    deinit {
        for reader in readers { reader.cancel() }
        for window in progressWindows.values { window.cancel() }
        for subscriber in subscribers.values { subscriber.finish() }
    }

    // MARK: - Lifecycle and events

    /// Starts reading the engine's ``DownloadEngineControlling/updates`` and
    /// ``DownloadEngineControlling/progress``, which have one consumer each: nothing else may
    /// read them. Then creates the download folders (``DownloadLocations/prepare()``). Call it
    /// once, before the engine's first `activate()`; later calls only prepare the folders.
    ///
    /// - Throws: the error of ``DownloadLocations/prepare()``; the streams are read anyway.
    public func start() async throws {
        if readers.isEmpty {
            do {
                for record in try await store.allRecords() { track(record) }
            } catch {
                logError("Couldn't read downloads to track", error)
            }
            let updates = engine.updates
            let progress = engine.progress
            readers = [
                Task { [weak self] in
                    for await update in updates {
                        guard let self else { return }
                        await self.handle(update)
                    }
                },
                Task { [weak self] in
                    for await progress in progress {
                        guard let self else { return }
                        await self.handle(progress)
                    }
                },
            ]
        }
        try locations.prepare()
    }

    /// A new stream of everything that happens from now on. Each call gets its own stream;
    /// it ends when the subscriber stops iterating.
    public func events() -> AsyncStream<DownloadManagerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadManagerEvent.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func emit(_ event: DownloadManagerEvent) {
        for subscriber in subscribers.values { subscriber.yield(event) }
    }

    // MARK: - Enqueue

    /// Queues the download of a book, or of one podcast episode, and starts it.
    ///
    /// - An existing download record for the media is kept: a paused or failed one is resumed,
    ///   and the result is ``EnqueueResult/alreadyQueued(_:)``.
    /// - Media already downloaded gives ``EnqueueResult/alreadyDownloaded(_:)``: a book whose
    ///   local item has an audio or ebook file, or an episode with a file carrying its ID.
    /// - With `replacingExisting`, neither check applies: a new plan replaces the record (its
    ///   transfers are stopped and their resume data deleted), or downloads the media again
    ///   over the stored files. Paths are deterministic, so files with the same names are
    ///   replaced in place.
    ///
    /// The bytes still to fetch plus ``storageHeadroom`` must fit in the available capacity;
    /// when a file's size is unknown, the item's (or episode's) reported size is used instead.
    /// When the capacity can't be read, the download is queued anyway, and the engine's
    /// `outOfSpace` failure catches a full disk.
    ///
    /// - Parameter item: an expanded item (`ItemEndpoints.item(id:)`).
    /// - Throws: a ``DownloadManagerError``.
    public func enqueue(
        item: LibraryItem, episodeID: String?, connectionID: UUID, replacingExisting: Bool = false
    ) async throws(DownloadManagerError) -> EnqueueResult {
        let itemKey = MediaKey(serverConnectionID: connectionID, libraryItemId: item.id)
        await beginEnqueuing(itemKey)
        defer { endEnqueuing(itemKey) }
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: item.id, episodeId: episodeID)
        let existing = try await read { try await self.store.record(key: key) }
        if let existing, !replacingExisting {
            return try await keep(existing)
        }
        let localItem = try await read {
            try await self.localItems.item(serverConnectionID: connectionID, libraryItemId: item.id)
        }
        if !replacingExisting, let localItem, Self.hasDownloaded(key, in: localItem) {
            return .alreadyDownloaded(localItem.id)
        }
        let coverPath = try await existingCoverPath(for: key, localItem: localItem)
        let plan: DownloadRecordDTO
        do {
            plan = try planner.plan(
                item: item, episodeID: episodeID, connectionID: connectionID, existingCoverPath: coverPath)
        } catch {
            throw DownloadManagerError(error)
        }
        try await checkCapacity(for: plan, item: item)

        if let existing {
            // Store before engine: a paused record's parts can't be started again meanwhile.
            _ = try await read { try await self.store.setState(.paused, forRecord: existing.id) }
            await engine.stop(partIDs: existing.parts.map(\.id), keepingResumeData: false)
            forget(existing.id)
        }
        let record = try await read { try await self.store.upsertRecord(plan).record }
        track(record)
        emit(.recordChanged(record))
        await engine.start(partIDs: record.parts.map(\.id))
        return .started(record.id)
    }

    /// Waits until no other enqueue of the item is under way, then claims it.
    private func beginEnqueuing(_ itemKey: MediaKey) async {
        while enqueuing.contains(itemKey) {
            await withCheckedContinuation { continuation in
                enqueueWaiters[itemKey, default: []].append(continuation)
                enqueueWaiting?(itemKey)
            }
        }
        enqueuing.insert(itemKey)
    }

    private func endEnqueuing(_ itemKey: MediaKey) {
        enqueuing.remove(itemKey)
        for waiter in enqueueWaiters.removeValue(forKey: itemKey) ?? [] { waiter.resume() }
    }

    /// Keeps an existing record, resuming it when it is paused or failed.
    private func keep(_ record: DownloadRecordDTO) async throws(DownloadManagerError) -> EnqueueResult {
        if tracked[record.id] == nil { track(record) }
        switch record.state {
        case .paused, .failed:
            do {
                _ = try await engine.resume(recordID: record.id)
            } catch {
                logError("Couldn't resume a download", error)
                throw .storeFailure
            }
            await refresh(record.id, announce: true)
        case .queued, .downloading:
            break
        }
        return .alreadyQueued(record.id)
    }

    /// Whether `localItem` already holds the media of `key`.
    private static func hasDownloaded(_ key: MediaKey, in localItem: LocalLibraryItemDTO) -> Bool {
        if let episodeID = key.episodeId {
            return localItem.files.contains { $0.episodeId == episodeID }
        }
        return localItem.files.contains { $0.kind == .audio || $0.kind == .ebook }
    }

    /// The item's cover that is stored or on its way: the local item's, or else a cover part
    /// of another record of the same item, so two episodes queued together fetch it once.
    private func existingCoverPath(
        for key: MediaKey, localItem: LocalLibraryItemDTO?
    ) async throws(DownloadManagerError) -> String? {
        if let path = localItem?.coverRelativePath { return path }
        let records = try await read { try await self.store.records(serverConnectionID: key.serverConnectionID) }
        return
            records
            .lazy
            .filter { $0.key.libraryItemId == key.libraryItemId && $0.key != key }
            .compactMap { $0.parts.first { $0.kind == .cover }?.destinationRelativePath }
            .first
    }

    private func checkCapacity(for record: DownloadRecordDTO, item: LibraryItem) async throws(DownloadManagerError) {
        // A cover's size is never known in advance; the headroom covers it.
        let files = record.parts.filter { $0.kind != .cover }
        var required = files.reduce(Int64(0)) { $0 + max($1.expectedBytes - $1.bytesWritten, 0) }
        if files.contains(where: { $0.expectedBytes <= 0 }) {
            required = max(required, Int64(Self.reportedSize(of: item, episodeID: record.key.episodeId) ?? 0))
        }
        required += Self.storageHeadroom
        let available: Int64
        do {
            available = try await capacity.availableCapacity()
        } catch {
            logError("Couldn't read the available storage", error)
            return
        }
        guard required <= available else { throw .insufficientStorage(required: required, available: available) }
    }

    /// The server's size of the episode, or of the whole item.
    private static func reportedSize(of item: LibraryItem, episodeID: String?) -> Int? {
        switch item.media {
        case .podcast(let podcast):
            return podcast.episodes?.first { $0.id == episodeID }?.size
        case .book(let book):
            return item.size ?? book.size
        case nil:
            return item.size
        }
    }

    // MARK: - Engine updates

    private func handle(_ update: DownloadUpdate) async {
        switch update {
        case .partCompleted(_, let recordID):
            await refresh(recordID, announce: true)
        case .partFailed(_, let recordID, let code, let message, let willRetry):
            await refresh(recordID, announce: true)
            if !willRetry { emit(.failed(recordID: recordID, code: code, message: message)) }
        case .recordComplete(let recordID, let itemID):
            var key = forget(recordID)
            if key == nil { key = await bookKey(ofLocalItem: itemID) }
            if let key {
                emit(.completed(recordID: recordID, itemID: itemID, key: key))
            } else {
                Log.downloads.fault("A download completed that the manager didn't track")
            }
        case .sessionUnavailable(let code, _):
            Log.downloads.error("Downloads are waiting for the session: \(code.rawValue, privacy: .public)")
        }
    }

    /// The key of a downloaded book, for a record that wasn't tracked (an episode's key can't be
    /// told from its local item).
    private func bookKey(ofLocalItem itemID: UUID) async -> MediaKey? {
        guard let item = try? await localItems.item(id: itemID), item.mediaType == .book else { return nil }
        return MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)
    }

    // MARK: - Progress

    private func handle(_ progress: DownloadProgress) async {
        if tracked[progress.recordID] == nil { await refresh(progress.recordID, announce: false) }
        if var record = tracked[progress.recordID] {
            record.parts[progress.partID] = (progress.bytesWritten, progress.expectedBytes)
            tracked[progress.recordID] = record
            publishProgress(of: progress.recordID)
        }
        progressHandled?(progress)
    }

    /// Sends a record's progress at once, unless it was sent less than ``progressInterval``
    /// ago; then the newest value is sent when that interval ends. Reaching the end is always
    /// sent at once.
    private func publishProgress(of recordID: UUID) {
        guard let record = tracked[recordID] else { return }
        if record.fraction >= 1 {
            progressWindows.removeValue(forKey: recordID)?.cancel()
            pendingProgress.remove(recordID)
        } else if progressWindows[recordID] != nil {
            pendingProgress.insert(recordID)
            return
        }
        emit(.progress(recordID: recordID, fraction: record.fraction, bytes: record.bytes))
        guard record.fraction < 1 else { return }
        let clock = clock
        progressWindows[recordID] = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.progressInterval)
            } catch {
                return
            }
            await self?.endProgressWindow(of: recordID)
        }
    }

    private func endProgressWindow(of recordID: UUID) {
        progressWindows[recordID] = nil
        if pendingProgress.remove(recordID) != nil { publishProgress(of: recordID) }
    }

    // MARK: - Tracking

    private func track(_ record: DownloadRecordDTO) {
        let previous = tracked[record.id]?.parts ?? [:]
        var parts: [UUID: (written: Int64, expected: Int64)] = [:]
        for part in record.parts {
            // Stored progress is written less often than it is reported; keep the newer value.
            let live = part.state == .completed ? nil : previous[part.id]
            parts[part.id] = (
                max(part.bytesWritten, live?.written ?? 0),
                live.map { max($0.expected, part.expectedBytes) }
                    ?? part.expectedBytes
            )
        }
        tracked[record.id] = TrackedRecord(key: record.key, parts: parts)
    }

    /// Stops tracking a record; returns its key.
    @discardableResult
    private func forget(_ recordID: UUID) -> MediaKey? {
        progressWindows.removeValue(forKey: recordID)?.cancel()
        pendingProgress.remove(recordID)
        return tracked.removeValue(forKey: recordID)?.key
    }

    /// Reads a record again and tracks it; with `announce`, reports it.
    private func refresh(_ recordID: UUID, announce: Bool) async {
        let record: DownloadRecordDTO?
        do {
            record = try await store.record(id: recordID)
        } catch {
            logError("Couldn't read a download", error)
            return
        }
        // A record that is gone was finalised or deleted; its key is kept for `recordComplete`.
        guard let record else { return }
        track(record)
        if announce { emit(.recordChanged(record)) }
    }

    // MARK: - Helpers

    /// Runs a store call, mapping its error.
    private func read<T: Sendable>(_ body: () async throws -> T) async throws(DownloadManagerError) -> T {
        do {
            return try await body()
        } catch DownloadStore.StoreError.connectionNotFound(let id) {
            throw .connectionNotFound(id)
        } catch {
            logError("A download store call failed", error)
            throw .storeFailure
        }
    }

    private nonisolated func logError(_ message: String, _ error: any Error) {
        Log.downloads.error(
            "\(message, privacy: .public): \(Log.redact(String(describing: error)), privacy: .public)")
    }
}
