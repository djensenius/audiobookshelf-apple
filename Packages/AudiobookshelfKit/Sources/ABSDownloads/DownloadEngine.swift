import ABSAPI
import ABSCore
import ABSData
import Foundation

/// Why a part failed. Stable, unlike the English message.
public enum DownloadFailureCode: String, Sendable, Equatable {
    /// The transfer failed (network, timeout, server error status).
    case transfer
    /// The server answered with a status that won't change on retry.
    case httpStatus
    /// The server rejected the access token again after a refresh.
    case unauthorized
    /// A redirect dropped the `Authorization` header and the new address answered 401.
    case redirectedUnauthorized
    /// A redirect left the server: the foreground check refused it before the transfer, or the
    /// background transfer's body was discarded.
    case offOrigin
    /// The body was an error page or message (HTML, text, JSON or XML), not the file.
    case unexpectedContent
    /// The body's size isn't the file's size.
    case sizeMismatch
    /// The file is larger than its kind allows (a cover over
    /// ``DownloadEngine/maxCoverBytes``); the transfer was stopped.
    case tooLarge
    /// The file couldn't be moved into place.
    case fileSystem
    /// The device is out of space.
    case outOfSpace
    /// No credentials: the connection is signed out or the refresh failed.
    case credentials
    /// The download's state couldn't be saved. Counts as a failure, so the part fails for
    /// good with this code once the retries are used up.
    case store
    /// The part's destination path is invalid.
    case invalidDestination
    /// Another process holds the background session; downloads stop until the next
    /// ``DownloadEngine/activate()``.
    case sessionInUse
    /// The background session kept disconnecting; downloads wait for the next
    /// ``DownloadEngine/activate()``.
    case sessionLost
    /// The connection sends custom headers. A background session follows a redirect of the
    /// transfer itself, or of a resumed transfer's `Range` request, without asking its delegate,
    /// so the redirect check can't keep them on the server. Refused until such downloads run in
    /// the foreground (follow-up #467).
    case customHeadersUnsupported
}

/// A durable change the engine reports. Every update is delivered; live progress is on
/// ``DownloadEngine/progress``, and ``DownloadStore`` holds the durable state.
public enum DownloadUpdate: Sendable, Equatable {
    case partCompleted(partID: UUID, recordID: UUID)
    /// `willRetry` is `false` when the part failed for good: its record is now `failed`, and
    /// its other parts are stopped (keeping their resume data) and queued.
    case partFailed(partID: UUID, recordID: UUID, code: DownloadFailureCode, message: String, willRetry: Bool)
    /// Every part completed: the record is now the local item `itemID` and was deleted.
    case recordComplete(recordID: UUID, itemID: UUID)
    /// A cover-only record (`DownloadRecordDTO.isCoverOnly`) completed after its local item
    /// was deleted: it was deleted as it was then, and its cover file is left on disk.
    case recordDiscarded(DownloadRecordDTO)
    /// The engine has no working session (`sessionInUse` or `sessionLost`); the affected
    /// parts are queued.
    case sessionUnavailable(code: DownloadFailureCode, message: String)
    /// A part started and moved its record from `queued` to `downloading`: its first start, a
    /// resume, or a transfer adopted after a relaunch. Not sent when the record was already
    /// `downloading`, as for its other parts.
    case recordStarted(recordID: UUID)
}

/// A part's live progress, throttled to about every 1% or 1 second.
public struct DownloadProgress: Sendable, Equatable {
    public var partID: UUID
    public var recordID: UUID
    public var bytesWritten: Int64
    public var expectedBytes: Int64
}

