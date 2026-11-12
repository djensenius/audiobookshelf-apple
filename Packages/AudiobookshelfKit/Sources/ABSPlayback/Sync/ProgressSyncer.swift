import ABSAPI
import ABSCore
import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "ProgressSyncer")

/// The progress transport component (#234 of #53). End-to-end reconciliation belongs to #158.
///
/// - **Cadence.** A streamed session reports `POST /api/session/:id/sync` every ``syncInterval``
///   while playing, and at once on pause, seek, chapter change, the end and ``flush()`` (call it
///   when the app moves to the background). The session's last report goes with the
///   coordinator's `/close` through `finalCloseReport`.
/// - **Listening time** is wall-clock time while playing, independent of rate (ADR 0007). A tick
///   credits the monotonic time since the previous tick only while playing and only if media time
///   advanced; a gap longer than ``maxTickGap`` (a suspension) credits one interval. A seek adds
///   nothing for the jump or for the time the seek took; only confirmed samples earn credit.
/// - **One request at a time.** Every send runs on one serial queue, and a send
///   counts as finished only when the service call returns, after its task has completed. So no
///   report or PATCH goes out while an earlier one could still reach the server. The
///   coordinator's final `/close` doesn't go through this queue, but waits, up to
///   `PlaybackCoordinator.closeWaitTimeout`, for the closing session's report in flight, if any.
///   A report still queued for it is skipped, so it doesn't hold the close back.
/// - **Positions first.** Each report trigger saves `LocalMediaProgress` with `needsServerSync`
///   before sending. Local writes have their own serial queue, so a held request doesn't block
///   saving a newer seek or pause. Failed writes stay in memory for the next trigger or drain,
///   and schedule a drain after a backoff, so a paused session's position isn't left unsaved;
///   no report is sent while a position still needs saving.
///   Final positions enter that queue synchronously in the close callback, even for clean or
///   missing rows. Their throwing receipts acknowledge only committed audio, not listening time.
/// - **Failures.** The position stays in the durable retry queue. Listening time is carried into the next
///   report when the request clearly never reached the server (DNS, connect, TLS, auth) or
///   was turned away before the session handler ran (408, 429).
/// - **Ambiguous failures (#381).** After a timeout, lost response or 5xx the server may or may
///   not have applied the report, so its listening time is kept as an unreconciled snapshot.
///   The first report after ``reconcileDelay`` reads the session (`GET /api/session/:id`) and
///   compares its `timeListening` with the time acknowledged so far: if the snapshot was
///   applied it is acknowledged; if not, it rides along in that report, once only (recovered
///   time is tracked until it is delivered or dropped, so no later failure resends it again);
///   if the lookup fails or the total matches neither, it is dropped and logged, never sent
///   blind. Reports in the meantime carry only new time; a second ambiguous failure first
///   merges into the snapshot, which then counts only if all or none of it was applied.
///   Closing or abandoning the session drops a snapshot still unreconciled (#382).
///   Residual risk: `/sync` has no idempotency key, and the server's session shows only what it
///   has applied, so an unchanged total can't prove the original request will never apply. The
///   delay makes that need a request body the server fully received but still hadn't processed
///   a request timeout plus a margin after the client gave up; then its time counts twice.
/// - **Server errors (#171).** A `/sync` answered with 5xx, 408 or 429 backs off that session's
///   reports for ``syncInterval`` doubled per consecutive failure, up to ``maxSyncBackoff``;
///   ``flush()`` ignores the backoff. Positions are still saved meanwhile, and a periodic report
///   held back by the backoff falls due when it ends; a wake then reports a paused session too,
///   unless a report already went out since the backoff ended. Closing the session cancels it.
///   A 404 means the server no longer has the session (ABS keeps open sessions in memory, so a
///   restart drops them): the session sends no more `/sync`, and each later trigger drains the
///   saved position through PATCH instead, until the server rejects the session's own row.
///   Listening time from that 404 on is not sent (to be decided with offline sessions, #158).
/// - **Durable queue.** ``drainPendingProgress()`` PATCHes the connection's dirty rows, one group
///   per request from `LocalProgressStore.beginSend`, in its order (audio, finished, ebook). It
///   runs after every successful `/sync` and on ``flush()``; call it on reconnect and at launch.
///   A successful `/sync` still drains the saved position through PATCH: only the store's PATCH
///   acknowledgement clears the dirty group, without clearing a newer edit. Clean rows are kept.
///   Failed settlements retain their token and outcome for the next drain. A PATCH rejected
///   for good (``isPermanent(_:)``: 400, 404, 410, 422) is settled with `rejectSend`, so the row
///   stops being retried until it is edited again. A drain that stopped on any other failure
///   (a PATCH, a pending row's GET or a store save) schedules one more drain, backed off like
///   `/sync`; a drain that completes cleanly resets that backoff. Both wakes are cancelled on
///   detach and quiesce.
///   Each pending row is fetched once before sending. Unusable or rejected progress defers that
///   row; a thrown lookup stops the pass. In a real conflict, a server value newer than the edit
///   wins by ADR 0003 and that group isn't PATCHed over it. A group ADR 0003 shields, because the
///   server's value may be this device's own send or a side effect of one, keeps its edit without
///   that check, so its PATCH can overwrite another device's newer value. Nor does the merge
///   cover another device's write between GET and PATCH (the server offers no conditional write
///   here), or clock skew between this device's edit time and the server's `lastUpdate`
///   (ADR 0007 decision 8, "Stale writes"). The drain never sends a `/sync`; after the
///   confirmations below, it resends the `/close`s the coordinator couldn't confirm
///   (``CloseRetryQueue``, #382), each only once
///   ``admitDeferredReport(sessionID:key:currentTime:editedAt:)`` admits it.
///   After settlements, outstanding PATCH acknowledgements get one confirmation lookup per key,
///   even on clean-only drains. Unresolved obligations remain for a later drain, without a resend.
///   Finally, the still-loaded session gets one baseline lookup if its key was not already read.
///   This only refreshes storage; it never changes playback or creates a report trigger.
/// - **Reconnect.** Given a `NetworkPathSource`, an offline path followed by an online one runs
///   ``drainPendingProgress()``, which also retries the active baseline lookup that a failed or
///   offline start skipped, as does an online path whose `onlineEpoch` grew (the offline path in
///   between was dropped). Repeated online paths and an online first path don't drain.
@MainActor
public final class ProgressSyncer {
    /// Seconds between reports while playing (legacy `TIME_BETWEEN_SESSION_SYNC_IN_SECONDS`).
    public static let syncInterval: TimeInterval = 15
    /// The longest `/sync` backoff after consecutive server errors.
    public static let maxSyncBackoff: TimeInterval = 300
    /// PATCHes per row in one drain: each group once, plus re-sends of groups edited meanwhile.
    static let maxSendsPerRow = 6

