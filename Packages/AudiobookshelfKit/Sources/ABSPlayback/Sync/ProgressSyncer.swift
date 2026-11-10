import ABSAPI
import ABSCore
import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "ProgressSyncer")

/// Keeps listening progress from being lost (#53; ADR 0003 "Write throttling", ADR 0007 point 8).
///
/// - **Cadence.** A streamed session reports `POST /api/session/:id/sync` every ``syncInterval``
///   while playing, and at once on pause, seek, chapter change, the end and ``flush()`` (call it
///   when the app moves to the background). The session's last report goes with the
///   coordinator's `/close` through `finalCloseReport`.
/// - **Listening time** is wall-clock time while playing, independent of rate (ADR 0007). A tick
///   credits the monotonic time since the previous tick only while playing and only if media time
///   advanced; a gap longer than two tick intervals credits one interval. Seeks add nothing.
/// - **One request at a time.** Every send and store write runs on one serial queue, and a send
///   counts as finished only when the service call returns, after its task has completed. So no
///   report or PATCH goes out while an earlier one could still reach the server.
/// - **Failures.** A failed `/sync` writes the position to `LocalMediaProgress`
///   (`needsServerSync`), the durable retry queue. Its listening time is carried into the next
///   report only when the request clearly never reached the server (offline, DNS, connect, auth);
///   after an ambiguous failure it is dropped, so it is never counted twice.
/// - **Durable queue.** ``drainPendingProgress()`` PATCHes the connection's dirty rows, one group
///   per request from `LocalProgressStore.beginSend`, in its order (audio, finished, ebook). It
///   runs after every successful `/sync` and on ``flush()``; call it on reconnect and at launch.
///   While a row is pending, every report also updates it, so the PATCH never sends an older
///   position than the session's.
@MainActor
public final class ProgressSyncer {
    /// Seconds between reports while playing (legacy `TIME_BETWEEN_SESSION_SYNC_IN_SECONDS`).
    public static let syncInterval: TimeInterval = 15
    /// PATCHes per row in one drain: each group once, plus re-sends of groups edited meanwhile.
    static let maxSendsPerRow = 6

    private struct CurrentSession {
        let sessionID: String
        let key: MediaKey
        /// Listening time not yet handed to a report.
        var listened: TimeInterval = 0
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

    /// Starts following `source`: observes its events and supplies its `finalCloseReport`.
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
    }

