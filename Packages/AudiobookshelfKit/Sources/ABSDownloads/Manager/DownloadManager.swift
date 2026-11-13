import ABSCore
import ABSData
import Foundation

/// Turns server items and podcast episodes into downloads, and reports what happens to them.
///
/// - ``enqueue(item:episodeID:connectionID:replacingExisting:unlessQuiescedSince:)`` plans a ``DownloadRecordDTO``
///   (``DownloadPlanner``), skips media that is already queued or downloaded, checks the disk
///   space, saves the record and starts its parts on the engine.
/// - ``pause(recordID:)``, ``resume(recordID:)``, ``retry(recordID:)``, ``cancel(recordID:)``
///   and ``restartActiveTransfers()`` control downloads; ``deleteLocalItem(id:)`` and
///   ``deleteEpisode(itemID:episodeId:)`` delete downloaded media.
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
    /// What ``enqueue(item:episodeID:connectionID:replacingExisting:unlessQuiescedSince:)`` did.
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
        /// Whether it only fetches the item's cover again (``DownloadRecordDTO/isCoverOnly``).
        var isCoverOnly = false
        /// The file such a record fetches.
        var fetchedCover: String?

        var bytes: Int64 { parts.values.reduce(0) { DownloadManager.adding($0, max($1.written, 0)) } }

        var fraction: Double {
            // Server-reported lengths can be anything: sum them as `Double` so they can't overflow.
            let expected = parts.values.reduce(0.0) { $0 + Double(max($1.expected, 0)) }
            guard expected > 0 else { return 0 }
            return min(1, Double(bytes) / expected)
        }
    }

    let store: DownloadStore
    let localItems: LocalItemStore
    let engine: any DownloadEngineControlling
    let locations: DownloadLocations
    private let planner: DownloadPlanner
    private let capacity: any StorageCapacityProviding
    private let clock: any Clock<Duration>
    let progressLinking: (any LocalProgressLinking)?
    /// Test seams, optional so production makes no actor hop for them.
    private let enqueueWaiting: (@Sendable (MediaKey) -> Void)?
    private let progressHandled: (@Sendable (DownloadProgress) -> Void)?
    private let subscriberRemoved: (@Sendable () -> Void)?
    private let trackingRecords: (@Sendable () async -> Void)?
    private let recordRead: (@Sendable (UUID) async -> Void)?
    /// Called by a clean-up between its two reads of the paths still in use.
    let usedPathsReading: (@Sendable () async -> Void)?
    /// Called by a cover hand-off between its first read of the local item and its read of the
    /// records.
    let coverHandOffReading: (@Sendable () async -> Void)?

    /// Items with an enqueue, control, deletion or completion under way, by their item-level
    /// key (no episode). Each of these holds its item (``holdingItem(_:_:)``), so two calls for
    /// the same media can't both plan a record across the actor's suspension points, two
    /// episodes of one podcast can't both plan the shared cover, a cancel or deletion can't
    /// interleave with an enqueue of the same item, and a completion is reported and linked
    /// before or after a deletion of its item, not during it.
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
    /// How many times a record stopped being tracked (``forget(_:)``); a read of records that
    /// overlapped one is made again (``readSettled(_:)``).
    private var forgotten = 0
    // Known limitation: a relaunch before the next episode completes loses a refused cover.
    /// Covers of items to fetch again at the item's next episode completion
    /// (``restoreCover(after:itemID:)``), by item-level key: one nothing took over while the
    /// item had no local item (``handOffCover(_:of:)``) and episode records of it remained, or
    /// one whose refetch failed for good (``dropFailedRefetch(_:)``). Dropped once used, or when
    /// an episode completes into a deleted item and no record of the item is left. In memory
    /// only.
    var refusedCovers: [MediaKey: CoverSource] = [:]
    /// Records the system paused rather than the user, by who holds the pause: a policy restart
    /// (``restartActiveTransfers()``) or a credential replacement's cleanup
    /// (``pause(recordID:owner:)``). A user pause, resume, retry or cancel takes it back, so only
    /// the holder's ``resume(recordID:owner:unlessQuiescedSince:)`` resumes the record, and only
    /// until then. In memory only.
    var systemPauses: [UUID: UUID] = [:]

    /// - Parameters:
    ///   - store: the same actor the engine uses.
    ///   - capacity: ``VolumeStorageCapacity`` in the app.
    ///   - clock: paces progress events.
    ///   - progressLinking: links local progress to downloaded media (``LocalProgressStoreLinker``
    ///     in the app); `nil` keeps no links.
    public init(
        store: DownloadStore,
        localItems: LocalItemStore,
        engine: any DownloadEngineControlling,
        locations: DownloadLocations,
        capacity: any StorageCapacityProviding,
        clock: any Clock<Duration> = ContinuousClock(),
        progressLinking: (any LocalProgressLinking)? = nil
    ) {
        self.init(
            store: store, localItems: localItems, engine: engine, locations: locations, capacity: capacity,
            clock: clock, progressLinking: progressLinking, enqueueWaiting: nil, progressHandled: nil,
            subscriberRemoved: nil)
    }

    init(
        store: DownloadStore,
        localItems: LocalItemStore,
        engine: any DownloadEngineControlling,
        locations: DownloadLocations,
        capacity: any StorageCapacityProviding,
        clock: any Clock<Duration>,
        progressLinking: (any LocalProgressLinking)? = nil,
        enqueueWaiting: (@Sendable (MediaKey) -> Void)?,
        progressHandled: (@Sendable (DownloadProgress) -> Void)?,
        subscriberRemoved: (@Sendable () -> Void)? = nil,
        trackingRecords: (@Sendable () async -> Void)? = nil,
        recordRead: (@Sendable (UUID) async -> Void)? = nil,
        usedPathsReading: (@Sendable () async -> Void)? = nil,
        coverHandOffReading: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.localItems = localItems
        self.engine = engine
        self.locations = locations
        planner = DownloadPlanner(locations: locations)
        self.capacity = capacity
        self.clock = clock
        self.progressLinking = progressLinking
        self.enqueueWaiting = enqueueWaiting
        self.progressHandled = progressHandled
        self.subscriberRemoved = subscriberRemoved
        self.trackingRecords = trackingRecords
        self.recordRead = recordRead
        self.usedPathsReading = usedPathsReading
        self.coverHandOffReading = coverHandOffReading
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
            var records: [DownloadRecordDTO] = []
            do {
                records = try await readSettled({ try await self.store.allRecords() })
                for record in records where tracked[record.id] == nil {
                    track(record)
                }
            } catch {
                logError("Couldn't read downloads to track", error)
            }
            // A refetch whose failure was saved before the process ended: nothing resumes it.
            // One too large stays dropped, as its update would have.
            for record in records where record.isCoverOnly && record.state == .failed {
                let tooLarge = record.parts.contains { DownloadEngine.failedAsTooLarge($0.lastError) }
                await dropFailedRefetch(record.id, code: tooLarge ? .tooLarge : nil)
            }
            // A refetch left paused by a deletion of its local item that failed to delete it.
            for record in records where record.isCoverOnly && record.state == .paused {
                await cancelOrphanedRefetch(record.id)
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

    func emit(_ event: DownloadManagerEvent) {
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
    /// A request the user made in an account's session passes the ``quiesceGeneration()`` taken
    /// when it began as `generation`: once a sign-out, expiry or removal has stopped the server's
    /// downloads (``DownloadEngine/quiesce(connectionID:pausing:)``) under way then or since, it
    /// throws ``DownloadManagerError/downloadsStopped(_:)`` and queues nothing. It checks before
    /// its first write; the new record is then saved paused, so no activation starts it, and
    /// queued and started by ``DownloadEngine/resume(recordID:unlessQuiescedSince:)``, which
    /// checks again once it is queued: a quiesce that begins later finds it queued and pauses it
    /// with the others. A record that resume kept paused, or that failed, is deleted. An existing
    /// paused or failed record stays paused, even when the guarded resume can't pause it again.
    ///
    /// - Parameter item: an expanded item (`ItemEndpoints.item(id:)`).
    /// - Throws: a ``DownloadManagerError``.
    public func enqueue(
        item: LibraryItem, episodeID: String?, connectionID: UUID, replacingExisting: Bool = false,
        unlessQuiescedSince generation: Int? = nil
    ) async throws(DownloadManagerError) -> EnqueueResult {
        let itemKey = MediaKey(serverConnectionID: connectionID, libraryItemId: item.id)
        await beginEnqueuing(itemKey)
        defer { endEnqueuing(itemKey) }
        try await ensureNotQuiesced(connectionID, since: generation)
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: item.id, episodeId: episodeID)
        var existing = try await read { try await self.store.record(key: key) }
        // A cover-only record (#326) shares a podcast's item-level key; it isn't this download.
        if existing?.isCoverOnly == true { existing = nil }
        if let record = existing, !replacingExisting {
            if let result = try await keep(record, item: item, unlessQuiescedSince: generation) { return result }
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
        if let generation {
            // Not startable until the engine's guarded resume has checked for a quiesce.
            plan.state = .paused
            return try await startGuarded(plan, since: generation)
        }
        let record = try await read { try await self.store.upsertRecord(plan).record }
        track(record)
        emit(.recordChanged(record))
        await engine.start(partIDs: record.parts.map(\.id))
        return .started(record.id)
    }

    /// Saves a new paused `plan`, then queues and starts it with the engine's guarded resume;
    /// deletes it when the resume keeps it paused for a quiesce since `generation`, or fails.
    private func startGuarded(
        _ plan: DownloadRecordDTO, since generation: Int
    ) async throws(DownloadManagerError) -> EnqueueResult {
        let connectionID = plan.key.serverConnectionID
        let record = try await read { try await self.store.upsertRecord(plan).record }
        track(record)
        let resumed: Bool
        do throws(DownloadManagerError) {
            resumed = try await read {
                try await self.engine.resume(recordID: record.id, unlessQuiescedSince: generation)
            }
        } catch {
            await discardUnstarted(record.id)
            try await ensureNotQuiesced(connectionID, since: generation)
            throw error
        }
        guard resumed else {
            await discardUnstarted(record.id)
            try await ensureNotQuiesced(connectionID, since: generation)
            // Deleted by something else before the resume read it.
            throw .storeFailure
        }
        await refresh(record.id, announce: true)
        return .started(record.id)
    }

    /// Deletes a new record nothing started; one that can't be deleted is paused instead, so no
    /// activation starts it.
    private func discardUnstarted(_ recordID: UUID) async {
        forget(recordID)
        do {
            _ = try await read { try await self.store.deleteRecord(recordID) }
        } catch {
            _ = try? await read { try await self.store.setState(.paused, forRecord: recordID) }
        }
    }

    /// The engine's quiesce count now, for the `unlessQuiescedSince` of
    /// ``enqueue(item:episodeID:connectionID:replacingExisting:unlessQuiescedSince:)``.
    public func quiesceGeneration() async -> Int {
        await engine.quiesceGeneration()
    }

    /// Throws ``DownloadManagerError/downloadsStopped(_:)`` if a quiesce of `connectionID` was under
    /// way at, or began since, `generation`.
    private func ensureNotQuiesced(_ connectionID: UUID, since generation: Int?) async throws(DownloadManagerError) {
        guard let generation, await engine.hasQuiesced(connectionID: connectionID, since: generation) else { return }
        throw .downloadsStopped(connectionID)
    }

    /// Waits until no other enqueue, control or deletion of the item is under way, then claims it.
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

    /// Runs `body` while it holds the item of `key` (see ``enqueuing``). Not reentrant: `body`
    /// must not hold the same item again.
    func holdingItem<T: Sendable, Failure: Error>(
        _ key: MediaKey, _ body: () async throws(Failure) -> T
    ) async throws(Failure) -> T {
        let itemKey = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        await beginEnqueuing(itemKey)
        defer { endEnqueuing(itemKey) }
        return try await body()
    }

    /// Keeps an existing record, resuming it when it is paused or failed and its remaining bytes
    /// fit; `nil` when the record is gone by the time it is resumed.
    private func keep(
        _ record: DownloadRecordDTO, item: LibraryItem, unlessQuiescedSince generation: Int?
    ) async throws(DownloadManagerError) -> EnqueueResult? {
        if tracked[record.id] == nil { track(record) }
        switch record.state {
        case .paused, .failed:
            // The disk may have filled since it was queued (it may have failed `outOfSpace`).
            try await checkCapacity(for: record, item: item)
            let resumed: Bool
            do throws(DownloadManagerError) {
                resumed = try await read {
                    if let generation {
                        try await self.engine.resume(recordID: record.id, unlessQuiescedSince: generation)
                    } else {
                        try await self.engine.resume(recordID: record.id)
                    }
                }
            } catch {
                if let generation,
                    await engine.hasQuiesced(connectionID: record.key.serverConnectionID, since: generation)
                {
                    // A guarded resume that queued the record but couldn't pause it again: paused,
                    // as the quiesce leaves its other records (``restartActiveTransfers()``).
                    _ = try? await read {
                        try await self.store.setState(.paused, forRecord: record.id, expecting: [.queued])
                    }
                    throw .downloadsStopped(record.key.serverConnectionID)
                }
                throw error
            }
            guard resumed else {
                // Kept paused by a quiesce, so it still exists; else finalised or deleted.
                try await ensureNotQuiesced(record.key.serverConnectionID, since: generation)
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
    /// - `completedUpdatedAt`: when that cover was updated, from its record's snapshot.
    /// A pending cover part of a paused or failed record counts for neither: the plan fetches
    /// its own. A cover-only record of the item (whose key is the item's) counts too.
    func existingCover(
        for key: MediaKey, localItem: LocalLibraryItemDTO?
    ) async throws(DownloadManagerError) -> (
        pendingPath: String?, completed: DownloadPartDTO?, completedUpdatedAt: Date?
    ) {
        if let path = localItem?.coverRelativePath { return (path, nil, nil) }
        let records = try await read { try await self.store.records(serverConnectionID: key.serverConnectionID) }
        let siblings = records.filter {
            $0.key.libraryItemId == key.libraryItemId && ($0.key != key || $0.isCoverOnly)
        }
        let covers = siblings.compactMap { record in
            record.parts.first { $0.kind == .cover }.map { (record, $0) }
        }
        let locations = locations
        let stored = covers.first { _, part in
            part.state == .completed
                && (try? locations.fileURL(forRelativePath: part.destinationRelativePath))
                    .map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        if let stored { return (nil, stored.1, stored.0.media.coverUpdatedAt) }
        let pending = covers.first { record, part in
            part.state != .completed && (record.state == .queued || record.state == .downloading)
        }
        return (pending?.1.destinationRelativePath, nil, nil)
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
            // Clamped first: a negative size from the server would underflow the subtraction.
            let reported = max(Int64(Self.reportedSize(of: item, episodeID: record.key.episodeId) ?? 0), 0)
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
            // A record cancelled meanwhile isn't tracked any more, and isn't reported again.
            guard !willRetry, let record = tracked[recordID] else { break }
            if record.isCoverOnly {
                await dropFailedRefetch(recordID, code: code)
            } else {
                emit(.failed(recordID: recordID, code: code, message: message))
            }
        case .recordComplete(let recordID, let itemID):
            await complete(recordID, as: itemID)
        case .recordDiscarded(let record):
            await discard(record)
        case .sessionUnavailable(let code, _):
            Log.downloads.error("Downloads are waiting for the session: \(code.rawValue, privacy: .public)")
        case .recordStarted(let recordID):
            await refresh(recordID, announce: true)
        }
    }

    /// Reports a record that became the local item `itemID`, and links its progress, while it
    /// holds the item, so this runs before or after a deletion of the item, never during it.
    /// Media deleted before this ran (the local item, or the episode, deleted while the engine
    /// finalised the record or after) is reported as
    /// ``DownloadManagerEvent/recordRemoved(recordID:)`` and not linked, as is a cover-only
    /// record, which downloaded no media, and whose file is removed unless the item took it. An
    /// episode completing into a local item without a cover may give it one
    /// (``restoreCover(after:itemID:)``).
    private func complete(_ recordID: UUID, as itemID: UUID) async {
        let isCoverOnly = tracked[recordID]?.isCoverOnly == true
        let fetchedCover = tracked[recordID]?.fetchedCover
        var key = forget(recordID)
        if key == nil { key = await bookKey(ofLocalItem: itemID) }
        guard let key else {
            // A podcast's record (an episode, or a cover-only one) can't be told from its item.
            Log.downloads.fault("A download completed that the manager didn't track and isn't a book")
            return
        }
        await holdingItem(key) {
            let downloaded: Bool
            do {
                // Another episode can keep the item after this one was deleted.
                downloaded = try await localItems.item(id: itemID).map { Self.hasDownloaded(key, in: $0) } ?? false
            } catch {
                // Reported as completed: the engine just saved the item.
                logError("Couldn't read a downloaded item", error)
                downloaded = true
            }
            guard downloaded, !isCoverOnly else {
                reportRemoved(recordID)
                // A refetched cover the item didn't take, as it had one by then, goes.
                if let fetchedCover {
                    await cleanUp(after: key, removing: [fetchedCover], folder: nil, cover: nil)
                }
                if !isCoverOnly, key.episodeId != nil { await dropRefusedCoverIfUnused(key) }
                return
            }
            await linkProgress(key: key, itemID: itemID)
            emit(.completed(recordID: recordID, itemID: itemID, key: key))
            if key.episodeId != nil { await restoreCover(after: key, itemID: itemID) }
        }
    }

    /// The key of a downloaded book, for a record that wasn't tracked. An episode's key can't be
    /// told from its local item, so an episode record the manager never tracked (saved after
    /// ``start()`` by something other than ``enqueue(item:episodeID:connectionID:replacingExisting:unlessQuiescedSince:)``,
    /// and gone before any of its updates was handled) completes without a
    /// ``DownloadManagerEvent/completed(recordID:itemID:key:)`` event.
    private func bookKey(ofLocalItem itemID: UUID) async -> MediaKey? {
        guard let item = try? await localItems.item(id: itemID), item.mediaType == .book else { return nil }
        return MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)
    }

    /// Links local progress to the downloaded media; a failure is logged.
    private func linkProgress(key: MediaKey, itemID: UUID) async {
        guard let progressLinking else { return }
        do {
            try await progressLinking.link(key: key, itemID: itemID)
        } catch {
            logError("Couldn't link progress to a download", error)
        }
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

    func track(_ record: DownloadRecordDTO) {
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
            completed: Set(record.parts.filter { $0.state == .completed }.map(\.id)), isCoverOnly: record.isCoverOnly,
            fetchedCover: record.isCoverOnly ? record.parts.first?.destinationRelativePath : nil)
    }

    /// Stops tracking a record; returns its key. A refresh that read the record before reads
    /// again (``readSettled(_:)``), so it doesn't track it again or report it after this.
    @discardableResult
    func forget(_ recordID: UUID) -> MediaKey? {
        forgotten &+= 1
        progressWindows.removeValue(forKey: recordID)?.cancel()
        pendingProgress.remove(recordID)
        return tracked.removeValue(forKey: recordID)?.key
    }

    /// Stops tracking a record that is gone and left no local item, and reports it with
    /// ``DownloadManagerEvent/recordRemoved(recordID:)``; nothing about it is reported after.
    func reportRemoved(_ recordID: UUID) {
        forget(recordID)
        emit(.recordRemoved(recordID: recordID))
    }

    /// Reads a record again and tracks it; with `announce`, reports it.
    func refresh(_ recordID: UUID, announce: Bool) async {
        let record: DownloadRecordDTO?
        do {
            record = try await readSettled {
                let record = try await self.store.record(id: recordID)
                await self.recordRead?(recordID)
                return record
            }
        } catch {
            logError("Couldn't read a download", error)
            return
        }
        // A record that is gone was finalised or deleted; its key is kept for `recordComplete`.
        guard let record else { return }
        track(record)
        if announce { emit(.recordChanged(record)) }
    }

    /// Runs `body` until no record was forgotten while it ran, so what it read doesn't include
    /// a record deleted, replaced or completed meanwhile.
    private func readSettled<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        while true {
            let before = forgotten
            let value = try await body()
            if forgotten == before { return value }
        }
    }

    // MARK: - Helpers

    /// `a + b` of non-negative values, or `Int64.max` when that overflows.
    static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    /// Runs a store call, mapping its error.
    func read<T: Sendable>(_ body: () async throws -> T) async throws(DownloadManagerError) -> T {
        do {
            return try await body()
        } catch DownloadStore.StoreError.connectionNotFound(let id) {
            throw .connectionNotFound(id)
        } catch {
            logError("A download store call failed", error)
            throw .storeFailure
        }
    }

    nonisolated func logError(_ message: String, _ error: any Error) {
        Log.downloads.error(
            "\(message, privacy: .public): \(Log.redact(String(describing: error)), privacy: .public)")
    }
}