    struct Position: Equatable {
        let revision: UInt64
        let token: PlaybackPositionToken
        let time: Double
        let duration: Double
        let editedAt: Date
    }

    struct CurrentSession {
        /// Local ownership, not just the media key (or a server's reused session identifier).
        let ownership = UUID()
        let sessionID: String
        let key: MediaKey
        /// `sessionStarted` precedes position resolution; only `loaded` makes the position reportable.
        var hasLoaded = false
        /// Listening time not yet handed to a report.
        var listened: TimeInterval = 0
        /// The session's listening time the server is known to have applied.
        var ackedTotal: TimeInterval = 0
        /// An ambiguously failed report's listening time, how much of it was already a resend
        /// (which isn't resent again), and the monotonic time the client gave up on it.
        var unreconciled: (delta: TimeInterval, resent: TimeInterval, failedAt: TimeInterval)?
        /// Of `listened`, the time a reconciliation recovered: already sent once, so a later
        /// ambiguous failure doesn't resend it. Consumed and restored together with `listened`.
        var recovered: TimeInterval = 0
        /// The latest report trigger, persisted independently of transport.
        var position: Position?
        /// Consecutive `/sync`s answered with 5xx, 408 or 429.
        var syncFailures = 0
        /// No `/sync` before this monotonic time, except from ``flush()``.
        var retryAt: TimeInterval?
        /// The server answered `/sync` with 404: triggers drain the position instead.
        var isAbandoned = false
        /// A PATCH of this abandoned session's row was rejected for good (the item is likely
        /// gone): its triggers only save the position, so they don't re-PATCH and log each time.
        var isRowRejected = false
    }

    private weak var source: (any PlaybackProgressSource)?
    let service: any ProgressSyncService
    let store: LocalProgressStore
    let clock: ProgressSyncClock
    private let tickInterval: TimeInterval
    private var observer: PlaybackObserverToken?

    private(set) var current: CurrentSession?
    private var isPlaying = false
    private var lastTick: (uptime: TimeInterval, mediaTime: Double)?
    private var lastSyncAt: TimeInterval?
    private var chapterIndex: Int?
    /// The `didSeek` the coordinator emits right after `loaded` is the resume position, not a seek.
    private var loadedTime: Double?
    /// The session with a `/sync` queued but not started; later requests join it.
    private var queuedSyncSessionID: String?
    /// Whether a ``flush()`` joined the queued `/sync`, so it goes out despite a backoff.
    private var queuedSyncIgnoresBackoff = false
    /// The `/sync` inside `service.syncSession` now, resolved when the call returns. Its
    /// session's final close waits for it; queued reports don't count.
    private var inFlightSync: (sessionID: String, done: PlaybackCloseResult<Void>)?
    private var tail: Task<Void, Never>?
    private var persistenceTail: Task<Void, Never>?
    /// Test seam: hold local persistence independently of transport.
    var beforePositionPersistence: (@MainActor () async -> Void)?
    /// Test seam at the capture-to-evidence boundary; no transport has been issued here.
    var beforeSessionAudioPreparation: (@MainActor () async -> Void)?
    /// Test seam: hold a prepared PATCH before its return is consumed by transport checks.
    var afterProgressSendPreparation: (@MainActor (ProgressPatch) async -> Void)?
    /// Test seam: observes a drain ending, once any retry is scheduled.
    var afterDrain: (@MainActor () -> Void)?
    /// Test seam before the active refresh's throwing provenance lookup.
    var beforeActiveProgressCapture: (@MainActor () async -> Void)?
    /// Test seam: observes admission without suspending between ownership validation and store submission.
    var activeProgressIntakeSubmitted: (@MainActor () -> Void)?
    private(set) var pendingPositions: [MediaKey: Position] = [:]
    /// The pending positions whose last save failed, as opposed to ones merely still queued.
    private var failedPositions: [MediaKey: Position] = [:]
    private(set) var positionRevision: UInt64 = 0
    private var positionReceipts: [MediaKey: [(revision: UInt64, receipt: PlaybackCloseResult<Void>)]] = [:]
    private var transportTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isTransportQuiesced = false
    /// `nil` error means success; neither outcome may be forgotten if the store throws.
    private var pendingSettlements: [MediaKey: (patch: ProgressPatch, error: String?, rejected: Bool)] = [:]
    /// Set by ``detach()``: queued requests are skipped; issued calls are canceled best-effort.
    private(set) var isDetached = false
    /// A drain is queued but not started; later requests join it.
    private var isDrainQueued = false
    /// The `/sync` scheduled for when the current session's backoff ends. Readable for tests.
    private(set) var syncWake: Task<Void, Never>?
    /// The drain scheduled after a drain that stopped on a failure. Readable for tests.
    private(set) var drainWake: Task<Void, Never>?
    /// Consecutive drains that stopped on a failure.
    private var drainFailures = 0
    /// How the drain running now ended: on a failure, or after its last pending row and
    /// confirmation (neither when it stopped early for another reason, such as a newer position).
    var drainOutcome: (failed: Bool, completed: Bool) = (false, false)
    /// Follows the network path; cancelled on detach and quiesce. Readable for tests to join.
    private(set) var pathTask: Task<Void, Never>?
    /// Test seam: called after each network path is handled, with whether it queued a drain
    /// (join it with ``waitForIdle()``).
    var pathHandled: (@MainActor (NetworkPath, Bool) -> Void)?
    /// Closes the coordinator couldn't confirm, kept to retry (#382).
    let closeQueue = CloseRetryQueue()

