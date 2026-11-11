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
///   coordinator's `/close` doesn't go through this queue yet, so it can overlap a report in
///   flight (#158).
/// - **Positions first.** Each report trigger saves `LocalMediaProgress` with `needsServerSync`
///   before sending. Local writes have their own serial queue, so a held request doesn't block
///   saving a newer seek or pause. Failed writes stay in memory for the next trigger or drain;
///   no report is sent while a position still needs saving.
///   Final positions enter that queue synchronously in the close callback, even for clean or
///   missing rows. Their throwing receipts acknowledge only committed audio, not listening time.
/// - **Failures.** The position stays in the durable retry queue. Listening time is carried into the next
///   report only when the request clearly never reached the server (DNS, connect, TLS, auth);
///   after an ambiguous failure it is dropped, so it is never counted twice.
/// - **Durable queue.** ``drainPendingProgress()`` PATCHes the connection's dirty rows, one group
///   per request from `LocalProgressStore.beginSend`, in its order (audio, finished, ebook). It
///   runs after every successful `/sync` and on ``flush()``; call it on reconnect and at launch.
///   A successful `/sync` still drains the saved position through PATCH: only the store's PATCH
///   acknowledgement clears the dirty group, without clearing a newer edit. Clean rows are kept.
///   Failed settlements retain their token and outcome for the next drain.
@MainActor
public final class ProgressSyncer {
    /// Seconds between reports while playing (legacy `TIME_BETWEEN_SESSION_SYNC_IN_SECONDS`).
    public static let syncInterval: TimeInterval = 15
    /// PATCHes per row in one drain: each group once, plus re-sends of groups edited meanwhile.
    static let maxSendsPerRow = 6

    private struct Position: Equatable {
        let revision: UInt64
        let token: PlaybackPositionToken
        let time: Double
        let duration: Double
        let editedAt: Date
    }

    private struct CurrentSession {
        let sessionID: String
        let key: MediaKey
        /// `sessionStarted` precedes position resolution; only `loaded` makes the position reportable.
        var hasLoaded = false
        /// Listening time not yet handed to a report.
        var listened: TimeInterval = 0
        /// The latest report trigger, persisted independently of transport.
        var position: Position?
    }

    private weak var source: (any PlaybackProgressSource)?
    private let service: any ProgressSyncService
    private let store: LocalProgressStore
    private let clock: ProgressSyncClock
    private let tickInterval: TimeInterval
    private var observer: PlaybackObserverToken?

    private var current: CurrentSession?
    private var isPlaying = false
    private var lastTick: (uptime: TimeInterval, mediaTime: Double)?
    private var lastSyncAt: TimeInterval?
    private var chapterIndex: Int?
    /// The `didSeek` the coordinator emits right after `loaded` is the resume position, not a seek.
    private var loadedTime: Double?
    /// The session with a `/sync` queued but not started; later requests join it.
    private var queuedSyncSessionID: String?
    private var tail: Task<Void, Never>?
    private var persistenceTail: Task<Void, Never>?
    /// Test seam: hold local persistence independently of transport.
    var beforePositionPersistence: (@MainActor () async -> Void)?
    /// Test seam at the capture-to-evidence boundary; no transport has been issued here.
    var beforeSessionAudioPreparation: (@MainActor () async -> Void)?
    private var pendingPositions: [MediaKey: Position] = [:]
    private var positionRevision: UInt64 = 0
    private var positionReceipts: [MediaKey: [(revision: UInt64, receipt: PlaybackCloseResult<Void>)]] = [:]
    private var transportTasks: [UUID: Task<Void, Never>] = [:]
    private var isTransportQuiesced = false
    /// `nil` error means success; neither outcome may be forgotten if the store throws.
    private var pendingSettlements: [MediaKey: (patch: ProgressPatch, error: String?)] = [:]
    /// Set by ``detach()``: queued requests are skipped; issued calls are canceled best-effort.
    private var isDetached = false

    /// Starts following `source`: observes its events and supplies its `finalCloseReport`.
    /// - Parameter store: Reuse the same writer across account-scope lifetimes. Independent
    ///   writers over the same database do not share in-process playback-position ordering.
    /// - Parameter tickInterval: The engine's time-update interval (`AudioEngine`'s
    ///   `timeObserverInterval`).
    public init(
        source: any PlaybackProgressSource, service: any ProgressSyncService, store: LocalProgressStore,
        clock: ProgressSyncClock = .live, tickInterval: TimeInterval = 0.5
    ) {
        self.source = source
        self.service = service
        self.store = store
        self.clock = clock
        self.tickInterval = tickInterval
        observer = source.addObserver { [weak self] event in self?.handle(event) }
        source.finalCloseReport = { [weak self] closing in self?.closeReport(for: closing) }
        source.quiesceProgressTransport = { [weak self] in self?.quiesceTransport() }
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
        for task in transportTasks.values { task.cancel() }
    }

    // MARK: Commands

    /// Reports the current session now and drains the durable queue; returns when both are done.
    /// Call when the app moves to the background.
    public func flush() async {
        if current != nil {
            creditPlayedTime()
            requestSync()
        }
        await drainPendingProgress()
    }