/// Downloads the parts of ``DownloadStore`` records with one background `URLSession` task
/// per part (#72).
///
/// - Each task's `taskDescription` is its part ID, which is how tasks are matched to parts
///   after a relaunch; the store's `taskIdentifier` is only a cache.
/// - A task is only created once ``DownloadStore/beginRunning(partID:expecting:now:)`` has
///   moved its part to `running`, so a launch from a stale read can't restart a part that has
///   since completed, been stopped, failed for good or been deleted. A transfer that survived
///   a relaunch is only adopted the same way; otherwise it stops, keeping its resume data.
/// - Requests carry `Authorization: Bearer` and the custom headers, never `?token=`. The
///   access token is refreshed (or checked) before each task is created or resumed; a 401 for
///   the current token recreates the task from a fresh request once.
/// - Resume data from failed transfers is sealed in a ``ResumeDataVault`` and only used while
///   the credentials and network access it was created with are current (ADR 0007).
/// - Failures are retried with ``RetryPolicy`` backoff: in the foreground after a wait in the
///   process, in the background as a new task whose `earliestBeginDate` is the delay, created
///   before the wake is released. The count is the store's `retryCount`, so it carries over a
///   relaunch; only ``start(partIDs:)`` (and ``resume(recordID:)``) start it over. When a part
///   fails for good, its record fails and its other parts stop, keeping their resume data.
/// - A file a transfer moved into place, but whose completion wasn't saved before the process
///   ended, completes its part at the next activation. Only the part's current transfer
///   counts: each launch starts a new generation (see ``DownloadLocations``), so a file from an
///   earlier one is downloaded again.
/// - A complete record becomes a local item (`LocalItemStore.upsertFromDownload(_:)`) and is
///   deleted; activation repeats that for complete records left by a crash (ADR 0003).
///
/// Call ``activate()`` when the app comes to the foreground: it restarts the queued parts,
/// and until ``deactivate()`` (when the app goes to the background) a part the user's force
/// quit cancelled restarts at once. A background wake (``handleBackgroundEvents()``) only
/// handles the session's events. Create one engine per process: a background session
/// identifier may only be used by one session at a time.
public actor DownloadEngine {
    public static let sessionIdentifier = URLSessionConfiguration.absDownloadsIdentifier
    /// Restarts per part and activation that don't count as failures (a system cancellation
    /// or a lost session); later ones go through the ``RetryPolicy``.
    static let maxFreeRestarts = 3
    /// Session recreations after it was lost, each after a ``RetryPolicy`` delay, before the
    /// engine waits for the next ``activate()``.
    static let maxSessionRecreations = 3
    /// Attempts, a second apart, to save failed writes before a background wake is released.
    static let maxWakeSaveAttempts = 3

    /// The most a cover part may download. A cover's size is never known in advance, so a
    /// transfer, or a declared length, over this fails the part for good with
    /// ``DownloadFailureCode/tooLarge``, as it goes rather than once the body is on disk.
    static let maxCoverBytes: Int64 = 20 * 1024 * 1024

    /// A launch for a connection with custom headers (``DownloadFailureCode/customHeadersUnsupported``).
    private struct CustomHeadersRefused: Error {}

    private struct PartContext {
        var recordID: UUID
        var connectionID: UUID
        var serverPath: String
        var destination: URL?
        var expectedBytes: Int64
        var hasResumeData: Bool
        var maxBytes: Int64?
    }

    /// Durable changes, for one consumer. Nothing is dropped.
    public nonisolated let updates: AsyncStream<DownloadUpdate>
    /// Live progress, for one consumer. Only the newest events are kept if it falls behind.
    public nonisolated let progress: AsyncStream<DownloadProgress>
    private let updateContinuation: AsyncStream<DownloadUpdate>.Continuation
    private let progressContinuation: AsyncStream<DownloadProgress>.Continuation
    private let store: DownloadStore
    private let localItems: LocalItemStore
    private let credentials: any DownloadCredentialProviding
    private let vault: ResumeDataVault
    /// Only a store in the App Group lists every download; a fallback store would make the
    /// shared resume data look unreferenced.
    private let sweepsOrphanedResumeData: Bool
    private let locations: DownloadLocations
    private let retryPolicy: RetryPolicy
    private let networkAccess: @Sendable () async -> NetworkAccess
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let makeSession: DownloadSessionFactory
    private let preflight: any DownloadRedirectPreflighting
    private let registry: DownloadEngineRegistry
    private let readRecords: @Sendable (DownloadStore) async throws -> [DownloadRecordDTO]
    private let readRecord: @Sendable (DownloadStore, UUID) async throws -> DownloadRecordDTO?
    private let cancelKeepingResumeData: @Sendable (URLSessionDownloadTask) async -> Data?
    /// Test seams, optional so production makes no actor hop for them.
    private let beforeStoppingSiblings: (@Sendable (UUID) async -> Void)?
    private let afterPermanentFailure: (@Sendable (UUID) async -> Void)?
    /// Between a failure replay's record write and its start.
    private let beforeReplayStart: (@Sendable (UUID) async -> Void)?
    private let startFoundSettling: (@Sendable (Set<UUID>) async -> Void)?
    private let adoptionStarted: (@Sendable (UUID) async -> Void)?
    /// Before a discard clears a part's resume-data flag; throwing fails that write.
    private let beforeClearingResumeFlag: (@Sendable (UUID) async throws -> Void)?
    /// After a finalisation made a record a local item, before it deletes the record.
    private let afterUpsertingLocalItem: (@Sendable (UUID) async -> Void)?
    /// Internal so tests can post events.
    let delegate = DownloadSessionDelegate()

    private var activation: Task<Bool, Never>?
    private var session: (any DownloadSession)?
    private var isEventLoopRunning = false
    private var isInvalidatingSession = false
    /// Set by ``activate()`` and cleared by ``deactivate()``: a part the user's force quit
    /// cancelled is restarted at once.
    private var restartsQueuedParts = false
    /// Set by ``deactivate()`` and background wakes, and cleared by ``activate()``: iOS can
    /// suspend the process at any time, so a retry's transfer is created at once and begins
    /// after its delay (`earliestBeginDate`) instead of waiting in the process.
    private var isInBackground = false
    /// Restarts that didn't count as failures since ``activate()``.
    private var freeRestarts: [UUID: Int] = [:]
    /// Session recreations since the last moved file or ``activate()``.
    private var sessionRecreations = 0
    /// Another process holds the session identifier; set until the next ``activate()``.
    private var isSessionInUse = false
    private var contexts: [UUID: PartContext] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// A token per launch in progress; ``stop(partIDs:keepingResumeData:)`` removes it.
    private var launching: [UUID: UUID] = [:]
    /// Each launch's redirect check in progress; cancelled where its marker is removed, so the
    /// check's request can't follow a redirect with the old credentials after a sign-out.
    private var preflights: [UUID: Task<URLRequest, any Error>] = [:]
    /// Parts to launch once the session is created again.
    private var deferredLaunches: Set<UUID> = []
    /// Parts being completed or failed for good; they keep their context (so a concurrent
    /// read doesn't bring back their old state) but can't launch.
    private var settling: Set<UUID> = []
    /// Parts a plain ``start(partIDs:)`` (not a record resume) asked for while they were
    /// settling; one that was failing for good starts once that is settled.
    private var plainStartsAfterSettling: Set<UUID> = []
    /// Moved files whose completion couldn't be saved yet, with their sizes. The part stays
    /// settling until ``saveCompletion(_:)`` succeeds.
    private var unsavedCompletions: [UUID: Int64] = [:]
    /// Parts the store still has as `running` because writing their idle state failed. No
    /// transfer of this engine has them, so their next launch accepts `running`.
    private var strandedRunning: Set<UUID> = []
    /// Stops under way: until one has queued its part, the store still has it `running`.
    private var stopping: [UUID: Task<Void, Never>] = [:]
    /// The last resume-data sweep failed; the next ``activate()`` runs it again.
    private var isResumeDataSweepPending = false
    /// Parts sealed while a retried sweep reads the records, which it keeps; `nil` otherwise.
    private var sealedDuringSweep: Set<UUID>?
    /// The last ``pause(recordID:)`` or ``resume(recordID:)`` of each record; each waits for
    /// the one before it.
    private var recordOperations: [UUID: Task<Void, Never>] = [:]
    /// Resumes that haven't reached the part-start section yet. Failures during this interval
    /// must leave the record startable by the resume.
    private var resumingRecords: Set<UUID> = []
    /// Incremented synchronously when a resume begins, before its first store await. One `Int`
    /// per record that was ever resumed, kept until the engine goes away.
    private var resumeGenerations: [UUID: Int] = [:]
    /// Records whose latest resume is an automatic one (``resume(recordID:unlessQuiescedSince:)``
    /// with a generation), which starts nothing between a ``deactivate()`` and the next
    /// ``activate()``; a failure's replay of it keeps that restriction.
    private var guardedResumes: Set<UUID> = []
    /// A part gets one stale-failure replay per user resume; a replay's own failure stays final.
    /// One `Int` per part that was ever replayed, kept until the engine goes away.
    private var replayedResumeGenerationByPart: [UUID: Int] = [:]
    /// The parts failing for good, by record (a part twice while its replay's launch fails it
    /// again), and those whose failure overlapped another part's of the same record. A plain
    /// start's replay of an overlapping failure leaves the record `failed`, so it can't strand
    /// the other part as failed. Only failures under way.
    private var failingForGood: [UUID: [UUID]] = [:]
    private var overlappingFailures: Set<UUID> = []
    /// Records whose `failed` state couldn't be saved after a part failed for good. Their parts
    /// can't launch until ``reconcile()`` saves it.
    private var pendingRecordFailures: Set<UUID> = []
    /// The connections of the failures for good under way, from the start of their handling
    /// until their replay has started, and the ``quiesce(connectionID:pausing:)`` calls waiting
    /// for them.
    private var failingConnections: [UUID] = []
    private var failureWaiters: [CheckedContinuation<Void, Never>] = []
    /// Internal so tests can tell when ``quiesce(connectionID:pausing:)`` waits for a failure.
    var failureWaiterCount: Int { failureWaiters.count }
    /// The connections being quiesced, one entry per call: a failure's replay doesn't queue
    /// their records again.
    private var quiescingConnections: [UUID] = []
    /// Counts the ``quiesce(connectionID:pausing:)`` calls that ended, and the count at each
    /// connection's last one, so a resume can tell whether one was under way at, or began
    /// since, a point (``quiesceGeneration()``).
    private var quiesceCount = 0
    private var lastQuiesces: [UUID: Int] = [:]
    /// Connections quiesced: their transfers that survived a relaunch (any task this engine
    /// didn't create) are cancelled, not adopted, and their results dropped, for the rest of the
    /// process; they carry the credentials of before the sign-out. Each is also marked on disk
    /// (``DownloadLocations/markSurvivorsToStop(connectionID:)``) until a session listing has
    /// cancelled its survivors and its resume data is deleted, so a relaunch before that still
    /// does both; each activation reads the markers again before it lists the session's tasks.
    private var survivorsToStop: Set<UUID> = []
    /// Connections whose resume data isn't known to be deleted: being quiesced, or a quiesce or
    /// activation couldn't delete it. ``finalise(_:)`` leaves their complete records, so the
    /// parts that lead to the blobs stay for the next try.
    private var undiscardedSignOuts: Set<UUID> = []
    /// The identifiers of the tasks this engine created, so they aren't taken for survivors.
    private var createdTasks: Set<Int> = []
    /// The parts this engine marked a transfer start for, so a file a survivor moved isn't
    /// taken for theirs (see ``performActivation()``).
    private var markedTransfers: Set<UUID> = []
    /// Surviving transfers whose adoption ``reattach(_:partID:)`` is deciding, and the results
    /// they finished with meanwhile: those are handled only once the transfer is adopted.
    private var adopting: Set<Int> = []
    private var heldResults: [Int: DownloadTaskResult] = [:]
    /// Records being finalised, so a completion and ``activate()`` don't finalise one twice.
    private var finalising: Set<UUID> = []
    private var retries: [UUID: Task<Void, Never>] = [:]
    /// Failures counted toward ``RetryPolicy``'s limit: the store's `retryCount`, read with the
    /// part's context, so a relaunch doesn't start the count over. ``start(partIDs:)`` resets
    /// both.
    private var failures: [UUID: Int] = [:]
    private var authRetried: Set<UUID> = []
    /// Tasks of the current session whose completion is ignored (cancelled or not ours).
    private var ignoredTasks: Set<Int> = []
    private var throttle = ProgressThrottle()
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    /// The restart of queued parts that the last ``activate()`` began.
    private var restart: Task<Void, Never>?
    /// Events-finished calls that came before their wake asked for them.
    private(set) var unclaimedBackgroundFinishes = 0
    /// Wakes waiting for their events-finished call.
    var backgroundWaiterCount: Int { backgroundWaiters.count }
    /// Background event completions held until a disconnect's replacement tasks are submitted.
    private var backgroundFinishesAwaitingRecreation = 0

    /// - Parameters:
    ///   - networkAccess: the request flags for the current download cellular policy, read
    ///     when each task is created.
    ///   - makeSession: ``backgroundSession()`` in the app.
    ///   - preflight: checks each request's redirects before its background task is made.
    ///   - sweepsOrphanedResumeData: whether activation deletes resume data no record
    ///     references; pass `true` only when `store` is the App Group store.
    public init(
        store: DownloadStore,
        localItems: LocalItemStore,
        credentials: any DownloadCredentialProviding,
        vault: ResumeDataVault,
        sweepsOrphanedResumeData: Bool = false,
        locations: DownloadLocations,
        retryPolicy: RetryPolicy = .default,
        networkAccess: @escaping @Sendable () async -> NetworkAccess,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        makeSession: @escaping DownloadSessionFactory = DownloadEngine.backgroundSession(),
        preflight: any DownloadRedirectPreflighting = DownloadRedirectPreflight()
    ) {
        self.init(
            store: store, localItems: localItems, credentials: credentials, vault: vault,
            sweepsOrphanedResumeData: sweepsOrphanedResumeData, locations: locations,
            retryPolicy: retryPolicy, networkAccess: networkAccess, clock: clock, now: now, random: random,
            makeSession: makeSession, registry: .shared, readRecords: { try await $0.allRecords() },
            readRecord: { try await $0.record(id: $1) },
            cancelKeepingResumeData: { await $0.cancelByProducingResumeData() }, preflight: preflight)
    }

    init(
        store: DownloadStore,
        localItems: LocalItemStore,
        credentials: any DownloadCredentialProviding,
        vault: ResumeDataVault,
        sweepsOrphanedResumeData: Bool = false,
        locations: DownloadLocations,
        retryPolicy: RetryPolicy,
        networkAccess: @escaping @Sendable () async -> NetworkAccess,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date,
        random: @escaping @Sendable () -> Double,
        makeSession: @escaping DownloadSessionFactory,
        registry: DownloadEngineRegistry,
        readRecords: @escaping @Sendable (DownloadStore) async throws -> [DownloadRecordDTO],
        readRecord: @escaping @Sendable (DownloadStore, UUID) async throws -> DownloadRecordDTO?,
        cancelKeepingResumeData: @escaping @Sendable (URLSessionDownloadTask) async -> Data?,
        beforeStoppingSiblings: (@Sendable (UUID) async -> Void)? = nil,
        afterPermanentFailure: (@Sendable (UUID) async -> Void)? = nil,
        beforeReplayStart: (@Sendable (UUID) async -> Void)? = nil,
        startFoundSettling: (@Sendable (Set<UUID>) async -> Void)? = nil,
        adoptionStarted: (@Sendable (UUID) async -> Void)? = nil,
        beforeClearingResumeFlag: (@Sendable (UUID) async throws -> Void)? = nil,
        afterUpsertingLocalItem: (@Sendable (UUID) async -> Void)? = nil,
        preflight: any DownloadRedirectPreflighting = DownloadRedirectPreflight()
    ) {
        (updates, updateContinuation) = AsyncStream.makeStream()
        (progress, progressContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.store = store
        self.localItems = localItems
        self.credentials = credentials
        self.vault = vault
        self.sweepsOrphanedResumeData = sweepsOrphanedResumeData
        self.locations = locations
        self.retryPolicy = retryPolicy
        self.networkAccess = networkAccess
        self.clock = clock
        self.now = now
        self.random = random
        self.makeSession = makeSession
        self.preflight = preflight
        self.registry = registry
        self.readRecords = readRecords
        self.readRecord = readRecord
        self.cancelKeepingResumeData = cancelKeepingResumeData
        self.beforeStoppingSiblings = beforeStoppingSiblings
        self.afterPermanentFailure = afterPermanentFailure
        self.beforeReplayStart = beforeReplayStart
        self.startFoundSettling = startFoundSettling
        self.adoptionStarted = adoptionStarted
        self.beforeClearingResumeFlag = beforeClearingResumeFlag
        self.afterUpsertingLocalItem = afterUpsertingLocalItem
        registry.register(self)
    }

    // MARK: - Public API

    /// Creates the session if needed, reattaches to the transfers that survived a relaunch,
    /// and restarts the parts of `queued` and `downloading` records that have no transfer.
    /// Call it when the app comes to the foreground. It also resets the restarts that don't
    /// count as failures, lets a lost session be created again, and tries once more to create
    /// a session that another process held.
    ///
    /// - Returns: `false` when the downloads couldn't be read (nothing was cancelled or
    ///   restarted, and a later call tries again) or another process holds the session.
    @discardableResult
    public func activate() async -> Bool {
        freeRestarts.removeAll()
        sessionRecreations = 0
        isSessionInUse = false
        guard await ensureSession() else { return false }
        restartsQueuedParts = true
        isInBackground = false
        delegate.post(.restartQueued)
        await retryResumeDataSweep()
        return true
    }

    /// Creates the session if needed, reattaching to the transfers that survived a relaunch,
    /// without restarting queued parts or changing what ``activate()`` and ``deactivate()``
    /// set. A ``pause(recordID:)`` before the session exists can't stop a surviving transfer,
    /// and a resume after it lets activation adopt that transfer as it is, so
    /// ``DownloadManager/restartActiveTransfers()`` calls this first.
    ///
    /// - Returns: `false` when there is no session: the downloads couldn't be read, or another
    ///   process holds it.
    public func attachSurvivingTransfers() async -> Bool {
        await ensureSession()
    }

    /// Call when the app goes to the background: until the next ``activate()``, parts the
    /// system cancels are queued, not restarted, because a background wake can't start
    /// transfers reliably, and a retry's transfer is created at once, to begin after its delay.
    public func deactivate() {
        restartsQueuedParts = false
        isInBackground = true
    }

    /// ``deactivate()`` on the process's engine, if it has one.
    public static func deactivate() async {
        await DownloadEngineRegistry.shared.current?.deactivate()
    }

    /// Starts (or restarts) the given parts; parts that are already transferring are left
    /// alone, apart from their retry budget, which starts over (in the store too) for every
    /// part that isn't settling. A part being completed or failed for good is skipped entirely:
    /// a completion's save retry keeps its timer, and a failure for good starts the part once it
    /// is settled, with the budget reset then. Set their records to `queued` (or `downloading`)
    /// first: ``DownloadStore/beginRunning(partID:expecting:now:)`` refuses parts of `paused`
    /// and `failed` records, and a `failed` state the engine couldn't save is dropped.
    ///
    /// A plain start of some parts of a record doesn't restart the siblings that a failure it
    /// overlaps stopped; only ``resume(recordID:)`` does. If another part of the record fails for
    /// good during that failure, the record stays `failed` and the start is dropped.
    public func start(partIDs: [UUID]) async {
        await start(partIDs: partIDs, resumingRecordID: nil, resettingBudgetOf: nil)
    }

    /// - Parameters:
    ///   - resettingBudgetOf: the parts whose retry budget starts over, if they aren't
    ///     settling; `nil` for every part in `partIDs`. The replay of a failure that overlapped a
    ///     start passes the failing part only: its siblings were reset when the start began.
    ///   - onlyWhileActive: launches nothing after a ``deactivate()`` until the next
    ///     ``activate()``, which starts the parts left queued, as ``restartQueuedParts()`` does.
    private func start(
        partIDs: [UUID], resumingRecordID: UUID?, resettingBudgetOf: Set<UUID>? = nil,
        activationOwnsSession: Bool = false, onlyWhileActive: Bool = false
    ) async {
        // A replay from a failure held during reattachment runs inside performActivation's task.
        // Waiting for ensureSession here would make that task wait for itself.
        if !activationOwnsSession, !(await ensureSession()) { return }
        let records: [DownloadRecordDTO]
        do {
            records = try await loadRecords()
        } catch {
            logError("Couldn't read downloads", error)
            return
        }
        // A settling part is being completed or failed for good. One failing for good stops its
        // siblings, then forgets its context, so it starts once that is settled
        // (``failPermanently(_:code:message:)``). Which parts settle is noted before any launch
        // is awaited.
        var settlingParts: Set<UUID> = []
        for partID in partIDs {
            if let recordID = contexts[partID]?.recordID { pendingRecordFailures.remove(recordID) }
            if settling.contains(partID) { settlingParts.insert(partID) }
        }
        if let resumingRecordID {
            resumingRecords.remove(resumingRecordID)
        } else {
            plainStartsAfterSettling.formUnion(settlingParts)
        }
        if let startFoundSettling, !settlingParts.isEmpty { await startFoundSettling(settlingParts) }
        let retried = Set(records.flatMap(\.parts).filter { $0.retryCount > 0 }.map(\.id))
        let resets = resettingBudgetOf ?? Set(partIDs)
        for partID in partIDs where resets.contains(partID) && !settlingParts.contains(partID) {
            retries.removeValue(forKey: partID)?.cancel()
            let hasFailed = failures.removeValue(forKey: partID) != nil || retried.contains(partID)
            freeRestarts[partID] = nil
            authRetried.remove(partID)
            if hasFailed {
                await persist { _ = try await $0.updatePart(partID: partID, retryCount: 0) }
            }
        }
        for partID in partIDs
        where tasks[partID] == nil && !settlingParts.contains(partID) && (!onlyWhileActive || restartsQueuedParts) {
            await launch(partID, activationOwnsSession: activationOwnsSession, onlyWhileActive: onlyWhileActive)
        }
    }

    /// Cancels the given parts' transfers and queues them again. With `keepingResumeData`
    /// the transfer's resume data is sealed so a later ``start(partIDs:)`` continues it;
    /// otherwise any resume data is deleted. Set the record's state first (for example
    /// `paused`): then ``DownloadStore/beginRunning(partID:expecting:now:)`` refuses to start
    /// its parts again, from a relaunch or a launch already under way. Every part's stop is
    /// registered before any cancellation is awaited, and a launch of a part waits for its
    /// stop to finish, so a start during the stop restarts every part. Parts being completed
    /// or failed are left alone.
    public func stop(partIDs: [UUID], keepingResumeData: Bool) async {
        var stops: [(partID: UUID, stop: Task<Void, Never>)] = []
        for partID in partIDs where !settling.contains(partID) {
            retries.removeValue(forKey: partID)?.cancel()
            launching[partID] = nil
            preflights.removeValue(forKey: partID)?.cancel()
            deferredLaunches.remove(partID)
            authRetried.remove(partID)
            throttle.reset(partID)
            let task = tasks.removeValue(forKey: partID)
            if let task { ignoredTasks.insert(task.taskIdentifier) }
            // Until the cancellation returns, the store still has the part running: stops of a
            // part run in order, and its launches wait for them.
            let previous = stopping[partID]
            let stop = Task {
                await previous?.value
                await finishStopping(partID, task: task, keepingResumeData: keepingResumeData)
            }
            stopping[partID] = stop
            stops.append((partID, stop))
        }
        for (partID, stop) in stops {
            await stop.value
            if stopping[partID] == stop { stopping[partID] = nil }
        }
    }

    private func finishStopping(_ partID: UUID, task: URLSessionDownloadTask?, keepingResumeData: Bool) async {
        var hasResumeData: Bool? = keepingResumeData ? contexts[partID]?.hasResumeData : false
        if let task {
            // A finished task has no resume data to give.
            let isLive = task.state == .running || task.state == .suspended
            if keepingResumeData, isLive, let data = await cancelKeepingResumeData(task) {
                hasResumeData = seal(data, partID: partID, task: task)
            } else {
                task.cancel()
            }
        }
        // A blob that couldn't be deleted stays flagged, so a later discard deletes it.
        if !keepingResumeData, !vault.delete(partID: partID) { hasResumeData = true }
        if let hasResumeData { contexts[partID]?.hasResumeData = hasResumeData }
        await persistIdle(partID) {
            try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
        }
    }

    /// Pauses a download: its record becomes `paused`, then its transfers stop, keeping their
    /// resume data. Pauses and resumes of a record run one at a time, in call order.
    ///
    /// - Returns: `false` when the record doesn't exist, or has failed or completed meanwhile:
    ///   checked in the state's write, so a failure saved after the caller read it stays.
    @discardableResult
    public func pause(recordID: UUID) async throws -> Bool {
        try await serialized(recordID) { try await $0.performPause(recordID) }
    }

    private func performPause(_ recordID: UUID) async throws -> Bool {
        guard let record = try await readRecord(store, recordID) else { return false }
        guard try await store.setState(.paused, forRecord: recordID, expecting: [.queued, .downloading, .paused])
        else { return false }
        pendingRecordFailures.remove(recordID)
        await stop(partIDs: record.parts.filter { $0.state != .completed }.map(\.id), keepingResumeData: true)
        return true
    }

    /// Resumes a paused or failed download: its record is queued again, then its parts that
    /// haven't completed start, continuing from their resume data. Pauses and resumes of a
    /// record run one at a time, in call order.
    ///
    /// - Returns: `false` when the record doesn't exist.
    @discardableResult
    public func resume(recordID: UUID) async throws -> Bool {
        try await serialized(recordID) { try await $0.performResume(recordID, unlessQuiescedSince: nil) }
    }

    /// ``resume(recordID:)`` for a caller that paused the record itself after reading it
    /// (``DownloadManager/restartActiveTransfers()``): a quiesce of the record's server that is
    /// under way or began since `generation` (a ``quiesceGeneration()``) may have passed over
    /// the record while it was paused, so the resume pauses it instead and starts nothing: its
    /// transfers would run with the old credentials. Not one the user asked for, so between a
    /// ``deactivate()`` and the next ``activate()`` it only queues the record, whose parts that
    /// activation starts: background starts aren't reliable.
    ///
    /// - Returns: `false` when the record doesn't exist, or such a quiesce kept it paused.
    @discardableResult
    public func resume(recordID: UUID, unlessQuiescedSince generation: Int) async throws -> Bool {
        try await serialized(recordID) { try await $0.performResume(recordID, unlessQuiescedSince: generation) }
    }

    /// The quiesce count now, for ``resume(recordID:unlessQuiescedSince:)`` and
    /// ``hasQuiesced(connectionID:since:)``.
    public func quiesceGeneration() -> Int {
        quiesceCount
    }

    /// Whether a quiesce of `connectionID` is under way, or was under way at or began since
    /// `generation`.
    public func hasQuiesced(connectionID: UUID, since generation: Int) -> Bool {
        quiescingConnections.contains(connectionID) || lastQuiesces[connectionID, default: 0] > generation
    }

    private func performResume(_ recordID: UUID, unlessQuiescedSince generation: Int?) async throws -> Bool {
        resumeGenerations[recordID, default: 0] += 1
        if generation != nil {
            guardedResumes.insert(recordID)
        } else {
            guardedResumes.remove(recordID)
        }
        resumingRecords.insert(recordID)
        defer { resumingRecords.remove(recordID) }
        guard try await store.setState(.queued, forRecord: recordID),
            let record = try await readRecord(store, recordID)
        else { return false }
        // Checked once the record is queued: a quiesce that begins later finds it so and pauses it.
        if let generation, hasQuiesced(connectionID: record.key.serverConnectionID, since: generation) {
            Log.downloads.notice("Not resuming a download of a server whose downloads are being stopped")
            _ = try await store.setState(.paused, forRecord: recordID, expecting: [.queued])
            return false
        }
        await start(
            partIDs: record.parts.filter { $0.state != .completed }.map(\.id), resumingRecordID: recordID,
            onlyWhileActive: generation != nil)
        return true
    }

    /// Runs `operation` once the record's previous pause or resume has finished. Registered
    /// before anything is awaited, so a resume can't run between a pause's state write and its
    /// stops (it would find the transfers still running and leave them to the pause).
    private func serialized(
        _ recordID: UUID, _ operation: @escaping @Sendable (isolated DownloadEngine) async throws -> Bool
    ) async throws -> Bool {
        let previous = recordOperations[recordID]
        let run = Task {
            await previous?.value
            return try await operation(self)
        }
        let done = Task { _ = try? await run.value }
        recordOperations[recordID] = done
        defer { if recordOperations[recordID] == done { recordOperations[recordID] = nil } }
        return try await run.value
    }

    /// Deletes the resume data of every part of `connectionID`'s downloads, for sign-out,
    /// removal or a credential change (ADR 0003). Their next start is a fresh request. Only the
    /// parts' resume-data flags are written, so a part that failed or started since the
    /// downloads were read keeps its state. A stop of one of those parts still under way, such
    /// as a pause whose transfer is producing its resume data, is waited for first, so what it
    /// seals is deleted too.
    ///
    /// - Returns: `false` when the downloads couldn't be read (deleting nothing), a blob couldn't
    ///   be deleted (a flagged part stays flagged), or a flag couldn't be cleared.
    @discardableResult
    public func discardResumeData(connectionID: UUID) async -> Bool {
        let records: [DownloadRecordDTO]
        do {
            records = try await readRecords(store).filter { $0.key.serverConnectionID == connectionID }
        } catch {
            logError("Couldn't read downloads; not deleting a server's resume data", error)
            return false
        }
        // Only a stop with a live transfer seals, and the connection's transfers are stopped or
        // refused by now, so no stop that begins after this one can seal.
        let pendingStops = records.flatMap(\.parts).compactMap { stopping[$0.id] }
        for stop in pendingStops { await stop.value }
        var deleted = true
        // Every part, flagged or not: a pause whose seal failed, and whose previous blob couldn't
        // be deleted, leaves one unflagged, and a completion whose delete failed one completed.
        for part in records.flatMap(\.parts) {
            guard vault.delete(partID: part.id) else {
                Log.downloads.error("Couldn't delete resume data; a flagged part stays flagged")
                deleted = false
                continue
            }
            guard part.hasResumeData || contexts[part.id]?.hasResumeData == true else { continue }
            contexts[part.id]?.hasResumeData = false
            do {
                try await beforeClearingResumeFlag?(part.id)
                _ = try await store.updatePart(partID: part.id, hasResumeData: false)
            } catch {
                logError("Couldn't clear a deleted resume data's flag", error)
                deleted = false
            }
        }
        return deleted
    }

    /// Stops every transfer of `connectionID`'s downloads, whatever their record's state, then
    /// deletes their resume data, for a sign-out or removal (ADR 0003). It first attaches to the
    /// transfers that survived a relaunch, so they are stopped too, and waits for the parts being
    /// failed for good, whose sibling stops and replays could otherwise run after the discard.
    ///
    /// - Parameter pausing: sets the connection's records' state (for example `paused`), so
    ///   nothing starts them again. It runs first; from then until its resume data is deleted, a
    ///   failure's replay doesn't queue a record of the connection again (one left `failed`
    ///   stays so).
    /// - Returns: `false` when there is no session (the downloads couldn't be read, or another
    ///   process holds it), the downloads couldn't be read at any step, or resume data couldn't
    ///   be deleted. The transfers the engine knows of are still stopped, the resume data is
    ///   still deleted where it can be, and the transfers that survived a relaunch are cancelled
    ///   once the session is created; a later call tries the rest again.
    public func quiesce(connectionID: UUID, pausing: @Sendable () async -> Void = {}) async -> Bool {
        quiescingConnections.append(connectionID)
        // Its surviving transfers are rejected before anything is awaited, so no activation
        // adopts one meanwhile, even one that begins while the records are being paused or
        // after this call's attachment failed.
        survivorsToStop.insert(connectionID)
        // Its complete records are held from here until its resume data is deleted, here or by
        // a later activation, so nothing finalises one meanwhile.
        undiscardedSignOuts.insert(connectionID)
        do {
            try locations.markSurvivorsToStop(connectionID: connectionID)
        } catch {
            logError("Couldn't save a server's sign-out for the next launch", error)
        }
        // The pauses can wait on each other (the manager holds a podcast's item for each of its
        // episodes), so every transfer stops with the old credentials first, without a wait.
        let cancelled = cancelTransfers(of: connectionID)
        var isUnderWay = true
        // Ends this call's registration once, before its finalisation awaits, so a quiesce that
        // begins meanwhile sees itself as the last under way and clears the marker and hold.
        func end() {
            guard isUnderWay else { return }
            isUnderWay = false
            if let index = quiescingConnections.firstIndex(of: connectionID) {
                quiescingConnections.remove(at: index)
            }
            // Counted as it ends, so a generation taken while it was under way precedes it.
            quiesceCount += 1
            lastQuiesces[connectionID] = quiesceCount
        }
        defer { end() }
        await pausing()
        guard await ensureSession() else {
            await discardResumeData(connectionID: connectionID)
            return false
        }
        // Without the records, the transfers the engine knows of are still stopped.
        let records: [DownloadRecordDTO]?
        do {
            records = try await loadRecords()
        } catch {
            logError("Couldn't read downloads; stopping only a server's known transfers", error)
            records = nil
        }
        await waitForFailuresForGood(of: connectionID)
        // Only parts with something under way, so an idle part keeps its state.
        let parts = Set((records ?? []).filter { $0.key.serverConnectionID == connectionID }.flatMap(\.parts).map(\.id))
            .union(contexts.filter { $0.value.connectionID == connectionID }.keys)
            .filter {
                tasks[$0] != nil || launching[$0] != nil || stopping[$0] != nil || retries[$0] != nil
                    || deferredLaunches.contains($0) || cancelled.contains($0)
            }
        await stop(partIDs: Array(parts), keepingResumeData: false)
        await waitForFailuresForGood(of: connectionID)
        let discarded = await discardResumeData(connectionID: connectionID)
        // The session's listing cancelled the survivors, or adopted them before this call, which
        // cancelled them above; the marker stays until the resume data is gone too. Only the
        // last quiesce under way clears it, releases the hold and finalises the records it held:
        // another may still seal more, or fail to delete it.
        end()
        if discarded, !quiescingConnections.contains(connectionID) {
            clearSurvivorsToStop(connectionID)
            undiscardedSignOuts.remove(connectionID)
            await finaliseCompletedRecords()
        }
        return records != nil && discarded
    }

    /// Removes `connectionID`'s marker. A failure is logged; the next activation reads the
    /// markers again and retries it.
    private func clearSurvivorsToStop(_ connectionID: UUID) {
        do {
            try locations.clearSurvivorsToStop(connectionID: connectionID)
        } catch {
            logError("Couldn't clear a server's sign-out marker; the next session retries", error)
        }
    }

    /// Cancels `connectionID`'s transfers, launches and retries at once, dropping their resume
    /// data, as the start of ``stop(partIDs:keepingResumeData:)`` does. Their parts' states are
    /// left to the stops that follow, which find no transfer to wait for.
    ///
    /// - Returns: the parts it cancelled something of.
    private func cancelTransfers(of connectionID: UUID) -> Set<UUID> {
        var cancelled: Set<UUID> = []
        for (partID, context) in contexts where context.connectionID == connectionID && !settling.contains(partID) {
            let retry = retries.removeValue(forKey: partID)
            retry?.cancel()
            let launch = launching.removeValue(forKey: partID)
            preflights.removeValue(forKey: partID)?.cancel()
            let task = tasks.removeValue(forKey: partID)
            if let task {
                ignoredTasks.insert(task.taskIdentifier)
                task.cancel()
            }
            if retry != nil || launch != nil || task != nil { cancelled.insert(partID) }
        }
        return cancelled
    }

    private func waitForFailuresForGood(of connectionID: UUID) async {
        while failingConnections.contains(connectionID) {
            await withCheckedContinuation { failureWaiters.append($0) }
        }
    }

    /// Call from `.backgroundTask(.urlSession(DownloadEngine.sessionIdentifier))` (through
    /// the static ``handleBackgroundEvents()``): creates the session if needed, then returns
    /// once it has delivered, and the engine has handled, the events of this wake. It doesn't
    /// restart queued parts. When the downloads can't be read, it returns at once and marks
    /// the wake abandoned, so its events-finished call, delivered once a later session exists,
    /// doesn't release a later wake early.
    public func handleBackgroundEvents() async {
        // A wake comes while the app is in the background; until it's opened, retries are
        // created as transfers that begin later.
        if !restartsQueuedParts { isInBackground = true }
        guard await ensureSession() else {
            // A session another process holds is that process's: its events don't come here.
            if !isSessionInUse { registry.abandonWake() }
            return
        }
        if unclaimedBackgroundFinishes > 0 {
            unclaimedBackgroundFinishes -= 1
            return
        }
        await withCheckedContinuation { backgroundWaiters.append($0) }
    }

    /// Gives up a background wake without creating the session, as ``handleBackgroundEvents()``
    /// does when it can't read the downloads: the wake's events wait for a later session, and
    /// their events-finished call doesn't release a later wake early.
    public func abandonBackgroundEvents() {
        registry.abandonWake()
    }

    /// ``handleBackgroundEvents()`` on the process's engine, waiting up to 10 seconds for the
    /// app to create it. Without one it returns, and the events wait for the next session.
    public static func handleBackgroundEvents() async {
        await handleBackgroundEvents(registry: .shared, timeout: .seconds(10), clock: ContinuousClock())
    }

    static func handleBackgroundEvents(
        registry: DownloadEngineRegistry, timeout: Duration, clock: any Clock<Duration>
    ) async {
        guard let engine = await registry.engine(timeout: timeout, clock: clock) else {
            registry.abandonWake()
            Log.downloads.error("No download engine was created to handle background events")
            return
        }
        await engine.handleBackgroundEvents()
    }

    // MARK: - Session

    /// Creates the session once the downloads are read, reattaching to surviving transfers.
    /// Returns `false` without a session when the read fails (the next call tries again) or
    /// another process holds the session.
    @discardableResult
    func ensureSession() async -> Bool {
        guard !isSessionInUse else { return false }
        let activation = activation ?? Task { await performActivation() }
        self.activation = activation
        return await activation.value
    }

    private func performActivation() async -> Bool {
        let records: [DownloadRecordDTO]
        // The connections a quiesce, maybe of a previous launch, couldn't finish cleaning up.
        let marked: Set<UUID>
        do {
            records = try await loadRecords()
            marked = try locations.connectionsWithSurvivorsToStop()
        } catch {
            logError("Couldn't read downloads or sign-out markers; not creating the session", error)
            activation = nil
            return false
        }
        // No transfer runs without the session, so only a part still stopping can seal meanwhile.
        sweepResumeData(records: records)
        survivorsToStop.formUnion(marked)
        // Their resume data goes before their complete records are finalised, which drops the
        // parts that lead to it; a quiesce under way deletes it itself, once its pauses end.
        let generation = quiesceCount
        var discarded: Set<UUID> = []
        for connectionID in marked where !quiescingConnections.contains(connectionID) {
            if await discardResumeData(connectionID: connectionID) { discarded.insert(connectionID) }
        }
        // A hold an earlier activation or quiesce left goes once its data is deleted, unless a
        // quiesce began meanwhile: that one may seal more, and releases the hold once it has
        // deleted it.
        undiscardedSignOuts.subtract(discarded.filter { !hasQuiesced(connectionID: $0, since: generation) })
        undiscardedSignOuts.formUnion(marked.subtracting(discarded).subtracting(quiescingConnections))
        await finaliseCompletedRecords()
        let session = makeSession(delegate)
        self.session = session
        isInvalidatingSession = false
        ignoredTasks.removeAll()
        startEventLoop()
        // A task that finished on the way is left to its completion, which adopts it first.
        for task in await session.allTasks where task.state != .completed {
            if let partID = task.partID, tasks[partID] === task { continue }
            if isSurvivorToStop(task) {
                // Its part stays running, so it is queued below.
                ignoredTasks.insert(task.taskIdentifier)
                task.cancel()
                continue
            }
            guard let partID = task.partID, contexts[partID] != nil, tasks[partID] == nil,
                let download = task as? URLSessionDownloadTask
            else {
                ignoredTasks.insert(task.taskIdentifier)
                task.cancel()
                continue
            }
            await reattach(download, partID: partID, activationOwnsSession: true)
        }
        // The files their rejected survivors may have moved stop counting before the marker goes,
        // so a relaunch before the parts are queued again below doesn't complete them from one.
        // A connection whose transfer marker can't be removed keeps its marker.
        var unended: Set<UUID> = []
        for part in records.flatMap(\.parts)
        where part.state == .running && tasks[part.id] == nil && launching[part.id] == nil
            && !settling.contains(part.id) && !markedTransfers.contains(part.id)
        {
            guard let connectionID = contexts[part.id]?.connectionID, survivorsToStop.contains(connectionID) else {
                continue
            }
            if !locations.clearTransferMarker(partID: part.id) { unended.insert(connectionID) }
        }
        // Their survivors are cancelled and their resume data deleted, unless a quiesce began
        // meanwhile, which may seal more and clears the marker itself.
        for connectionID in discarded.subtracting(unended)
        where !hasQuiesced(connectionID: connectionID, since: generation) {
            clearSurvivorsToStop(connectionID)
        }
        // A part left running without a transfer: either its transfer moved the file, but iOS
        // ended the process before the completion was saved, or the app ended before the system
        // kept the transfer. The first completes, but only while the store still has the part
        // running in a download that isn't stopped: a file moved by a survivor whose adoption
        // was refused isn't used, nor one a survivor to stop moved (its pause failed, so its
        // download isn't stopped): only this engine's transfers of such a server count. The
        // second is queued again, so a restart can begin it, but only while the store still has
        // it running: a part that failed for good while the tasks were listed keeps its state.
        for part in records.flatMap(\.parts)
        where part.state == .running && tasks[part.id] == nil && launching[part.id] == nil
            && !settling.contains(part.id)
        {
            if let context = contexts[part.id],
                !survivorsToStop.contains(context.connectionID) || markedTransfers.contains(part.id),
                let bytes = movedFileSize(part.id, context),
                await isStillRunning(part.id)
            {
                Log.downloads.info("A download's file is already in place; completing it without a request")
                await complete(part.id, bytes: bytes)
            } else {
                await persistIdle(part.id) { _ = try await $0.queuePart(partID: part.id, expecting: [.running]) }
            }
        }
        return true
    }

    /// Whether the store still has `partID` running in a download that isn't stopped or failed
    /// for good, checked in one write by ``DownloadStore/beginRunning(partID:expecting:now:)``
    /// (which leaves a running part running). `false` when the store can't be read.
    private func isStillRunning(_ partID: UUID) async -> Bool {
        do {
            return try await beginRunning(partID, expecting: [.running])
        } catch {
            logError("Couldn't check a download's state", error)
            return false
        }
    }

    /// ``DownloadStore/beginRunning(partID:expecting:now:)``, sending
    /// ``DownloadUpdate/recordStarted(recordID:)`` when it moved the part's record from `queued`
    /// to `downloading`.
    private func beginRunning(_ partID: UUID, expecting: Set<DownloadPartState>) async throws -> Bool {
        let start = try await store.startPart(partID: partID, expecting: expecting, now: now())
        if case .startedRecord(let recordID) = start {
            updateContinuation.yield(.recordStarted(recordID: recordID))
        }
        return start != .refused
    }

    private func startEventLoop() {
        guard !isEventLoopRunning else { return }
        isEventLoopRunning = true
        let events = delegate.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// Adopts a transfer that survived a relaunch once
    /// ``DownloadStore/beginRunning(partID:expecting:now:)`` allows it. If the record was
    /// stopped or failed for good, or the store can't be written, the transfer is cancelled
    /// keeping its resume data and its part queued, as ``stop(partIDs:keepingResumeData:)``
    /// does; if the part completed or was deleted, it is cancelled. A result it finished with
    /// meanwhile is handled only once the transfer is adopted: otherwise only its resume data
    /// is kept, and a file it moved stays where it is until the part's next transfer replaces
    /// it. Activation doesn't complete the part from that file (see ``isStillRunning(_:)``), and
    /// the next transfer starts a new generation, so the file isn't reused (see
    /// ``movedFileSize(_:_:)``).
    private func reattach(_ task: URLSessionDownloadTask, partID: UUID, activationOwnsSession: Bool = false) async {
        adopting.insert(task.taskIdentifier)
        if let adoptionStarted { await adoptionStarted(partID) }
        await decideAdoption(of: task, partID: partID)
        adopting.remove(task.taskIdentifier)
        if let result = heldResults.removeValue(forKey: task.taskIdentifier) {
            await handleCompletion(task, result, activationOwnsSession: activationOwnsSession)
        }
    }

    /// Keeps a surviving transfer's result until its adoption is decided. Its resume data is
    /// sealed now, so a stopped part continues from it.
    private func hold(_ result: DownloadTaskResult, of task: URLSessionTask, partID: UUID) {
        if case .failed(let failure) = result, let data = failure.resumeData {
            contexts[partID]?.hasResumeData = seal(data, partID: partID, task: task)
        }
        heldResults[task.taskIdentifier] = result
    }

    private func decideAdoption(of task: URLSessionDownloadTask, partID: UUID) async {
        // Adopted before the write, so its events are handled while the write is under way.
        tasks[partID] = task
        var adopts = false
        do {
            adopts = try await beginRunning(partID, expecting: [.queued, .running, .failed])
        } catch {
            logError("Couldn't record a surviving download; stopping it", error)
        }
        guard tasks[partID] === task else { return }
        guard adopts else {
            // A deleted or completed part's transfer is cancelled; when the read fails, it stops.
            var isGone = false
            do {
                isGone = try await store.part(id: partID).map { $0.state == .completed } ?? true
            } catch {
                logError("Couldn't read a surviving download", error)
            }
            guard tasks[partID] === task else { return }
            if isGone {
                tasks[partID] = nil
                ignoredTasks.insert(task.taskIdentifier)
                task.cancel()
                vault.delete(partID: partID)
                locations.clearTransferMarker(partID: partID)
                forget(partID)
            } else {
                await stop(partIDs: [partID], keepingResumeData: true)
            }
            return
        }
        await persist { try await $0.setPartState(.running, partID: partID, taskIdentifier: task.taskIdentifier) }
        if task.state == .suspended, tasks[partID] === task { task.resume() }
    }

    /// Whether `task` survived a relaunch and its server was quiesced: it carries the
    /// credentials of before the sign-out (ADR 0003).
    private func isSurvivorToStop(_ task: URLSessionTask) -> Bool {
        guard let partID = task.partID, let context = contexts[partID] else { return false }
        return survivorsToStop.contains(context.connectionID) && !createdTasks.contains(task.taskIdentifier)
    }

    /// Lets the session's tasks finish, then creates it again (on ``sessionInvalidated()``).
    private func dropSession() {
        guard let session, !isInvalidatingSession else { return }
        isInvalidatingSession = true
        session.finishTasksAndInvalidate()
    }

    private func sessionInvalidated() async {
        session = nil
        activation = nil
        isInvalidatingSession = false
        tasks.removeAll()
        ignoredTasks.removeAll()
        if !isSessionInUse { await recreateSession() }
        while backgroundFinishesAwaitingRecreation > 0 {
            backgroundFinishesAwaitingRecreation -= 1
            releaseBackgroundWake()
        }
    }

    /// Creates the session again after a ``RetryPolicy`` delay, then launches the parts that
    /// waited for it. After ``maxSessionRecreations`` attempts without a moved file, the
    /// engine reports the session lost and waits for the next ``activate()``.
    private func recreateSession() async {
        sessionRecreations += 1
        guard sessionRecreations <= Self.maxSessionRecreations else {
            Log.downloads.error("The download session keeps disconnecting; waiting for the app to be opened")
            updateContinuation.yield(
                .sessionUnavailable(code: .sessionLost, message: "The download session keeps disconnecting."))
            return
        }
        let delay = retryPolicy.delay(beforeRetry: sessionRecreations, random: random()) ?? .zero
        if delay > .zero, !isInBackground { try? await clock.sleep(for: delay) }
        guard await ensureSession() else { return }
        let deferred = deferredLaunches
        deferredLaunches.removeAll()
        let notBefore: Date?
        if isInBackground, delay > .zero {
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            notBefore = now().addingTimeInterval(seconds)
        } else {
            notBefore = nil
        }
        for partID in deferred {
            await launch(partID, notBefore: notBefore)
        }
    }

    /// Another process holds the session identifier (`backgroundSessionInUseByAnotherProcess`):
    /// no session of this process can work, so the engine stops creating one until the next
    /// ``activate()``.
    private func sessionHeldByAnotherProcess() {
        guard !isSessionInUse else { return }
        isSessionInUse = true
        Log.downloads.fault("Another process holds the download session; downloads stop until the app is opened again")
        updateContinuation.yield(
            .sessionUnavailable(code: .sessionInUse, message: "Another process is using the download session."))
        dropSession()
    }

    /// Deletes resume data no record references: a record went though its blob's delete failed
    /// (#515). Run with no suspension since `records` was read; parts still stopping, or sealed
    /// while a retry read the records, are kept.
    private func sweepResumeData(records: [DownloadRecordDTO]) {
        guard sweepsOrphanedResumeData else { return }
        let kept = Set(records.flatMap(\.parts).map(\.id)).union(stopping.keys).union(sealedDuringSweep ?? [])
        isResumeDataSweepPending = !vault.deleteBlobs(except: kept)
    }

    /// Runs a failed sweep again once the session exists. Transfers run meanwhile, so the parts
    /// they seal during the read are kept; a sweep under way is not doubled.
    private func retryResumeDataSweep() async {
        guard isResumeDataSweepPending, sealedDuringSweep == nil else { return }
        sealedDuringSweep = []
        defer { sealedDuringSweep = nil }
        do {
            sweepResumeData(records: try await readRecords(store))
        } catch {
            logError("Couldn't read downloads to sweep resume data; the next activation tries again", error)
        }
    }

    /// Adds a context for each part not yet known that hasn't completed, with the failures the
    /// store counted for it.
    @discardableResult
    private func loadRecords() async throws -> [DownloadRecordDTO] {
        let records = try await readRecords(store)
        for record in records {
            for part in record.parts where part.state != .completed && contexts[part.id] == nil {
                let destination = try? locations.fileURL(forRelativePath: part.destinationRelativePath)
                contexts[part.id] = PartContext(
                    recordID: record.id, connectionID: record.key.serverConnectionID, serverPath: part.serverPath,
                    destination: destination, expectedBytes: part.expectedBytes, hasResumeData: part.hasResumeData,
                    maxBytes: part.kind == .cover ? Self.maxCoverBytes : nil)
                failures[part.id] = part.retryCount > 0 ? part.retryCount : nil
                delegate.setTarget(
                    destination.map {
                        .init(destination: $0, expectedBytes: part.expectedBytes, maxBytes: contexts[part.id]?.maxBytes)
                    }, for: part.id)
            }
        }
        return records
    }

    /// Launches the queued and failed parts of `queued` and `downloading` records. The read
    /// may be stale; ``DownloadStore/beginRunning(partID:expecting:now:)`` refuses the parts
    /// that changed since. A ``deactivate()`` meanwhile stops it: background starts aren't reliable.
    private func restartQueuedParts() async {
        let records: [DownloadRecordDTO]
        do {
            records = try await loadRecords()
        } catch {
            logError("Couldn't read downloads", error)
            return
        }
        let candidates = records.filter { $0.state == .queued || $0.state == .downloading }
            .flatMap(\.parts).filter { $0.state == .queued || $0.state == .failed || strandedRunning.contains($0.id) }
            .map(\.id)
        for partID in candidates where restartsQueuedParts {
            await launch(partID, onlyWhileActive: true)
        }
    }

    // MARK: - Tasks

    /// Starts `partID` once ``DownloadStore/beginRunning(partID:expecting:now:)`` allows it, then
    /// creates and resumes its task: from its resume data while it matches the fresh request's
    /// credentials and network access, otherwise from the fresh request. Each launch starts a
    /// new transfer generation (see ``movedFileSize(_:_:)``), so a file already at the
    /// destination is replaced, never reused.
    ///
    /// - Parameters:
    ///   - rejectedAccessToken: after a 401, the token that was rejected.
    ///   - notBefore: the task's `earliestBeginDate`, for a retry created in the background.
    ///   - onlyWhileActive: starts no transfer after a ``deactivate()`` that came while the launch
    ///     was suspended (reading credentials, say): the part is left queued for the next
    ///     ``activate()``.
    private func launch(
        _ partID: UUID, rejectedAccessToken: String? = nil, notBefore: Date? = nil,
        activationOwnsSession: Bool = false, onlyWhileActive: Bool = false
    ) async {
        if let stop = stopping[partID] { await stop.value }
        guard let context = contexts[partID], tasks[partID] == nil, retries[partID] == nil, launching[partID] == nil,
            !settling.contains(partID), !pendingRecordFailures.contains(context.recordID)
        else { return }
        guard session != nil, !isInvalidatingSession else {
            deferredLaunches.insert(partID)
            return
        }
        guard let destination = context.destination else {
            await failPermanently(
                partID, code: .invalidDestination, message: "The download's destination is invalid.",
                activationOwnsSession: activationOwnsSession)
            return
        }
        let token = UUID()
        launching[partID] = token
        defer { if launching[partID] == token { launching[partID] = nil } }
        // A part whose idle state couldn't be written is still running in the store.
        let startable: Set<DownloadPartState> =
            strandedRunning.contains(partID) ? [.queued, .failed, .running] : [.queued, .failed]
        // The last generation's marker goes first, so no file moved before this launch can
        // complete the part, even if the process ends before the new marker is written.
        locations.clearTransferMarker(partID: partID)
        do {
            guard try await beginRunning(partID, expecting: startable) else {
                // Completed, stopped, failed for good or deleted since it was read.
                if launching[partID] == token { forget(partID) }
                return
            }
            strandedRunning.remove(partID)
        } catch {
            logError("Couldn't start a download", error)
            if launching[partID] == token {
                await retry(
                    partID, code: .store, message: "Couldn't save the download's state.", transferFailed: false,
                    activationOwnsSession: activationOwnsSession)
            }
            return
        }
        do {
            try locations.markTransferStart(partID: partID)
            markedTransfers.insert(partID)
        } catch {
            logError("Couldn't mark a download's start; a file it moves is only kept once recorded", error)
        }
        let request: URLRequest
        var unchecked: URLRequest?
        do {
            let credentials = try await credentials.credentials(
                for: context.connectionID, replacing: rejectedAccessToken)
            // Before any request is made, so the headers never reach the preflight or a transfer.
            guard credentials.configuration.customHeaders.isEmpty else { throw CustomHeadersRefused() }
            var fresh = try DownloadRequests.request(
                path: context.serverPath, configuration: credentials.configuration,
                accessToken: credentials.accessToken)
            fresh.apply(await networkAccess())
            unchecked = fresh
            // Stopped while the credentials were read: no check is sent with them.
            guard launching[partID] == token else { return }
            let check = Task { [preflight] in try await preflight.check(fresh) }
            preflights[partID] = check
            defer { if preflights[partID] == check { preflights[partID] = nil } }
            // A cancelled launch (a retry task's) still cancels its check, as when it ran inline.
            request = try await withTaskCancellationHandler {
                try await check.value
            } onCancel: {
                check.cancel()
            }
        } catch DownloadRedirectPreflightError.noNetwork(let code) {
            if launching[partID] == token, let unchecked {
                await waitForNetwork(partID, launch: token, request: unchecked, code: code)
            }
            return
        } catch DownloadRedirectPreflightError.offOrigin {
            if launching[partID] == token {
                await failPermanently(
                    partID, code: .offOrigin, message: "The download is redirected to another server.",
                    activationOwnsSession: activationOwnsSession)
            }
            return
        } catch is CustomHeadersRefused {
            if launching[partID] == token {
                await failPermanently(
                    partID, code: .customHeadersUnsupported,
                    message: "Downloads aren't available yet for servers that need custom headers.",
                    activationOwnsSession: activationOwnsSession)
            }
            return
        } catch DownloadRedirectPreflightError.unreachable(let code) {
            if launching[partID] == token {
                await retry(
                    partID, code: .transfer,
                    message: "Couldn't reach the server: \(URLError(code).localizedDescription)",
                    transferFailed: false, activationOwnsSession: activationOwnsSession)
            }
            return
        } catch {
            if launching[partID] == token {
                await retry(
                    partID, code: .credentials,
                    message: "Couldn't authorize the download: \(error.localizedDescription)", transferFailed: false,
                    activationOwnsSession: activationOwnsSession)
            }
            return
        }
        guard launching[partID] == token, tasks[partID] == nil, contexts[partID] != nil, !settling.contains(partID)
        else { return }
        guard let session, !isInvalidatingSession else {
            // The session went away meanwhile: start again once it is back.
            deferredLaunches.insert(partID)
            await persistIdle(partID) { try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil) }
            return
        }
        // Deactivated while the credentials or the preflight were awaited.
        if onlyWhileActive, !restartsQueuedParts {
            await persistIdle(partID) { try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil) }
            return
        }
        var resumeData: Data?
        // Resume data that can't be read now (the Keychain or the file is unavailable while the
        // device is locked) is kept for a later launch; this one starts from the beginning.
        var keepsResumeData = false
        if contexts[partID]?.hasResumeData == true, rejectedAccessToken == nil {
            do {
                resumeData = try vault.open(partID: partID, credentialTag: ResumeDataVault.credentialTag(for: request))
            } catch {
                logError("Couldn't read resume data; starting the part from the beginning", error)
                keepsResumeData = true
            }
        }
        let task = resumeData.map(session.downloadTask(withResumeData:)) ?? session.downloadTask(with: request)
        createdTasks.insert(task.taskIdentifier)
        task.taskDescription = partID.uuidString
        if let notBefore { task.earliestBeginDate = notBefore }
        tasks[partID] = task
        delegate.setTarget(
            .init(destination: destination, expectedBytes: context.expectedBytes, maxBytes: context.maxBytes),
            for: partID)
        throttle.reset(partID)
        let recorded: Bool
        do {
            recorded = try await store.setPartState(
                .running, partID: partID, taskIdentifier: task.taskIdentifier, hasResumeData: keepsResumeData,
                now: now())
        } catch {
            logError("Couldn't update a download", error)
            recorded = true
        }
        guard recorded, tasks[partID] === task else {
            // The part was deleted or stopped meanwhile; the task never ran.
            if tasks[partID] === task { tasks[partID] = nil }
            ignoredTasks.insert(task.taskIdentifier)
            task.cancel()
            if !recorded { forget(partID) }
            return
        }
        // The resume data now lives in the task.
        if resumeData != nil { vault.delete(partID: partID) }
        contexts[partID]?.hasResumeData = keepsResumeData
        if resumeData == nil {
            await persist {
                try await $0.updateProgress(partID: partID, bytesWritten: 0, expectedBytes: context.expectedBytes)
            }
        }
        guard tasks[partID] === task else { return }
        // Deactivated while the part's state was saved: the task never ran, and the resume data
        // it took is sealed again for the next activation's launch.
        if onlyWhileActive, !restartsQueuedParts {
            tasks[partID] = nil
            ignoredTasks.insert(task.taskIdentifier)
            task.cancel()
            var hasResumeData = keepsResumeData
            if let resumeData {
                do {
                    try vault.seal(
                        resumeData, partID: partID, credentialTag: ResumeDataVault.credentialTag(for: request))
                    hasResumeData = true
                } catch {
                    logError("Couldn't keep a download's resume data; it starts from the beginning", error)
                }
            }
            contexts[partID]?.hasResumeData = hasResumeData
            await persistIdle(partID) {
                try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
            }
            return
        }
        task.resume()
    }

    // MARK: - Events

    private func handle(_ event: DownloadSessionEvent) async {
        switch event {
        case .progress(let task, let written, let expected):
            await handleProgress(task, bytesWritten: written, expectedBytes: expected)
        case .completed(let task, let result):
            await handleCompletion(task, result)
        case .backgroundEventsFinished:
            // iOS may end the process once the wake is released, losing writes kept only in
            // memory: those that failed are tried again first, a few times.
            for attempt in 0..<Self.maxWakeSaveAttempts where hasPendingWrites {
                if attempt > 0 { try? await clock.sleep(for: .seconds(1)) }
                await savePendingWrites()
            }
            if isInvalidatingSession {
                backgroundFinishesAwaitingRecreation += 1
                return
            }
            releaseBackgroundWake()
        case .sessionInvalidated:
            await sessionInvalidated()
        case .restartQueued:
            // Handled here, between completions: saves that failed and records left complete
            // but not finalised are done before parts restart.
            await reconcile()
            restart = Task { [weak self] in await self?.restartQueuedParts() }
        case .barrier(let continuation):
            continuation.resume()
        }
    }

    /// Releases the matching wake once its writes and any session recreation are complete.
    private func releaseBackgroundWake() {
        // An abandoned wake's call is matched first: it can arrive once a later wake waits,
        // and must not release that one before its own events are handled.
        if !registry.consumeAbandonedWake() {
            if !backgroundWaiters.isEmpty {
                backgroundWaiters.removeFirst().resume()
            } else {
                unclaimedBackgroundFinishes += 1
            }
        }
    }

    /// Returns once the events delivered so far are handled. For tests.
    func processPendingEvents() async {
        guard isEventLoopRunning else { return }
        await withCheckedContinuation { delegate.post(.barrier($0)) }
    }

    /// Returns once the restart of queued parts that the last ``activate()`` began has launched
    /// them. For tests.
    func waitForRestart() async {
        await processPendingEvents()
        await restart?.value
    }

    private static let tooLargePrefix = "The file is larger than "

    static func tooLargeMessage(_ limit: Int64) -> String {
        "\(tooLargePrefix)\(limit) bytes."
    }

    /// Whether a part's saved `lastError` is that of a ``DownloadFailureCode/tooLarge`` failure:
    /// the store keeps only the message, not the code.
    static func failedAsTooLarge(_ lastError: String?) -> Bool {
        lastError?.hasPrefix(tooLargePrefix) == true
    }

    private func handleProgress(_ task: URLSessionTask, bytesWritten: Int64, expectedBytes: Int64) async {
        // An error body (a 401 page, say) also reports progress.
        guard let partID = task.partID, let context = contexts[partID],
            tasks[partID]?.taskIdentifier == task.taskIdentifier
        else { return }
        // Before the check below: an error body over the limit (a large 404 page, say) is
        // stopped too, rather than written in full to temporary storage.
        if let limit = context.maxBytes, bytesWritten > limit || expectedBytes > limit {
            ignoredTasks.insert(task.taskIdentifier)
            task.cancel()
            await failPermanently(partID, code: .tooLarge, message: Self.tooLargeMessage(limit))
            return
        }
        guard DownloadSessionDelegate.classify(response: task.response, task: task) == nil else { return }
        authRetried.remove(partID)
        let expected = expectedBytes > 0 ? expectedBytes : context.expectedBytes
        let decision = throttle.record(
            partID, bytesWritten: bytesWritten, expectedBytes: expected, at: ContinuousClock.now)
        if decision.publishes {
            progressContinuation.yield(
                DownloadProgress(
                    partID: partID, recordID: context.recordID, bytesWritten: bytesWritten, expectedBytes: expected))
        }
        if decision.persists {
            let date = now()
            await persist {
                try await $0.updateProgress(
                    partID: partID, bytesWritten: bytesWritten, expectedBytes: expected, now: date)
            }
        }
    }

    private func handleCompletion(
        _ task: URLSessionTask, _ result: DownloadTaskResult, activationOwnsSession: Bool = false
    ) async {
        if ignoredTasks.remove(task.taskIdentifier) != nil { return }
        guard let partID = task.partID, contexts[partID] != nil else { return }
        let current = tasks[partID]
        // Finished before or while the session was created: neither its result nor its resume
        // data is kept. A part it left running is queued again.
        if isSurvivorToStop(task) {
            if current == nil, launching[partID] == nil, !settling.contains(partID) {
                await persistIdle(partID) { _ = try await $0.queuePart(partID: partID, expecting: [.running]) }
            }
            return
        }
        // A surviving transfer's result waits for its adoption, so it can't complete or fail a
        // stopped record's part. One that finished before it was adopted is adopted first.
        if adopting.contains(task.taskIdentifier) {
            hold(result, of: task, partID: partID)
            return
        }
        if current == nil, !settling.contains(partID), let download = task as? URLSessionDownloadTask {
            hold(result, of: task, partID: partID)
            await reattach(download, partID: partID, activationOwnsSession: activationOwnsSession)
            return
        }
        if case .moved(let bytes) = result {
            // A finished file wins even from a stale task; drop any newer transfer.
            if let current, current.taskIdentifier != task.taskIdentifier {
                ignoredTasks.insert(current.taskIdentifier)
                current.cancel()
            }
            sessionRecreations = 0
            await complete(partID, bytes: bytes)
            return
        }
        // A stale task's failure doesn't affect the transfer that replaced it.
        guard current == nil || current?.taskIdentifier == task.taskIdentifier else { return }
        tasks[partID] = nil
        throttle.reset(partID)
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 {
            // The server accepted the token, so a later 401 is a new one.
            authRetried.remove(partID)
        }
        switch result {
        case .moved:
            return
        case .httpStatus(401):
            await handleUnauthorized(partID, task: task, activationOwnsSession: activationOwnsSession)
        case .httpStatus(let status) where status == 0 || status == 408 || status == 429 || status >= 500:
            await retry(
                partID, code: .transfer, message: "The server returned HTTP \(status).",
                activationOwnsSession: activationOwnsSession)
        case .httpStatus(let status):
            await failPermanently(
                partID, code: .httpStatus, message: "The server returned HTTP \(status).",
                activationOwnsSession: activationOwnsSession)
        case .redirectedUnauthorized:
            await failPermanently(
                partID, code: .redirectedUnauthorized,
                message: "The download was redirected, and its sign-in isn't sent to the new address.",
                activationOwnsSession: activationOwnsSession)
        case .offOrigin:
            await failPermanently(
                partID, code: .offOrigin, message: "The download was redirected to another server.",
                activationOwnsSession: activationOwnsSession)
        case .unexpectedContent(let type):
            await retry(
                partID, code: .unexpectedContent, message: "The server sent \(type) instead of the file.",
                activationOwnsSession: activationOwnsSession)
        case .sizeMismatch(let expected, let actual):
            let message =
                expected > 0
                ? "The file has \(actual) bytes instead of \(expected)."
                : "The server didn't send the whole file (\(actual) bytes)."
            await retry(partID, code: .sizeMismatch, message: message, activationOwnsSession: activationOwnsSession)
        case .tooLarge(let limit):
            await failPermanently(
                partID, code: .tooLarge, message: Self.tooLargeMessage(limit),
                activationOwnsSession: activationOwnsSession)
        case .moveFailed(let message, let isOutOfSpace):
            if isOutOfSpace {
                await failPermanently(
                    partID, code: .outOfSpace, message: message, activationOwnsSession: activationOwnsSession)
            } else {
                await retry(
                    partID, code: .fileSystem, message: message, activationOwnsSession: activationOwnsSession)
            }
        case .failed(let failure):
            await handleTransferFailure(
                partID, task: task, failure, activationOwnsSession: activationOwnsSession)
        }
    }

    private func handleTransferFailure(
        _ partID: UUID, task: URLSessionTask, _ failure: DownloadTransferFailure, activationOwnsSession: Bool = false
    ) async {
        if let data = failure.resumeData {
            contexts[partID]?.hasResumeData = seal(data, partID: partID, task: task)
        }
        if failure.isOutOfSpace {
            await failPermanently(
                partID, code: .outOfSpace, message: failure.message, activationOwnsSession: activationOwnsSession)
            return
        }
        if failure.isSessionInUse {
            await requeue(partID)
            sessionHeldByAnotherProcess()
            return
        }
        guard failure.isBackgroundCancellation || failure.isSessionDisconnected else {
            await retry(partID, code: .transfer, message: failure.message, activationOwnsSession: activationOwnsSession)
            return
        }
        // Not the transfer's fault: restart it without counting a failure, a few times.
        if failure.isSessionDisconnected { dropSession() }
        let restarts = freeRestarts[partID, default: 0] + 1
        freeRestarts[partID] = restarts
        guard restarts <= Self.maxFreeRestarts else {
            await retry(partID, code: .transfer, message: failure.message, activationOwnsSession: activationOwnsSession)
            return
        }
        if failure.isSessionDisconnected { deferredLaunches.insert(partID) }
        await requeue(partID)
        // Only a force quit restarts at once: its cancellations arrive when the app is opened
        // again. The others happen in the background and wait for the next activation.
        if failure.isForceQuit, restartsQueuedParts {
            Task { [weak self] in await self?.launch(partID) }
        }
    }

    /// Queues the part again without counting a failure.
    private func requeue(_ partID: UUID) async {
        let hasResumeData = contexts[partID]?.hasResumeData
        await persistIdle(partID) {
            try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
        }
    }

    /// Resume data replays the rejected header, so it is deleted. A 401 for the current token
    /// recreates the task from a fresh request once; a 401 for a token that has since been
    /// replaced doesn't count.
    private func handleUnauthorized(
        _ partID: UUID, task: URLSessionTask, activationOwnsSession: Bool = false
    ) async {
        guard let context = contexts[partID] else { return }
        vault.delete(partID: partID)
        contexts[partID]?.hasResumeData = false
        let message = "The server rejected the download's sign-in (HTTP 401)."
        let header = task.originalRequest?.value(forHTTPHeaderField: "Authorization") ?? ""
        let rejected = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
        let current = await credentials.currentCredentials(for: context.connectionID)?.accessToken
        let isStale = current != nil && current != rejected
        if !isStale, !authRetried.insert(partID).inserted {
            await failPermanently(
                partID, code: .unauthorized, message: message, activationOwnsSession: activationOwnsSession)
            return
        }
        await persistIdle(partID) {
            try await $0.setPartState(
                .queued, partID: partID, taskIdentifier: nil, error: message, hasResumeData: false)
        }
        // In the background the new task is created before a wake is released (see `retry`).
        if isInBackground {
            await launch(partID, rejectedAccessToken: rejected, activationOwnsSession: activationOwnsSession)
        } else {
            Task { [weak self] in await self?.launch(partID, rejectedAccessToken: rejected) }
        }
    }

    /// Records the moved file's size, then finalises the record once every part completed.
    /// A size other than the expected one is the length the server declared (the file changed
    /// since the download was planned), so it becomes the part's expected size.
    private func complete(_ partID: UUID, bytes: Int64) async {
        guard contexts[partID] != nil, settling.insert(partID).inserted else { return }
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        vault.delete(partID: partID)
        failures[partID] = nil
        unsavedCompletions[partID] = bytes
        await saveCompletion(partID)
    }

    /// Saves an unsaved completion. When the store can't be written, the part stays settling,
    /// so no transfer replaces its file, and the save is retried after the ``RetryPolicy``'s
    /// delays, then on each ``activate()``.
    private func saveCompletion(_ partID: UUID) async {
        guard let context = contexts[partID], let bytes = unsavedCompletions[partID] else { return }
        let date = now()
        let completed: Bool
        do {
            if context.expectedBytes > 0, bytes != context.expectedBytes {
                Log.downloads.info("A file's size changed on the server since its download was planned")
                try await store.updateProgress(partID: partID, bytesWritten: bytes, expectedBytes: bytes, now: date)
            }
            completed = try await store.completePart(partID: partID, finalBytes: bytes, now: date)
        } catch {
            logError("Couldn't record a finished download", error)
            // Another save may have succeeded meanwhile.
            guard unsavedCompletions[partID] != nil else { return }
            let failure = failures[partID, default: 0] + 1
            failures[partID] = failure
            guard let delay = retryPolicy.delay(beforeRetry: failure, random: random()) else { return }
            let clock = clock
            retries.removeValue(forKey: partID)?.cancel()
            retries[partID] = Task { [weak self] in
                guard (try? await clock.sleep(for: delay)) != nil else { return }
                await self?.retrySavingCompletion(partID)
            }
            return
        }
        guard unsavedCompletions.removeValue(forKey: partID) != nil else { return }
        locations.clearTransferMarker(partID: partID)
        plainStartsAfterSettling.remove(partID)
        forget(partID)
        settling.remove(partID)
        guard completed else { return }
        updateContinuation.yield(.partCompleted(partID: partID, recordID: context.recordID))
        if let record = try? await store.record(id: context.recordID), record.isComplete {
            await finalise(record)
        }
    }

    private func retrySavingCompletion(_ partID: UUID) async {
        guard !Task.isCancelled, retries.removeValue(forKey: partID) != nil else { return }
        await saveCompletion(partID)
    }

    /// Saves the completions and record failures that failed and finalises the complete
    /// records that weren't.
    private func reconcile() async {
        await savePendingWrites()
        await finaliseCompletedRecords()
    }

    private var hasPendingWrites: Bool { !unsavedCompletions.isEmpty || !pendingRecordFailures.isEmpty }

    private func savePendingWrites() async {
        for partID in unsavedCompletions.keys {
            retries.removeValue(forKey: partID)?.cancel()
            failures[partID] = nil
            await saveCompletion(partID)
        }
        for recordID in pendingRecordFailures where pendingRecordFailures.contains(recordID) {
            await saveRecordFailure(recordID)
        }
    }

    /// Saves a record's `failed` state; when it can't, the record's parts can't launch until a
    /// later ``reconcile()`` saves it. A resume pending for the record owns it and skips the
    /// write, unless `ownsFailure`.
    private func saveRecordFailure(_ recordID: UUID, ownsFailure: Bool = false) async {
        guard ownsFailure || !resumingRecords.contains(recordID) else {
            pendingRecordFailures.remove(recordID)
            return
        }
        do {
            _ = try await store.setState(.failed, forRecord: recordID, expecting: [.queued, .downloading])
            pendingRecordFailures.remove(recordID)
        } catch {
            logError("Couldn't record a failed download", error)
            pendingRecordFailures.insert(recordID)
        }
    }

    /// Makes a complete record a local item, then deletes it. A cover-only record whose local
    /// item is gone is deleted and reported discarded instead. A failure is logged; the next
    /// activation repeats it. A held connection's record (``undiscardedSignOuts``) is left to
    /// the quiesce or activation that releases the hold, also when the hold begins while the
    /// local item is written.
    private func finalise(_ record: DownloadRecordDTO) async {
        guard !undiscardedSignOuts.contains(record.key.serverConnectionID), finalising.insert(record.id).inserted
        else { return }
        defer { finalising.remove(record.id) }
        do {
            let item = try await localItems.upsertFromDownload(record, now: now())
            await afterUpsertingLocalItem?(record.id)
            guard !undiscardedSignOuts.contains(record.key.serverConnectionID) else { return }
            try await store.deleteRecord(record.id)
            updateContinuation.yield(.recordComplete(recordID: record.id, itemID: item.id))
        } catch LocalItemStore.StoreError.itemNotFound {
            guard !undiscardedSignOuts.contains(record.key.serverConnectionID) else { return }
            do {
                if try await store.deleteRecord(record.id) != nil {
                    updateContinuation.yield(.recordDiscarded(record))
                }
            } catch {
                logError("Couldn't discard a cover download", error)
            }
        } catch {
            logError("Couldn't finalise a download", error)
        }
    }

    private func finaliseCompletedRecords() async {
        do {
            for record in try await store.completedRecords() {
                await finalise(record)
            }
        } catch {
            logError("Couldn't read finished downloads", error)
        }
    }

    /// Marks the part failed and schedules a retry, or fails it for good once the retries
    /// are used up. In the foreground the retry waits in the process, so the part shows its
    /// error meanwhile. In the background (``isInBackground``) iOS can suspend the process
    /// before that wait ends, so a failed transfer's replacement is created at once, before a
    /// wake is released, and begins after the delay (`earliestBeginDate`); it is adopted like
    /// any transfer after a relaunch.
    ///
    /// - Parameter transferFailed: `false` when no request could be made (the credentials or
    ///   the store failed); then the retry always waits in the process.
    private func retry(
        _ partID: UUID, code: DownloadFailureCode, message: String, transferFailed: Bool = true,
        activationOwnsSession: Bool = false
    ) async {
        guard let context = contexts[partID] else { return }
        let failure = failures[partID, default: 0] + 1
        failures[partID] = failure
        guard let delay = retryPolicy.delay(beforeRetry: failure, random: random()) else {
            await failPermanently(
                partID, code: code, message: message, retryCount: failure,
                activationOwnsSession: activationOwnsSession)
            return
        }
        await persistIdle(partID) {
            try await $0.setPartState(
                .failed, partID: partID, taskIdentifier: nil, error: message, errorCode: code.rawValue,
                hasResumeData: context.hasResumeData, retryCount: failure)
        }
        updateContinuation.yield(
            .partFailed(partID: partID, recordID: context.recordID, code: code, message: message, willRetry: true))
        if isInBackground, transferFailed {
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            await launch(
                partID, notBefore: now().addingTimeInterval(seconds), activationOwnsSession: activationOwnsSession)
            return
        }
        let clock = clock
        retries[partID] = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryNow(partID)
        }
    }

    /// Queues the part until a network its request may use is available, then launches it
    /// again. Unlike ``retry(_:code:message:transferFailed:activationOwnsSession:)`` this uses
    /// none of the part's retries: being offline, or on a network the download settings forbid,
    /// isn't the server failing. When the wait ends at once because a network was there after
    /// all (a server that drops the connection, say), the failure is retried and counted. A stop
    /// cancels the wait like a retry's.
    private func waitForNetwork(_ partID: UUID, launch token: UUID, request: URLRequest, code: URLError.Code) async {
        await persistIdle(partID) { try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil) }
        // Stopped meanwhile. The wait begins after this launch returns, so it can launch again.
        guard launching[partID] == token else { return }
        let preflight = preflight
        retries[partID] = Task { [weak self] in
            let waited = await preflight.waitForNetwork(request)
            await self?.networkWaitEnded(partID, waited: waited, code: code)
        }
    }

    private func networkWaitEnded(_ partID: UUID, waited: Bool, code: URLError.Code) async {
        guard !Task.isCancelled, retries.removeValue(forKey: partID) != nil else { return }
        if waited {
            await launch(partID)
        } else {
            await retry(
                partID, code: .transfer, message: "Couldn't reach the server: \(URLError(code).localizedDescription)",
                transferFailed: false)
        }
    }

    private func retryNow(_ partID: UUID) async {
        guard !Task.isCancelled, retries.removeValue(forKey: partID) != nil else { return }
        await launch(partID)
    }

    /// Fails the part and its record for good, and stops the record's other parts, keeping
    /// their resume data, so a retry of the record continues them. The record fails first
    /// unless a resume already owns it (an attempt the replay below launched for that resume
    /// fails it regardless: its failure is final); a concurrent launch of another part is
    /// refused until failure is saved.
    ///
    /// A start of the part that overlapped the failure (a plain ``start(partIDs:)``, or
    /// ``resume(recordID:)`` before, during or after any part of it) is replayed once the
    /// failure is settled: the part restarts with a fresh retry budget, and for a resume so do
    /// the siblings the failure stopped. A part is replayed once per resume. A plain start's
    /// replay leaves the record `failed` when another part of it failed for good while this
    /// failure was under way: restarting only this part would strand that one. If activation is
    /// handling the failure while reattaching a task, the replay reuses its session instead of
    /// awaiting the activation task that is already handling it. No replay is made while the
    /// part's server is being quiesced (``quiesce(connectionID:pausing:)``).
    private func failPermanently(
        _ partID: UUID, code: DownloadFailureCode, message: String, retryCount: Int? = nil,
        activationOwnsSession: Bool = false
    ) async {
        guard let context = contexts[partID], settling.insert(partID).inserted else { return }
        // Noted before any await, so a sibling's failure that begins later sees this one.
        let concurrentFailures = failingForGood[context.recordID, default: []].filter { $0 != partID }
        if !concurrentFailures.isEmpty {
            overlappingFailures.formUnion(concurrentFailures)
            overlappingFailures.insert(partID)
        }
        failingForGood[context.recordID, default: []].append(partID)
        // One entry per failure under way (a part twice while its replay's launch fails it
        // again), until its replay has started, for quiesce(connectionID:pausing:).
        failingConnections.append(context.connectionID)
        defer {
            if let index = failingConnections.firstIndex(of: context.connectionID) {
                failingConnections.remove(at: index)
            }
            let waiters = failureWaiters
            failureWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let resumeGenerationAtStart = resumeGenerations[context.recordID, default: 0]
        let resumeWasPendingAtStart = resumingRecords.contains(context.recordID)
        let isReplayedAttempt = replayedResumeGenerationByPart[partID] == resumeGenerationAtStart
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        await saveRecordFailure(context.recordID, ownsFailure: isReplayedAttempt)
        await persistIdle(partID) {
            try await $0.setPartState(
                .failed, partID: partID, taskIdentifier: nil, error: message, errorCode: code.rawValue,
                hasResumeData: context.hasResumeData, retryCount: retryCount)
        }
        if let beforeStoppingSiblings { await beforeStoppingSiblings(partID) }
        let siblings = contexts.filter { $0.value.recordID == context.recordID && $0.key != partID }.map(\.key)
        await stop(partIDs: siblings, keepingResumeData: true)
        forget(partID)
        settling.remove(partID)
        // A failure raised by this part's own launch ends that launch, so the replay can start it.
        launching[partID] = nil
        updateContinuation.yield(
            .partFailed(partID: partID, recordID: context.recordID, code: code, message: message, willRetry: false))
        let wasPlainStart = plainStartsAfterSettling.remove(partID) != nil
        let resumeGeneration = resumeGenerations[context.recordID, default: 0]
        let resumeNeedsReplay =
            resumeGeneration > 0
            && replayedResumeGenerationByPart[partID] != resumeGeneration
            && (resumeGeneration > resumeGenerationAtStart || resumeWasPendingAtStart)
        if wasPlainStart || resumeNeedsReplay {
            let replayParts =
                resumeNeedsReplay
                ? ([partID] + siblings.filter { !settling.contains($0) })
                : [partID]
            for replayPart in replayParts {
                plainStartsAfterSettling.remove(replayPart)
            }
            // F1's `failed` write is enqueued at the store before the `queued` of any resume that
            // registers after it, so a `failed` seen here is newer than a resume's `queued`: only
            // a replay due to a plain start may overwrite it (its own failure made it `failed`),
            // and only when no other part failed for good meanwhile. Its record write was then a
            // no-op, so queuing the record and restarting this part alone would strand that part.
            // A sibling failure that begins after this check writes `failed` after the `queued`.
            let replayable: Set<DownloadState> =
                resumeNeedsReplay || overlappingFailures.contains(partID)
                ? [.queued, .downloading] : [.queued, .downloading, .failed]
            do {
                // A sign-out pausing the server's records leaves a `failed` one as it is.
                guard !quiescingConnections.contains(context.connectionID),
                    try await store.setState(.queued, forRecord: context.recordID, expecting: replayable)
                else {
                    endFailingForGood(partID, recordID: context.recordID)
                    if let afterPermanentFailure { await afterPermanentFailure(partID) }
                    return
                }
                // One that began during the write may have read the record while it was `failed`.
                if quiescingConnections.contains(context.connectionID) {
                    if replayable.contains(.failed) {
                        _ = try await store.setState(.failed, forRecord: context.recordID, expecting: [.queued])
                    }
                    endFailingForGood(partID, recordID: context.recordID)
                    if let afterPermanentFailure { await afterPermanentFailure(partID) }
                    return
                }
            } catch {
                logError("Couldn't resume a download after its failure settled", error)
                endFailingForGood(partID, recordID: context.recordID)
                if let afterPermanentFailure { await afterPermanentFailure(partID) }
                return
            }
            if resumeNeedsReplay {
                replayedResumeGenerationByPart[partID] = resumeGeneration
            }
            if let beforeReplayStart { await beforeReplayStart(partID) }
            // The replay carries the user's reset for the part it skipped: its budget was
            // persisted as used up by this failure, after any reset the start made.
            // A replay of an automatic resume starts nothing while the app is in the background,
            // as that resume wouldn't: the next activation starts the parts it leaves.
            await start(
                partIDs: replayParts, resumingRecordID: nil, resettingBudgetOf: [partID],
                activationOwnsSession: activationOwnsSession,
                onlyWhileActive: resumeNeedsReplay && guardedResumes.contains(context.recordID))
        }
        endFailingForGood(partID, recordID: context.recordID)
        if let afterPermanentFailure { await afterPermanentFailure(partID) }
    }

    /// Ends one of `partID`'s failures for good in ``failingForGood``. It stays there until its
    /// replay has started, so a sibling that fails meanwhile leaves the record `failed` too.
    private func endFailingForGood(_ partID: UUID, recordID: UUID) {
        if let index = failingForGood[recordID]?.firstIndex(of: partID) {
            failingForGood[recordID]?.remove(at: index)
        }
        if failingForGood[recordID]?.isEmpty == true { failingForGood[recordID] = nil }
        if failingForGood[recordID]?.contains(partID) != true { overlappingFailures.remove(partID) }
    }

    // MARK: - Helpers

    /// Drops what the engine knows about `partID` until the store is read again.
    private func forget(_ partID: UUID) {
        contexts[partID] = nil
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        failures[partID] = nil
        freeRestarts[partID] = nil
        authRetried.remove(partID)
        deferredLaunches.remove(partID)
        throttle.reset(partID)
        delegate.setTarget(nil, for: partID)
    }

    /// The size of the file at the part's destination when its current transfer moved it there:
    /// it has the expected size and was modified after the transfer's start marker
    /// (``DownloadLocations/markTransferStart(partID:)``). The delegate moves a file there only
    /// once it has checked it, but iOS can end the process before its completion is saved.
    /// Every launch clears the marker before the part runs again and writes a new one, so a
    /// file from an earlier transfer (a part requeued after it completed, or one whose
    /// survivor wasn't adopted) is never reused.
    private func movedFileSize(_ partID: UUID, _ context: PartContext) -> Int64? {
        guard context.expectedBytes > 0, let destination = context.destination,
            let started = locations.transferStart(partID: partID)
        else { return nil }
        // A fresh URL, so no cached values are read.
        let values = try? URL(filePath: destination.path(percentEncoded: false))
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize.map(Int64.init), size == context.expectedBytes,
            let modified = values?.contentModificationDate, modified > started
        else { return nil }
        return size
    }

    /// Seals `data` under the task's request; returns whether it was kept.
    private func seal(_ data: Data, partID: UUID, task: URLSessionTask) -> Bool {
        do {
            try vault.seal(
                data, partID: partID, credentialTag: ResumeDataVault.credentialTag(for: task.originalRequest))
            sealedDuringSweep?.insert(partID)
            return true
        } catch {
            logError("Couldn't seal resume data", error)
            vault.delete(partID: partID)
            return false
        }
    }

    /// Runs a store write, logging failures: the engine keeps transferring when one fails.
    private func persist(_ write: (DownloadStore) async throws -> Void) async {
        do {
            try await write(store)
        } catch {
            logError("Couldn't update a download", error)
        }
    }

    /// Runs the write that moves a part out of `running` (to queued or failed). When it fails,
    /// the store still has the part running with no transfer, so its next launch accepts that.
    private func persistIdle(_ partID: UUID, _ write: (DownloadStore) async throws -> Void) async {
        do {
            try await write(store)
            strandedRunning.remove(partID)
        } catch {
            logError("Couldn't update a download", error)
            strandedRunning.insert(partID)
        }
    }

    private func logError(_ message: String, _ error: any Error) {
        Log.downloads.error(
            "\(message, privacy: .public): \(Log.redact(String(describing: error)), privacy: .public)")
    }
}

extension DownloadEngine {
    /// The production factory: a background session with ``sessionIdentifier``.
    public static func backgroundSession() -> DownloadSessionFactory {
        { delegate in
            URLSession(configuration: .absDownloads(), delegate: delegate, delegateQueue: nil)
        }
    }
}