    /// Starts following `source`: observes its events and supplies its `finalCloseReport`.
    /// - Parameter store: Reuse the same writer across account-scope lifetimes. Independent
    ///   writers over the same database do not share in-process playback-position ordering.
    /// - Parameter tickInterval: The engine's time-update interval (`AudioEngine`'s
    ///   `timeObserverInterval`).
    /// - Parameter paths: The network path, to drain when it comes back online (pass
    ///   `SystemNetworkPathSource`); `nil` leaves reconnect draining to the caller.
    public init(
        source: any PlaybackProgressSource, service: any ProgressSyncService, store: LocalProgressStore,
        clock: ProgressSyncClock = .live, tickInterval: TimeInterval = 0.5, paths: (any NetworkPathSource)? = nil
    ) {
        self.source = source
        self.service = service
        self.store = store
        self.clock = clock
        self.tickInterval = tickInterval
        observer = source.addObserver { [weak self] event in self?.handle(event) }
        source.finalCloseReport = { [weak self] closing in
            guard let self, let handoff = closeReport(for: closing) else { return nil }
            // closeReport just queued the closing position: its token stamps the retained close.
            retainClose(handoff, for: closing, token: pendingPositions[closing.key]?.token)
            return handoff
        }
        source.quiesceProgressTransport = { [weak self] in self?.quiesceTransport() }
        if let paths { watch(paths.paths()) }
    }

    isolated deinit {
        pathTask?.cancel()
        syncWake?.cancel()
        drainWake?.cancel()
    }

    /// Stops following the source and quiesces transport. Owned position writes still finish.
    public func detach() {
        quiesceTransport()
        isDetached = true
        if let observer { source?.removeObserver(observer) }
        observer = nil
        source?.finalCloseReport = nil
        source?.quiesceProgressTransport = nil
        source = nil
        current = nil
    }

    /// Permanently prevents queued/new sync and PATCH calls and cancels issued calls best-effort.
    /// Does not detach the final-position reporter or cancel any local write; never calls `flush`.
    public func quiesceTransport() {
        isTransportQuiesced = true
        pathTask?.cancel()
        pathTask = nil
        syncWake?.cancel()
        syncWake = nil
        drainWake?.cancel()
        drainWake = nil
        for task in transportTasks.values { task.cancel() }
    }

    // MARK: Commands

    /// Reports the current session now, even while its reports back off, and drains the durable
    /// queue; returns when both are done. Call when the app moves to the background.
    public func flush() async {
        if current != nil {
            creditPlayedTime()
            requestSync(ignoringBackoff: true)
        }
        await drainPendingProgress()
    }

    /// PATCHes dirty rows, confirms outstanding ACKs and refreshes the still-loaded baseline;
    /// returns when done. Call on launch and, without a path source, when the network comes back.
    public func drainPendingProgress() async {
        requestDrain()
        await waitForIdle()
    }

    private func requestDrain() {
        guard !isDrainQueued else { return }
        isDrainQueued = true
        enqueue { [weak self] in
            self?.isDrainQueued = false
            await self?.drain()
        }
    }

    /// Drains on each offline-to-online transition, not on repeated or initial online paths.
    /// The drain is queued, not awaited: the system source keeps only the newest path, so
    /// blocking here could miss an offline-to-online cycle while a drain's request is in flight.
    /// An offline path the stream dropped still shows as a grown `onlineEpoch`.
    private func watch(_ paths: AsyncStream<NetworkPath>) {
        pathTask = Task { [weak self] in
            var previous: NetworkPath?
            for await path in paths {
                guard let self, !self.isDetached, !self.isTransportQuiesced else { return }
                let reconnected =
                    previous.map { path.isOnline && (!$0.isOnline || path.onlineEpoch != $0.onlineEpoch) } ?? false
                previous = path
                if reconnected { self.requestDrain() }
                self.pathHandled?(path, reconnected)
            }
        }
    }

    /// Waits for every queued report, store write and PATCH.
    func waitForIdle() async {
        await waitForPendingWrites()
        while let task = tail {
            await task.value
            if tail == task {
                tail = nil
                break
            }
        }
        await waitForPendingWrites()
    }

    /// Waits for local writes independently of a held network request.
    func waitForPendingWrites() async {
        while let task = persistenceTail {
            await task.value
            if persistenceTail == task {
                persistenceTail = nil
                return
            }
        }
    }

    // MARK: Events

    private func handle(_ event: PlaybackCoordinatorEvent) {
        let now = clock.uptime()
        switch event {
        case .sessionStarted(let sessionID, let key):
            guard key.serverConnectionID == service.serverConnectionID else { return }
            current = CurrentSession(sessionID: sessionID, key: key)
            syncWake?.cancel()
            syncWake = nil
            isPlaying = false
            lastTick = nil
            loadedTime = nil
        case .loaded(let time):
            current?.hasLoaded = true
            loadedTime = time
            lastSyncAt = now
            chapterIndex = source?.chapterIndex
            if source?.loadedPositionIsExplicit == true, let session = current {
                // A chapter/start-time or pending seek/jump is new intent, not listening credit
                // or a network trigger. It must supersede a held final close even with no tick.
                queuePosition(session.key, time: time, duration: source?.duration ?? 0)
            }
        case .playbackStarted:
            isPlaying = true
            lastSyncAt = now
            lastTick = source?.confirmedPlaybackTime.map { (now, $0) }
        case .paused, .ended:
            creditPlayedTime()
            isPlaying = false
            lastTick = nil
            requestSync()
        case .didSeek(let time):
            defer { loadedTime = nil }
            chapterIndex = source?.chapterIndex
            lastTick = isPlaying ? (now, time) : nil
            if loadedTime != time { requestSync() }
        case .tick(let time):
            tick(time, now: now)
        case .sessionWillClose(let closing):
            if current?.sessionID == closing.sessionID {
                current = nil
                cancelSyncWake()
            }
            isPlaying = false
            lastTick = nil
        case .itemChanged, .failed:
            break
        }
    }