    /// PATCHes the connection's progress rows marked `needsServerSync`; returns when done. Call on
    /// launch and when the network comes back.
    public func drainPendingProgress() async {
        enqueue { [weak self] in await self?.drain() }
        await waitForIdle()
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
            if current?.sessionID == closing.sessionID { current = nil }
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
            current = nil
        }
        guard
            let report = PlaybackSyncReport(
                currentTime: closing.currentTime, timeListened: listened, duration: closing.duration),
            let position = queuePosition(closing.key, time: closing.currentTime, duration: closing.duration)
        else { return nil }
        let receipt = PlaybackCloseResult<Void>()
        positionReceipts[closing.key, default: []].append((position.revision, receipt))
        return PlaybackCloseHandoff(report: report, position: receipt)
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

    private func requestSync() {
        guard !isDetached, !isTransportQuiesced, let session = current, let source,
            session.hasLoaded,
            let position = queuePosition(session.key, time: source.currentTime, duration: source.duration)
        else { return }
        current?.position = position
        let sessionID = session.sessionID
        lastSyncAt = clock.uptime()
        guard queuedSyncSessionID != sessionID else { return }
        queuedSyncSessionID = sessionID
        enqueue { [weak self] in await self?.sendSync(sessionID: sessionID) }
    }

    /// Sends the latest saved trigger for `sessionID`, if it is still current.
    private func sendSync(sessionID: String) async {
        await waitForPendingWrites()
        if queuedSyncSessionID == sessionID { queuedSyncSessionID = nil }
        guard await settleSessionAudioOutcomes() else { return }
        guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty,
            let session = current, session.sessionID == sessionID,
            let position = session.position
        else { return }
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
        current?.listened -= listened
        let outcome: SessionAudioOutcome
        do {
            try await service.syncSession(id: sessionID, report: report)
            outcome = .succeeded
        } catch {
            if Self.neverReachedServer(error) {
                outcome = .notDelivered
                if current?.sessionID == sessionID {
                    current?.listened += listened
                } else if listened > 0 {
                    // TODO(#158): carry it into the closed session's reconciliation.
                    logger.info(
                        "Dropped \(listened, privacy: .public) s of listening time: the session closed before it could be resent"
                    )
                }
            } else {
                outcome = .ambiguous
                if listened > 0 {
                    logger.info(
                        "Dropped \(listened, privacy: .public) s of listening time after an ambiguous sync failure (\(Self.caseName(error), privacy: .public))"
                    )
                }
            }
            await settleSessionAudio(evidence, outcome: outcome)
            return
        }
        guard await settleSessionAudio(evidence, outcome: outcome) else { return }
        await drain()
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
                    finishReceipts(for: key, through: position.revision, result: .success(()))
                } catch {
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

    private func drain() async {
        guard await settleSessionAudioOutcomes() else { return }
        guard !isDetached, !isTransportQuiesced else { return }
        queuePersistence()
        await waitForPendingWrites()
        guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
        for outcome in Array(pendingSettlements.values) {
            guard await settle(outcome.patch, error: outcome.error) else { return }
        }
        let rows: [LocalMediaProgressDTO]
        do {
            rows = try await store.pendingSync(for: service.serverConnectionID)
        } catch {
            logger.error("Reading pending progress failed: \(String(describing: error), privacy: .public)")
            return
        }
        for row in rows {
            for _ in 0..<Self.maxSendsPerRow {
                await waitForPendingWrites()
                guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return }
                let patch: ProgressPatch?
                do {
                    patch = try await store.beginSend(for: row.key, now: clock.now())
                } catch {
                    logger.error("Starting a progress send failed: \(String(describing: error), privacy: .public)")
                    break
                }
                guard let patch else { break }
                guard !isDetached, !isTransportQuiesced else {
                    _ = await settle(patch, error: "accountEnded")
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
                    guard await settle(patch, error: Self.caseName(error)) else { return }
                    if Self.isOffline(error) { return }
                    break
                }
                guard await settle(patch, error: nil) else { return }
            }
        }
    }

    /// Retry this exact local outcome before taking another PATCH. If the store released the
    /// token on rollback, its settlement returns false; the dirty row gets a fresh send instead.
    private func settle(_ patch: ProgressPatch, error: String?) async -> Bool {
        pendingSettlements[patch.key] = (patch, error)
        do {
            if let error {
                try await store.failSend(patch, error: error)
            } else {
                try await store.completeSend(patch, serverLastUpdate: nil)
            }
            pendingSettlements[patch.key] = nil
            return true
        } catch {
            logger.error("Saving a progress outcome failed: \(String(describing: error), privacy: .public)")
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

    /// Later PATCHes would fail the same way, so the drain stops.
    private static func isOffline(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .network, .timedOut, .notAuthenticated, .sessionExpired: true
        default: false
        }
    }

    /// The error's case without associated values (which can carry server messages), for logs.
    private static func caseName(_ error: any Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