    /// Stops following the source.
    public func detach() {
        if let observer { source?.removeObserver(observer) }
        observer = nil
        source?.finalCloseReport = nil
        source = nil
        current = nil
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
        while let task = tail {
            await task.value
            if tail == task {
                tail = nil
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
            loadedTime = time
            lastSyncAt = now
            chapterIndex = source?.chapterIndex
        case .playbackStarted:
            isPlaying = true
            lastSyncAt = now
            lastTick = source.map { (now, $0.currentTime) }
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
            if closing.wasLoaded {
                enqueue { [weak self] in
                    await self?.updatePendingRow(closing.key, time: closing.currentTime, duration: closing.duration)
                }
            }
        case .itemChanged, .failed:
            break
        }
    }

    private func tick(_ time: Double, now: TimeInterval) {
        guard current != nil else { return }
        let playing = isPlaying && source?.isPlaying == true
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
    private func closeReport(for closing: ClosingSession) -> PlaybackSyncReport? {
        var listened: TimeInterval = 0
        if current?.sessionID == closing.sessionID {
            creditPlayedTime()
            listened = current?.listened ?? 0
            current = nil
        }
        return PlaybackSyncReport(currentTime: closing.currentTime, timeListened: listened, duration: closing.duration)
    }

    /// Credits the time since the last tick, when playing (a pause, the end, a flush or a close).
    private func creditPlayedTime() {
        let now = clock.uptime()
        guard isPlaying, let last = lastTick else { return }
        current?.listened += credit(for: now - last.uptime)
        lastTick = (now, source?.currentTime ?? last.mediaTime)
    }

    private func credit(for gap: TimeInterval) -> TimeInterval {
        guard gap.isFinite, gap > 0 else { return 0 }
        return gap > 2 * tickInterval ? tickInterval : gap
    }

    // MARK: Queue

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    private func requestSync() {
        guard let sessionID = current?.sessionID else { return }
        lastSyncAt = clock.uptime()
        guard queuedSyncSessionID != sessionID else { return }
        queuedSyncSessionID = sessionID
        enqueue { [weak self] in await self?.sendSync(sessionID: sessionID) }
    }

    /// Sends one report for `sessionID` if it is still current. The snapshot (position, duration
    /// and listening time) is taken now, when the previous request has finished.
    private func sendSync(sessionID: String) async {
        if queuedSyncSessionID == sessionID { queuedSyncSessionID = nil }
        guard let session = current, session.sessionID == sessionID, let source else { return }
        let time = source.currentTime
        let duration = source.duration
        let listened = session.listened
        guard let report = PlaybackSyncReport(currentTime: time, timeListened: listened, duration: duration) else {
            return
        }
        current?.listened = 0
        do {
            try await service.syncSession(id: sessionID, report: report)
        } catch {
            if Self.neverReachedServer(error) {
                if current?.sessionID == sessionID { current?.listened += listened }
            } else if listened > 0 {
                logger.info(
                    "Dropped \(listened, privacy: .public) s of listening time after an ambiguous sync failure (\(Self.caseName(error), privacy: .public))"
                )
            }
            await record(session.key, time: time, duration: duration)
            return
        }
        await updatePendingRow(session.key, time: time, duration: duration)
        await drain()
    }

    /// Records the position into the media's row if it is waiting for a PATCH, so the PATCH
    /// never sends an older position.
    private func updatePendingRow(_ key: MediaKey, time: Double, duration: Double) async {
        guard (try? await store.progress(for: key))?.needsServerSync == true else { return }
        await record(key, time: time, duration: duration)
    }

    private func record(_ key: MediaKey, time: Double, duration: Double) async {
        guard time.isFinite, time >= 0 else { return }
        let duration = duration.isFinite && duration > 0 ? duration : 0
        let progress = duration > 0 ? min(time / duration, 1) : 0
        do {
            try await store.recordEdit(
                ProgressEdit(audio: .init(currentTime: time, duration: duration, progress: progress)), for: key,
                now: clock.now())
        } catch {
            logger.error("Saving progress for a later sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Durable queue

    private func drain() async {
        let rows: [LocalMediaProgressDTO]
        do {
            rows = try await store.pendingSync(for: service.serverConnectionID)
        } catch {
            logger.error("Reading pending progress failed: \(String(describing: error), privacy: .public)")
            return
        }
        for row in rows {
            for _ in 0..<Self.maxSendsPerRow {
                let patch: ProgressPatch?
                do {
                    patch = try await store.beginSend(for: row.key, now: clock.now())
                } catch {
                    logger.error("Starting a progress send failed: \(String(describing: error), privacy: .public)")
                    break
                }
                guard let patch else { break }
                do {
                    try await service.updateProgress(
                        itemID: row.key.libraryItemId, episodeID: row.key.episodeId, Self.update(for: patch.values))
                } catch {
                    _ = try? await store.failSend(patch, error: Self.caseName(error))
                    if Self.isOffline(error) { return }
                    break
                }
                do {
                    try await store.completeSend(patch, serverLastUpdate: nil)
                } catch {
                    logger.error(
                        "Saving a progress acknowledgement failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// The PATCH body for one group. `beginSend` returns exactly one group and sends a missing
    /// `ebookProgress` as 0; `lastUpdate` is never sent.
    static func update(for send: ProgressSend) -> MediaProgressUpdate {
        if let audio = send.audio {
            return .audio(currentTime: audio.currentTime, duration: audio.duration, progress: audio.progress)
        }
        if let finished = send.finished {
            return .finished(finished.isFinished, at: finished.finishedAt)
        }
        let ebook = send.ebook
        return .ebook(location: ebook?.ebookLocation, progress: ebook?.ebookProgress ?? 0)
    }

    // MARK: Errors

    /// The request certainly didn't reach Audiobookshelf, or was rejected before the session was
    /// touched, so its listening time can be sent again.
    static func neverReachedServer(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .network(let code):
            [
                .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
                .appTransportSecurityRequiresSecureConnection,
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
