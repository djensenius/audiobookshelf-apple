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
        /// Parts whose stored size is final: progress read after their completion is stale.
        var completed: Set<UUID> = []

        var bytes: Int64 { parts.values.reduce(0) { DownloadManager.adding($0, max($1.written, 0)) } }

        var fraction: Double {
            // Server-reported lengths can be anything: sum them as `Double` so they can't overflow.
            let expected = parts.values.reduce(0.0) { $0 + Double(max($1.expected, 0)) }
            guard expected > 0 else { return 0 }
            return min(1, Double(bytes) / expected)
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
    private let subscriberRemoved: (@Sendable () -> Void)?
    private let trackingRecords: (@Sendable () async -> Void)?

    /// Items with an enqueue under way, by their item-level key (no episode). Every enqueue of
    /// one item runs alone, so two calls for the same media can't both plan a record across
    /// the actor's suspension points, and two episodes of one podcast can't both plan the
    /// shared cover.
    private var enqueuing: Set<MediaKey> = []
    private var enqueueWaiters: [MediaKey: [CheckedContinuation<Void, Never>]] = [:]
    private var subscribers: [UUID: AsyncStream<DownloadManagerEvent>.Continuation] = [:]
    private var readers: [Task<Void, Never>] = []
    /// Set by the first ``start()`` before it suspends, so overlapping calls read the engine's
    /// streams once.
    private var didStart = false
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
            clock: clock, enqueueWaiting: nil, progressHandled: nil, subscriberRemoved: nil)
    }

    init(
        store: DownloadStore,
        localItems: LocalItemStore,
        engine: any DownloadEngineControlling,
        locations: DownloadLocations,
        capacity: any StorageCapacityProviding,
        clock: any Clock<Duration>,
        enqueueWaiting: (@Sendable (MediaKey) -> Void)?,
        progressHandled: (@Sendable (DownloadProgress) -> Void)?,
        subscriberRemoved: (@Sendable () -> Void)? = nil,
        trackingRecords: (@Sendable () async -> Void)? = nil
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
        self.subscriberRemoved = subscriberRemoved
        self.trackingRecords = trackingRecords
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
        if !didStart {
            didStart = true
            // The readers exist before the first suspension, so an overlapping call can't make
            // a second pair.
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
            await trackingRecords?()
            do {
                for record in try await store.allRecords() where tracked[record.id] == nil { track(record) }
            } catch {
                logError("Couldn't read downloads to track", error)
            }
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
        subscriberRemoved?()
    }

    /// How many ``events()`` streams are open, for tests.
    var subscriberCount: Int { subscribers.count }

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
    /// - With `replacingExisting`, neither check applies: an existing record is paused, its
    ///   transfers stopped (deleting their resume data) and the record deleted, and the new
    ///   plan is saved as a new record, so a late finalise of the old one can't delete it. If
    ///   saving the new record fails, the old one is already gone: nothing is queued, and the
    ///   caller can enqueue again.
    /// - Downloading stored media again reuses its paths, which are deterministic: each new
    ///   file replaces the old one in place, atomically. Files at old paths that the server no
    ///   longer lists lose their rows when the record completes and are left for the
    ///   `DownloadJanitor`'s orphan sweep (#192). Until the replacement completes, an item
    ///   whose files changed content but kept their names can be a mix of old and new files.
    ///
    /// The bytes still to fetch for this download plus ``storageHeadroom`` must fit in the
    /// available capacity; other downloads under way aren't counted. When a file's size is
    /// unknown, the item's (or episode's) reported size is used instead. When the capacity
    /// can't be read, the download is queued anyway; in both cases the engine's `outOfSpace`
    /// failure catches a full disk.
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
        var existing = try await read { try await self.store.record(key: key) }
        if let record = existing, !replacingExisting {
            if let result = try await keep(record, item: item) { return result }
            // The record was finalised or deleted meanwhile: plan as if it never existed.
            existing = nil
        }
        let localItem = try await read {
            try await self.localItems.item(serverConnectionID: connectionID, libraryItemId: item.id)
        }
        if !replacingExisting, let localItem, Self.hasDownloaded(key, in: localItem) {
            return .alreadyDownloaded(localItem.id)
        }
        let cover = try await existingCover(for: key, localItem: localItem)
        var plan: DownloadRecordDTO
        do {
            plan = try planner.plan(
                item: item, episodeID: episodeID, connectionID: connectionID, existingCoverPath: cover.pendingPath)
        } catch {
            throw DownloadManagerError(error)
        }
        if let shared = cover.completed,
            let index = plan.parts.firstIndex(where: { $0.kind == .cover && $0.serverPath == shared.serverPath })
        {
            // The cover is on disk, held by another record that may never complete: this record
            // carries it as a completed part, so its local item gets the cover without a fetch.
            // Only the same version (the request path carries the item's `updatedAt`): the plan's
            // `coverUpdatedAt` would mark an older image as current. Otherwise it is fetched.
            plan.parts[index].destinationRelativePath = shared.destinationRelativePath
            plan.parts[index].filename = shared.filename
            plan.parts[index].expectedBytes = shared.expectedBytes
            plan.parts[index].bytesWritten = shared.bytesWritten
            plan.parts[index].state = .completed
        }
        try await checkCapacity(for: plan, item: item)

        if let existing {
            // Store before engine: a paused record's parts can't be started again meanwhile.
            _ = try await read { try await self.store.setState(.paused, forRecord: existing.id) }
            await engine.stop(partIDs: existing.parts.map(\.id), keepingResumeData: false)
            forget(existing.id)
            // A part still settling isn't stopped: the engine may finalise the old record and
            // then delete it by ID. Deleting it here, and saving the plan under the plan's new
            // ID, keeps that late delete off the new record. The stop deleted the resume data
            // of every part it stopped.
            _ = try await read { try await self.store.deleteRecord(existing.id) }
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

    /// Keeps an existing record, resuming it when it is paused or failed and its remaining bytes
    /// fit; `nil` when the record is gone by the time it is resumed.
    private func keep(
        _ record: DownloadRecordDTO, item: LibraryItem
    ) async throws(DownloadManagerError) -> EnqueueResult? {
        if tracked[record.id] == nil { track(record) }
        switch record.state {
        case .paused, .failed:
            // The disk may have filled since it was queued (it may have failed `outOfSpace`).
            try await checkCapacity(for: record, item: item)
            guard try await read({ try await self.engine.resume(recordID: record.id) }) else {
                forget(record.id)
                return nil
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

    /// The item's cover that is stored or on its way, so two episodes queued together fetch it
    /// once:
    /// - `pendingPath`: the local item's cover, or a cover part another queued or downloading
    ///   record of the item will fetch and attach. The plan gets no cover part.
    /// - `completed`: a cover part another record of the item has already fetched, on disk.
    ///   Its record may never complete (paused or failed), so the plan carries it instead.
    /// A pending cover part of a paused or failed record counts for neither: the plan fetches
    /// its own.
    private func existingCover(
        for key: MediaKey, localItem: LocalLibraryItemDTO?
    ) async throws(DownloadManagerError) -> (pendingPath: String?, completed: DownloadPartDTO?) {
        if let path = localItem?.coverRelativePath { return (path, nil) }
        let records = try await read { try await self.store.records(serverConnectionID: key.serverConnectionID) }
        let siblings = records.filter { $0.key.libraryItemId == key.libraryItemId && $0.key != key }
        let covers = siblings.compactMap { record in
            record.parts.first { $0.kind == .cover }.map { (record, $0) }
        }
        let locations = locations
        let stored = covers.first { _, part in
            part.state == .completed
                && (try? locations.fileURL(forRelativePath: part.destinationRelativePath))
                    .map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        if let stored { return (nil, stored.1) }
        let pending = covers.first { record, part in
            part.state != .completed && (record.state == .queued || record.state == .downloading)
        }
        return (pending?.1.destinationRelativePath, nil)
    }

    private func checkCapacity(for record: DownloadRecordDTO, item: LibraryItem) async throws(DownloadManagerError) {
        // A cover's size is never known in advance; the headroom covers it.
        // Completed parts need nothing more. Sizes come from the server, so the sums saturate
        // at `Int64.max` (which never fits) instead of overflowing.
        let files = record.parts.filter { $0.kind != .cover }
        let remaining = files.filter { $0.state != .completed }
        var required = remaining.reduce(Int64(0)) { Self.adding($0, Self.bytesToFetch($1)) }
        if remaining.contains(where: { $0.expectedBytes <= 0 }) {
            // The reported size covers the whole media: what is on disk and kept doesn't count.
            let kept = files.reduce(Int64(0)) {
                Self.adding($0, $1.state == .completed || $1.hasResumeData ? max($1.bytesWritten, 0) : 0)
            }
            let reported = Int64(Self.reportedSize(of: item, episodeID: record.key.episodeId) ?? 0)
            required = max(required, max(reported - kept, 0))
        }
        required = Self.adding(required, Self.storageHeadroom)
        let available: Int64
        do {
            available = try await capacity.availableCapacity()
        } catch {
            logError("Couldn't read the available storage", error)
            return
        }
        guard required <= available else { throw .insufficientStorage(required: required, available: available) }
    }

    /// The bytes a part that hasn't completed still has to fetch: the rest of the file when it
    /// resumes, or all of it when it has no resume data and starts again from the beginning.
    private static func bytesToFetch(_ part: DownloadPartDTO) -> Int64 {
        let expected = max(part.expectedBytes, 0)
        return part.hasResumeData ? max(expected - max(part.bytesWritten, 0), 0) : expected
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

    /// The key of a downloaded book, for a record that wasn't tracked. An episode's key can't be
    /// told from its local item, so an episode record the manager never tracked (saved after
    /// ``start()`` by something other than ``enqueue(item:episodeID:connectionID:replacingExisting:)``,
    /// and gone before any of its updates was handled) completes without a
    /// ``DownloadManagerEvent/completed(recordID:itemID:key:)`` event.
    private func bookKey(ofLocalItem itemID: UUID) async -> MediaKey? {
        guard let item = try? await localItems.item(id: itemID), item.mediaType == .book else { return nil }
        return MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)
    }

    // MARK: - Progress

    private func handle(_ progress: DownloadProgress) async {
        if tracked[progress.recordID] == nil { await refresh(progress.recordID, announce: false) }
        // The streams are read by separate tasks, so a part's last progress can arrive after its
        // completion was read from the store; the stored size wins.
        if var record = tracked[progress.recordID], !record.completed.contains(progress.partID) {
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
        tracked[record.id] = TrackedRecord(
            key: record.key, parts: parts,
            completed: Set(record.parts.filter { $0.state == .completed }.map(\.id)))
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

    /// `a + b` of non-negative values, or `Int64.max` when that overflows.
    static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

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