    private func tick(_ time: Double, now: TimeInterval) {
        guard current != nil else { return }
        let playing = isPlaying && source?.isPlaying == true && source?.confirmedPlaybackTime != nil
        if playing, let last = lastTick, time > last.mediaTime {
            current?.listened += credit(for: now - last.uptime)
        }
        lastTick = playing ? (now, time) : nil
        let chapter = source?.chapterIndex
        if chapter != chapterIndex {
            chapterIndex = chapter
            requestSync()
        } else if playing, let lastSyncAt, now - lastSyncAt >= Self.syncInterval {
            requestSync()
        }
    }

    /// The body of the coordinator's final `/close`: the closing position and the listening time
    /// no report carried yet.
    private func closeReport(for closing: ClosingSession) -> PlaybackCloseHandoff? {
        var listened: TimeInterval = 0
        if current?.sessionID == closing.sessionID {
            creditPlayedTime()
            listened = current?.listened ?? 0
            if let snapshot = current?.unreconciled {
                // TODO(#382): reconcile it before the close.
                logDroppedSnapshot(snapshot.delta, reason: "the session closed before it was reconciled")
            }
            current = nil
            cancelSyncWake()
        }
        guard
            let report = PlaybackSyncReport(
                currentTime: closing.currentTime, timeListened: listened, duration: closing.duration),
            let position = queuePosition(closing.key, time: closing.currentTime, duration: closing.duration)
        else { return nil }
        let receipt = PlaybackCloseResult<Void>()
        positionReceipts[closing.key, default: []].append((position.revision, receipt))
        let sessionSync = inFlightSync?.sessionID == closing.sessionID ? inFlightSync?.done : nil
        return PlaybackCloseHandoff(report: report, position: receipt, sessionSync: sessionSync)
    }

    /// A final sample may advance after the last tick. Targets and stalls earn nothing, and
    /// every observation refreshes the baseline so later playback cannot inherit a stalled gap.
    private func creditPlayedTime() {
        let now = clock.uptime()
        let sample = source?.confirmedPlaybackTime
        defer { lastTick = sample.map { (now, $0) } }
        guard isPlaying, let last = lastTick, let sample, sample > last.mediaTime else { return }
        current?.listened += credit(for: now - last.uptime)
    }

    /// The longest gap between ticks still counted as play; a longer one (the app was suspended)
    /// credits one tick interval. At least 2 s, so a short stall with fast ticks isn't cut.
    var maxTickGap: TimeInterval { max(2 * tickInterval, 2) }

    private func credit(for gap: TimeInterval) -> TimeInterval {
        guard gap.isFinite, gap > 0 else { return 0 }
        return gap > maxTickGap ? tickInterval : gap
    }

    // MARK: Queue

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        let id = UUID()
        let task = Task {
            await previous?.value
            await operation()
            transportTasks[id] = nil
        }
        tail = task
        transportTasks[id] = task
    }

    private func requestSync(ignoringBackoff: Bool = false) {
        guard !isDetached, !isTransportQuiesced, let session = current, let source,
            session.hasLoaded,
            let position = queuePosition(session.key, time: source.currentTime, duration: source.duration)
        else { return }
        current?.position = position
        let sessionID = session.sessionID
        let now = clock.uptime()
        if !session.isAbandoned, !ignoringBackoff, let retryAt = session.retryAt, now < retryAt {
            // The next periodic report falls due when the backoff ends, not an interval from now.
            lastSyncAt = retryAt - Self.syncInterval
            return
        }
        lastSyncAt = now
        if session.isAbandoned {
            if !session.isRowRejected { requestDrain() }
            return
        }
        guard queuedSyncSessionID != sessionID else {
            // A flush joining a queued report keeps its bypass of the backoff.
            if ignoringBackoff { queuedSyncIgnoresBackoff = true }
            return
        }
        queuedSyncSessionID = sessionID
        queuedSyncIgnoresBackoff = ignoringBackoff
        enqueue { [weak self] in await self?.sendSync(sessionID: sessionID) }
    }

    /// Sends the latest saved trigger for `sessionID`, if it is still current.
    private func sendSync(sessionID: String) async {
        await waitForPendingWrites()
        var ignoringBackoff = false
        if queuedSyncSessionID == sessionID {
            queuedSyncSessionID = nil
            ignoringBackoff = queuedSyncIgnoresBackoff
        }
        guard await settleSessionAudioOutcomes() else { return }
        guard !isDetached, !isTransportQuiesced else { return }
        guard pendingPositions.isEmpty else {
            // A paused session may never report again: the drain's retry saves and sends it.
            if hasFailedPositionSave, drainWake == nil { scheduleDrainRetry() }
            return
        }
        guard var session = current, session.sessionID == sessionID, session.position != nil
        else { return }
        // A failure answered while this report was queued may have abandoned or backed off the
        // session; its listening time stays for the next report.
        if session.isAbandoned {
            if !session.isRowRejected { await drain() }
            return
        }
        if !ignoringBackoff, let retryAt = session.retryAt, clock.uptime() < retryAt {
            lastSyncAt = retryAt - Self.syncInterval
            return
        }
        if let snapshot = session.unreconciled, clock.uptime() >= snapshot.failedAt + reconcileDelay {
            await reconcile(sessionID: sessionID)
            guard !isDetached, !isTransportQuiesced, let reread = current, reread.sessionID == sessionID,
                reread.position != nil
            else { return }
            session = reread
        }
        guard let position = session.position else { return }
        let listened = session.listened
        guard
            let report = PlaybackSyncReport(
                currentTime: position.time, timeListened: listened, duration: position.duration)
        else {
            return
        }
        let evidence: SessionAudioSend
        do {
            await beforeSessionAudioPreparation?()
            guard
                let prepared = try await store.prepareSessionAudio(
                    for: session.key, token: position.token,
                    audio: .init(
                        currentTime: report.currentTime, duration: report.duration,
                        progress: report.duration > 0 ? min(report.currentTime / report.duration, 1) : 0),
                    sessionID: sessionID)
            else { return }
            evidence = prepared
        } catch {
            logger.error("Preparing session audio evidence failed: \(String(describing: error), privacy: .public)")
            return
        }
        // Preparation suspends. An ended scope may settle local evidence, never issue a request.
        guard !isDetached, !isTransportQuiesced, current?.sessionID == sessionID else {
            await settleSessionAudio(evidence, outcome: .notDelivered)
            return
        }
        // Ticks during the evidence save belong to the next report, not this captured delta.
        let resent = session.recovered
        current?.listened -= listened
        current?.recovered -= resent
        let outcome: SessionAudioOutcome
        // No suspension between the guard above and the call: a close sees it in flight.
        let done = PlaybackCloseResult<Void>()
        inFlightSync = (sessionID, done)
        do {
            defer {
                done.resolve(.success(()))
                if inFlightSync?.done === done { inFlightSync = nil }
            }
            try await service.syncSession(id: sessionID, report: report)
            outcome = .succeeded
            if current?.sessionID == sessionID {
                current?.ackedTotal += report.timeListened
                current?.syncFailures = 0
                current?.retryAt = nil
                cancelSyncWake()
            }
        } catch {
            let abandoned = noteSyncFailure(error, sessionID: sessionID)
            if case .notFound = error as? APIError {
                // No session, so the server applied nothing; but there's no session to resend to.
                outcome = .notDelivered
                if listened > 0 {
                    logger.info(
                        "Dropped \(listened, privacy: .public) s of listening time: the server no longer has the session (#337)"
                    )
                }
                if abandoned, let snapshot = current?.unreconciled {
                    current?.unreconciled = nil
                    logDroppedSnapshot(snapshot.delta, reason: "the server no longer has the session")
                }
            } else if Self.neverReachedServer(error) || Self.wasTurnedAway(error) {
                outcome = .notDelivered
                if current?.sessionID == sessionID {
                    current?.listened += listened
                    current?.recovered += resent
                } else if listened > 0 {
                    // TODO(#158): carry it into the closed session's reconciliation.
                    logger.info(
                        "Dropped \(listened, privacy: .public) s of listening time: the session closed before it could be resent"
                    )
                }
            } else {
                outcome = .ambiguous
                if current?.sessionID == sessionID {
                    // Kept until the next report learns whether the server applied it.
                    if listened > 0 {
                        // An earlier snapshot still waiting merges in: its outcome isn't known either.
                        let earlier = current?.unreconciled
                        current?.unreconciled = (
                            listened + (earlier?.delta ?? 0), resent + (earlier?.resent ?? 0), clock.uptime()
                        )
                    }
                } else if listened > 0 {
                    logger.info(
                        "Dropped \(listened, privacy: .public) s of listening time after an ambiguous sync failure (\(Self.caseName(error), privacy: .public)): the session closed"
                    )
                }
            }
            await settleSessionAudio(evidence, outcome: outcome)
            // The saved position still reaches the server, through PATCH.
            if abandoned { await drain() }
            return
        }
        guard await settleSessionAudio(evidence, outcome: outcome) else { return }
        await drain()
    }

    /// How close the server's total must be to count as matching: it sums the same doubles, so
    /// this only absorbs rounding.
    static let reconcileTolerance: TimeInterval = 0.5

    /// How long after giving up on an ambiguous `/sync` the session is looked up: the default
    /// request timeout (30 s) plus a 30 s margin for a request the server is still processing.
    var reconcileDelay: TimeInterval = 60

    /// Learns whether the server applied the ambiguous snapshot, from the session's
    /// `timeListening`. Not applied, it joins this report's listening time once, as recovered
    /// time. Otherwise the snapshot is acknowledged or dropped, never sent blind.
    private func reconcile(sessionID: String) async {
        guard let session = current, session.sessionID == sessionID, let snapshot = session.unreconciled
        else { return }
        current?.unreconciled = nil
        let ownership = session.ownership
        let serverTotal: TimeInterval
        do {
            serverTotal = try await service.openSession(id: sessionID).timeListening
        } catch {
            logDroppedSnapshot(snapshot.delta, reason: "the session lookup failed (\(Self.caseName(error)))")
            return
        }
        guard !isDetached, !isTransportQuiesced, current?.ownership == ownership else {
            logDroppedSnapshot(snapshot.delta, reason: "the session ended while it was reconciled")
            return
        }
        let acked = session.ackedTotal
        current?.ackedTotal = serverTotal
        if serverTotal >= acked + snapshot.delta - Self.reconcileTolerance {
            return
        }
        guard abs(serverTotal - acked) <= Self.reconcileTolerance else {
            logDroppedSnapshot(
                snapshot.delta, reason: "the server's total \(serverTotal) s matches neither outcome")
            return
        }
        if snapshot.resent > 0 {
            logDroppedSnapshot(snapshot.resent, reason: "it was already resent once")
        }
        let resend = snapshot.delta - snapshot.resent
        current?.listened += resend
        current?.recovered += resend
    }

    private func logDroppedSnapshot(_ delta: TimeInterval, reason: String) {
        guard delta > 0 else { return }
        logger.info(
            "Dropped \(delta, privacy: .public) s of unreconciled listening time: \(reason, privacy: .public)")
    }

    /// Records a server's answer to a failed `/sync`: 404 abandons the session, and 5xx, 408 and
    /// 429 back it off. Returns whether the session was abandoned.
    private func noteSyncFailure(_ error: any Error, sessionID: String) -> Bool {
        guard current?.sessionID == sessionID, let error = error as? APIError else { return false }
        switch error {
        case .notFound:
            current?.isAbandoned = true
            logger.error("The server no longer has the playback session; reporting its position by PATCH")
            return true
        case .http(let status, _) where status == 408 || status == 429 || (500..<600).contains(status):
            let failures = (current?.syncFailures ?? 0) + 1
            let backoff = Self.syncBackoff(afterFailures: failures)
            let retryAt = clock.uptime() + backoff
            current?.syncFailures = failures
            current?.retryAt = retryAt
            // Report when the backoff ends even if no tick or pause triggers it (a paused session).
            // The clock and the sleep are both monotonic, so the backoff has ended by then. Not
            // if a newer failure moved it, or a report already went out since it ended. A report
            // still in flight (a flush ignores the backoff) answers first: its success cancels
            // this wake and a server error reschedules it; any other failure leaves it to retry.
            let ownership = current?.ownership
            syncWake?.cancel()
            syncWake = scheduleWake(after: backoff) { syncer in
                while let inFlight = syncer.inFlightSync, inFlight.sessionID == syncer.current?.sessionID {
                    guard (try? await inFlight.done.wait()) != nil else { return }
                }
                guard !Task.isCancelled, !syncer.isDetached, !syncer.isTransportQuiesced,
                    syncer.current?.ownership == ownership, syncer.current?.retryAt == retryAt
                else { return }
                syncer.syncWake = nil
                if let sent = syncer.lastSyncAt, sent >= retryAt { return }
                syncer.requestSync()
            }
            return false
        default:
            return false
        }
    }

    private func cancelSyncWake() {
        syncWake?.cancel()
        syncWake = nil
    }

    /// Runs `action` after `delay` monotonic seconds, unless cancelled, detached or quiesced first.
    private func scheduleWake(
        after delay: TimeInterval, _ action: @escaping @MainActor (ProgressSyncer) async -> Void
    ) -> Task<Void, Never> {
        let sleep = clock.sleep
        return Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, !self.isDetached, !self.isTransportQuiesced else { return }
            await action(self)
        }
    }

    /// ``syncInterval`` doubled per consecutive failure after the first, up to ``maxSyncBackoff``.
    static func syncBackoff(afterFailures failures: Int) -> TimeInterval {
        min(syncInterval * Double(1 << min(max(failures - 1, 0), 10)), maxSyncBackoff)
    }

    @discardableResult
    private func settleSessionAudio(_ send: SessionAudioSend, outcome: SessionAudioOutcome) async -> Bool {
        do {
            try await store.settleSessionAudio(send, outcome: outcome)
            return true
        } catch {
            logger.error("Saving session audio outcome failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func settleSessionAudioOutcomes() async -> Bool {
        do {
            try await store.retrySessionAudioSettlements(for: service.serverConnectionID)
            return true
        } catch {
            logger.error("Retrying session audio outcome failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func queuePosition(
        _ key: MediaKey, time: Double, duration: Double
    ) -> Position? {
        guard time.isFinite, time >= 0 else { return nil }
        let duration = duration.isFinite && duration > 0 ? duration : 0
        positionRevision += 1
        let position = Position(
            revision: positionRevision, token: store.reservePlaybackPosition(for: key),
            time: time, duration: duration, editedAt: clock.now())
        pendingPositions[key] = position
        queuePersistence()
        return position
    }

    private func queuePersistence() {
        let previous = persistenceTail
        // Strong ownership is intentional: detach, release and waiter cancellation cannot drop
        // captured writes. Coalesced receipts are resolved only by a committed newer revision.
        persistenceTail = Task {
            await previous?.value
            await beforePositionPersistence?()
            let positions = pendingPositions
            for (key, queuedPosition) in positions {
                let position = queuedPosition
                guard pendingPositions[key] == position else { continue }
                let progress = position.duration > 0 ? min(position.time / position.duration, 1) : 0
                do {
                    // Store-scoped ordering is checked at the actual commit boundary, including
                    // when a newer scope committed while this scope's write was held.
                    _ = try await store.recordPlaybackPosition(
                        .init(currentTime: position.time, duration: position.duration, progress: progress),
                        for: key, token: position.token, now: position.editedAt)
                    // A newer event may have arrived while the save ran.
                    if pendingPositions[key] == position { pendingPositions[key] = nil }
                    failedPositions[key] = nil
                    finishReceipts(for: key, through: position.revision, result: .success(()))
                } catch {
                    failedPositions[key] = position
                    finishReceipts(for: key, through: position.revision, result: .failure(error))
                    logger.error("Saving pending progress failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func finishReceipts(for key: MediaKey, through revision: UInt64, result: Result<Void, any Error>) {
        let receipts = positionReceipts[key, default: []].filter { $0.revision <= revision }
        positionReceipts[key]?.removeAll { $0.revision <= revision }
        for entry in receipts { entry.receipt.resolve(result) }
    }

    // MARK: Durable queue

    /// One drain pass. One that stopped on a failure schedules another, backed off like `/sync`.
    private func drain() async {
        drainOutcome = (false, false)
        await drainPass()
        defer { afterDrain?() }
        guard !isDetached, !isTransportQuiesced else { return }
        // A position whose save failed stopped the drain as surely as a failed request did.
        if drainOutcome.failed || hasFailedPositionSave {
            scheduleDrainRetry()
        } else if drainOutcome.completed {
            drainFailures = 0
            drainWake?.cancel()
            drainWake = nil
        }
    }

    /// Whether a pending position is one whose save failed, not a newer one still being saved.
    private var hasFailedPositionSave: Bool {
        pendingPositions.contains { failedPositions[$0.key] == $0.value }
    }

    /// Drains again after a backoff, which grows with each failed drain.
    func scheduleDrainRetry() {
        drainFailures += 1
        drainWake?.cancel()
        drainWake = scheduleWake(after: Self.syncBackoff(afterFailures: drainFailures)) { syncer in
            syncer.drainWake = nil
            syncer.requestDrain()
        }
    }

    private func drainPass() async {
        guard await settleSessionAudioOutcomes() else {
            drainOutcome.failed = true
            return
        }
        guard !isDetached, !isTransportQuiesced else { return }
        queuePersistence()
        await waitForPendingWrites()
        guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
        for outcome in Array(pendingSettlements.values) {
            guard await settle(outcome.patch, error: outcome.error, rejected: outcome.rejected) else { return }
        }
        let rows: [LocalMediaProgressDTO]
        do {
            rows = try await store.pendingSync(for: service.serverConnectionID)
        } catch {
            logger.error("Reading pending progress failed: \(String(describing: error), privacy: .public)")
            drainOutcome.failed = true
            return
        }
        var attemptedConfirmations: [MediaKey: UUID] = [:]
        // A GET attempt suppresses only the extra active refresh, never a genuinely new ACK.
        var attemptedKeys: Set<MediaKey> = []
        for row in rows {
            await waitForPendingWrites()
            guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
            do {
                guard
                    try await fetchProgress(
                        for: row.key, attempted: &attemptedConfirmations, attemptedKeys: &attemptedKeys)
                else { continue }
            } catch {
                logger.error("Fetching pending progress failed: \(String(describing: error), privacy: .public)")
                drainOutcome.failed = true
                return
            }
            for _ in 0..<Self.maxSendsPerRow {
                await waitForPendingWrites()
                guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
                let patch: ProgressPatch?
                let sendPositionRevision: UInt64
                do {
                    // Intake may have cleaned the row; edits made during suspension belong to
                    // the current row, never the pre-fetch pendingSync snapshot.
                    guard try await store.progress(for: row.key)?.needsServerSync == true else { break }
                    guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
                    sendPositionRevision = positionRevision
                    patch = try await store.beginSend(for: row.key, now: clock.now())
                    if let patch { await afterProgressSendPreparation?(patch) }
                } catch {
                    logger.error("Starting a progress send failed: \(String(describing: error), privacy: .public)")
                    drainOutcome.failed = true
                    break
                }
                guard let patch else { break }
                guard !isDetached, !isTransportQuiesced else {
                    _ = await settle(patch, error: "accountEnded")
                    return
                }
                // A newer owned write may already have persisted and left pendingPositions.
                guard pendingPositions.isEmpty, positionRevision == sendPositionRevision else {
                    _ = await settle(patch, error: "pendingPosition")
                    return
                }
                guard let update = Self.update(for: patch.values) else {
                    logger.fault("beginSend returned a send with no group")
                    _ = await settle(patch, error: "emptySend")
                    break
                }
                do {
                    try await service.updateProgress(
                        itemID: row.key.libraryItemId, episodeID: row.key.episodeId, update)
                } catch {
                    if let status = Self.permanentStatus(error) {
                        logger.error(
                            "The server rejected a progress PATCH for \(row.key.rawValue, privacy: .private(mask: .hash)) with status \(status, privacy: .public); not retrying it until the next edit"
                        )
                        if current?.isAbandoned == true, current?.key == row.key { current?.isRowRejected = true }
                        guard await settle(patch, error: "rejected \(status)", rejected: true) else { return }
                        break
                    }
                    drainOutcome.failed = true
                    guard await settle(patch, error: Self.caseName(error)) else { return }
                    if Self.isOffline(error) { return }
                    break
                }
                guard await settle(patch, error: nil) else { return }
            }
        }
        // Snapshot keys once, not once per group ACK. A new ACK after a pre-drain GET is a
        // distinct obligation, but a rejected GET must not immediately retry the same ACK.
        let confirmations = await store.needsConfirmationFetch
            .filter { $0.serverConnectionID == service.serverConnectionID }
            .sorted { $0.rawValue < $1.rawValue }
        for key in confirmations {
            await waitForPendingWrites()
            guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
            do {
                _ = try await fetchProgress(
                    for: key, attempted: &attemptedConfirmations, attemptedKeys: &attemptedKeys,
                    confirmationOnly: true)
            } catch {
                logger.error("Confirming progress failed: \(String(describing: error), privacy: .public)")
                drainOutcome.failed = true
                return
            }
        }
        guard await retryRetainedCloses() else { return }
        drainOutcome.completed = true
        await refreshActiveProgress(unlessAttempted: attemptedKeys)
    }

    /// At most one canonical GET for the still-loaded session's key, if this drain has not read it.
    /// Durable progress only: never the engine, playback state, LastPlayed or the resume decision.
    private func refreshActiveProgress(unlessAttempted attemptedKeys: Set<MediaKey>) async {
        await waitForPendingWrites()
        guard let session = current, session.hasLoaded,
            session.key.serverConnectionID == service.serverConnectionID,
            !attemptedKeys.contains(session.key), ownsActiveRefresh(session)
        else { return }
        do {
            await beforeActiveProgressCapture?()
            guard ownsActiveRefresh(session) else { return }
            // Reuse the start capability: pre-request generation AND row identity, including
            // explicit absence and deletion invalidation. A failed read is never absence.
            let capture = try await store.captureStartProgress(for: session.key)
            guard ownsActiveRefresh(session) else { return }
            let progress = try await service.fetchProgress(
                itemID: session.key.libraryItemId, episodeID: session.key.episodeId)
            await waitForPendingWrites()
            guard ownsActiveRefresh(session), let progress else { return }
            // No suspension between ownership admission and submission. Already-submitted
            // actor work is not retroactively cancelled; atomic store provenance still applies.
            activeProgressIntakeSubmitted?()
            _ = try await store.applyStartProgress(progress, captured: capture)
        } catch {
            logger.error("Refreshing active progress failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Admission belongs to this loaded session, not merely its media key.
    private func ownsActiveRefresh(_ session: CurrentSession) -> Bool {
        !isDetached && !isTransportQuiesced && pendingPositions.isEmpty && pendingSettlements.isEmpty
            && current?.ownership == session.ownership && current?.hasLoaded == true
    }

    /// Shared canonical intake for pre-drain and confirmation. A successful merge is not a
    /// confirmation receipt: the store alone owns and releases the acknowledgement obligation.
    func fetchProgress(
        for key: MediaKey, attempted: inout [MediaKey: UUID], attemptedKeys: inout Set<MediaKey>,
        confirmationOnly: Bool = false
    ) async throws -> Bool {
        let capture = await store.captureProgressFetch(for: key)
        guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return false }
        if confirmationOnly {
            guard let acknowledgement = capture.acknowledgement, attempted[key] != acknowledgement else {
                return false
            }
        }
        if let acknowledgement = capture.acknowledgement { attempted[key] = acknowledgement }
        let capturedAt = capture.generation
        attemptedKeys.insert(key)
        let progress = try await service.fetchProgress(itemID: key.libraryItemId, episodeID: key.episodeId)
        await waitForPendingWrites()
        guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return false }
        guard let progress else {
            // Both pinned servers return 404 for absent user progress; the canonical API maps
            // only that error to nil. Permit first-progress creation without inventing a dated
            // zero baseline or releasing post-ACK socket suppression.
            return !(await store.hasChanged(key, since: capturedAt))
        }
        guard progress.libraryItemId == key.libraryItemId,
            (progress.episodeId ?? "") == (key.episodeId ?? ""),
            let lastUpdate = progress.lastUpdate
        else { return false }
        let baseline = ProgressBaseline(
            currentTime: progress.currentTime, progress: progress.progress, duration: progress.duration,
            isFinished: progress.isFinished,
            finishedAt: progress.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(lastUpdate) / 1000))
        let merged = try await store.applyServerProgress(
            [key: baseline], capturedAt: capturedAt, source: .fetch)
        return merged.contains(key)
    }

    /// Retry this exact local outcome before taking another PATCH. If the store released the
    /// token on rollback, its settlement returns false; the dirty row gets a fresh send instead.
    private func settle(_ patch: ProgressPatch, error: String?, rejected: Bool = false) async -> Bool {
        pendingSettlements[patch.key] = (patch, error, rejected)
        do {
            if let error, rejected {
                try await store.rejectSend(patch, error: error)
            } else if let error {
                try await store.failSend(patch, error: error)
            } else {
                try await store.completeSend(patch, serverLastUpdate: nil)
            }
            pendingSettlements[patch.key] = nil
            return true
        } catch {
            logger.error("Saving a progress outcome failed: \(String(describing: error), privacy: .public)")
            drainOutcome.failed = true
            return false
        }
    }

    /// The PATCH body for one group, or `nil` for a send with no group. `beginSend` returns
    /// exactly one group and sends a missing `ebookProgress` as 0; `lastUpdate` is never sent.
    static func update(for send: ProgressSend) -> MediaProgressUpdate? {
        if let audio = send.audio {
            return .audio(currentTime: audio.currentTime, duration: audio.duration, progress: audio.progress)
        }
        if let finished = send.finished {
            return .finished(finished.isFinished, at: finished.finishedAt)
        }
        guard let ebook = send.ebook else { return nil }
        return .ebook(location: ebook.ebookLocation, progress: ebook.ebookProgress ?? 0)
    }

    // MARK: Errors

    /// The request certainly didn't reach Audiobookshelf, or was rejected before the session was
    /// touched, so its listening time can be sent again: no host, no connection or no TLS
    /// handshake, a request refused before sending (roaming off, App Transport Security), a 401
    /// or 403, or a request that was never built or sent. Everything else is
    /// ambiguous, including `notConnectedToInternet`, `dataNotAllowed` and `callIsActive`, which
    /// can also end a request already sent.
    static func neverReachedServer(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .network(let code):
            [
                .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed,
                .internationalRoamingOff, .appTransportSecurityRequiresSecureConnection,
            ].contains(code)
        case .notAuthenticated, .sessionExpired, .unauthorized, .forbidden, .invalidURL, .encoding: true
        default: false
        }
    }

    /// A `/sync` the server turned away before its session handler ran (408 request timeout,
    /// 429 rate limit), so its listening time can be sent again.
    static func wasTurnedAway(_ error: any Error) -> Bool {
        if case .http(let status, _) = error as? APIError { [408, 429].contains(status) } else { false }
    }

    /// Later PATCHes would fail the same way, so the drain stops.
    static func isOffline(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .network, .timedOut, .notAuthenticated, .sessionExpired: true
        default: false
        }
    }

    /// A PATCH rejection that resending the same body would meet again: the item or episode is
    /// gone (404, 410) or the server refuses the body (400, 422). Only this list, so a
    /// misbehaving proxy can't quarantine rows with other statuses (409, 413, 401, 403, 408,
    /// 429 and 5xx stay retryable).
    static func isPermanent(_ error: any Error) -> Bool { permanentStatus(error) != nil }

    private static func permanentStatus(_ error: any Error) -> Int? {
        switch error as? APIError {
        case .notFound: 404
        case .http(let status, _) where [400, 404, 410, 422].contains(status): status
        default: nil
        }
    }

    /// The error's case without associated values (which can carry server messages), for logs.
    static func caseName(_ error: any Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
