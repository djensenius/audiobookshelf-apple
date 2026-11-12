import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "Reader")

/// A reader's position and its sync (#101, ADR 0003 and ADR 0008), for one ebook of one account.
///
/// - **Resume.** ``resume()`` reads the server's progress and the local row and opens at the
///   newer valid location (``EbookResumePoint/resolve(kind:local:server:)``).
/// - **Local first, debounced.** ``record(_:progress:)`` takes every page turn at once (for
///   ``location``) but saves it only after ``debounce`` without another turn (ADR 0003: ebook
///   location changes are debounced before they reach the store). Each save goes to
///   `LocalProgressStore.recordEdit` first and only then, once it is committed, to the server, so
///   several quick turns make one local write and one PATCH.
/// - **PATCH.** Sends go through the store's `beginSend`, `completeSend` and `failSend`, like
///   `ProgressSyncer`'s drain, so the row's ADR 0003 bookkeeping (one group per PATCH, audio and
///   finished before ebook, at most one PATCH in flight) holds. A failed PATCH leaves the ebook
///   group dirty in the store (`needsServerSync`), which survives a relaunch.
/// - **Flush.** Call ``flush()`` when the reader closes and when the app moves to the
///   background: it saves a waiting turn at once and sends it.
/// - **Reconnect.** Dirty rows are the durable queue. `ProgressSyncer.drainPendingProgress()`
///   already PATCHes every dirty row of the connection, ebook groups included, when the network
///   comes back and at launch; ``syncPending()`` sends this book's row on demand (for example when
///   the reader is open as the network returns).
///
/// Saves and sends run one at a time, in order.
@MainActor
@Observable
public final class EbookProgressModel {
    /// Quiet time after the last page turn before it is saved and sent.
    public static let defaultDebounce: Duration = .seconds(2)
    /// PATCHes per save. The store hands out one dirty group per PATCH, audio and finished before
    /// ebook, so the ebook group can need up to three.
    static let maxSendsPerSave = 3

    public let key: MediaKey
    public let kind: ReaderKind
    /// The reader's current location: the latest page turn, or where ``resume()`` opened.
    public private(set) var location: EbookLocation?
    /// `0...1` with ``location``; `nil` when unknown.
    public private(set) var progress: Double?
    /// Whether the store holds an ebook change the server hasn't acknowledged, as of the last save
    /// or send. A page turn still waiting for the debounce isn't counted.
    public private(set) var hasUnsyncedChanges = false
    /// The last failed save or send, cleared by the next successful send.
    public private(set) var lastError: String?

    /// The waiting debounce. Readable for tests.
    @ObservationIgnored private(set) var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var unsaved: (location: EbookLocation, progress: Double?)?
    /// Server progress known for the media, to seed a new row (ADR 0003 seeding).
    @ObservationIgnored private var serverSeed: ProgressBaseline?
    @ObservationIgnored private var knownServerProgress: MediaProgress?
    @ObservationIgnored private let store: LocalProgressStore
    @ObservationIgnored private let service: any EbookProgressService
    @ObservationIgnored private let localLibraryItemID: UUID?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - localLibraryItemID: The downloaded item, if any, linked to the row on save.
    ///   - serverProgress: Progress already known (for example from `ProgressCache`), used when
    ///     ``resume()`` can't reach the server.
    ///   - clock: Times the debounce; tests pass a manual clock.
    ///   - now: Dates local edits.
    public init(
        key: MediaKey, kind: ReaderKind, store: LocalProgressStore, service: any EbookProgressService,
        localLibraryItemID: UUID? = nil, serverProgress: MediaProgress? = nil, debounce: Duration = defaultDebounce,
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.key = key
        self.kind = kind
        self.store = store
        self.service = service
        self.localLibraryItemID = localLibraryItemID
        self.debounce = debounce
        self.clock = clock
        self.now = now
        knownServerProgress = serverProgress.flatMap { Self.matching($0, key) }
        serverSeed = knownServerProgress.flatMap(Self.baseline)
    }

    isolated deinit {
        debounceTask?.cancel()
    }

    /// Where to open: the newer of the local and the server location, or the start. Sets
    /// ``location`` unless a page was already turned.
    @discardableResult
    public func resume() async -> EbookResumePoint {
        guard kind.isSupported else { return .beginning }
        do {
            if let fetched = try await service.mediaProgress(itemID: key.libraryItemId, episodeID: key.episodeId) {
                knownServerProgress = Self.matching(fetched, key)
            }
        } catch {
            logger.info("Ebook progress unavailable: \(Self.caseName(error), privacy: .public)")
        }
        serverSeed = knownServerProgress.flatMap(Self.baseline) ?? serverSeed
        var local: LocalMediaProgressDTO?
        do {
            local = try await store.progress(for: key)
        } catch {
            logger.error("Reading local ebook progress failed: \(Self.caseName(error), privacy: .public)")
        }
        let point = EbookResumePoint.resolve(kind: kind, local: local, server: knownServerProgress)
        if location == nil {
            location = point.location
            progress = point.progress
        }
        hasUnsyncedChanges = local?.ebookDirty ?? false
        return point
    }

    /// A page turn or relocation. Ignored when it isn't valid for ``kind`` or repeats the current
    /// location and progress; otherwise saved and sent after ``debounce`` without another one.
    public func record(_ location: EbookLocation, progress: Double?) {
        guard location.isValid(for: kind) else { return }
        let progress = progress.map { min(max($0, 0), 1) }
        guard location != self.location || progress != self.progress else { return }
        self.location = location
        self.progress = progress
        unsaved = (location, progress)
        debounceTask?.cancel()
        let (clock, debounce) = (clock, debounce)
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            // A newer turn cancels this task before replacing it.
            guard let self, !Task.isCancelled else { return }
            debounceTask = nil
            await enqueue { [weak self] in await self?.save() }
        }
    }

    /// Saves a waiting page turn at once and sends it. Call when the reader closes and when the
    /// app moves to the background; returns when done.
    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await enqueue { [weak self] in await self?.save() }
    }

    /// Sends this book's unsent ebook change, if any, without a new page turn: the reconnect hook.
    public func syncPending() async {
        await enqueue { [weak self] in await self?.send() }
    }

    // MARK: - Private

    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    /// Saves the waiting turn locally, then sends. A failed local save sends nothing and keeps
    /// the turn for the next save, unless a newer one replaced it.
    private func save() async {
        if let pending = unsaved {
            unsaved = nil
            let edit = ProgressEdit(ebook: .init(location: pending.location.stored, progress: pending.progress))
            do {
                let row = try await store.recordEdit(
                    edit, for: key, serverProgress: serverSeed, localLibraryItemID: localLibraryItemID, now: now())
                hasUnsyncedChanges = row.ebookDirty
            } catch {
                if unsaved == nil { unsaved = pending }
                lastError = Self.caseName(error)
                logger.error("Saving ebook progress failed: \(Self.caseName(error), privacy: .public)")
                return
            }
        }
        await send()
    }

    /// PATCHes the row's dirty groups in the store's order until the ebook group was sent, a send
    /// fails, or nothing is left. Another sender (`ProgressSyncer`) holding the row's send makes
    /// `beginSend` return `nil`; it sends the change instead.
    private func send() async {
        for _ in 0..<Self.maxSendsPerSave {
            let patch: ProgressPatch?
            do {
                patch = try await store.beginSend(for: key, now: now())
            } catch {
                lastError = Self.caseName(error)
                logger.error("Starting an ebook progress send failed: \(Self.caseName(error), privacy: .public)")
                break
            }
            guard let patch else { break }
            var failure: String?
            if let update = Self.update(for: patch.values) {
                do {
                    try await service.writeProgress(
                        itemID: key.libraryItemId, episodeID: key.episodeId, update: update)
                } catch {
                    failure = Self.caseName(error)
                }
            } else {
                failure = "emptySend"
            }
            do {
                if let failure {
                    try await store.failSend(patch, error: failure)
                } else {
                    try await store.completeSend(patch, serverLastUpdate: nil)
                }
            } catch {
                // The store keeps the outcome and retries it on the next `beginSend`.
                failure = failure ?? Self.caseName(error)
                logger.error("Saving an ebook progress outcome failed: \(Self.caseName(error), privacy: .public)")
            }
            if let failure {
                lastError = failure
                break
            }
            lastError = nil
            if patch.values.groups == .ebook { break }
        }
        if let row = try? await store.progress(for: key) {
            hasUnsyncedChanges = row.ebookDirty
        }
    }

    /// The PATCH body for one group; `nil` for a send with no group.
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

    private static func matching(_ progress: MediaProgress, _ key: MediaKey) -> MediaProgress? {
        progress.libraryItemId == key.libraryItemId && (progress.episodeId ?? "") == (key.episodeId ?? "")
            ? progress : nil
    }

    /// Dated server progress as a seed; `nil` when undated.
    private static func baseline(_ progress: MediaProgress) -> ProgressBaseline? {
        guard let lastUpdate = progress.lastUpdate else { return nil }
        return ProgressBaseline(
            currentTime: progress.currentTime, progress: progress.progress, duration: progress.duration,
            isFinished: progress.isFinished,
            finishedAt: progress.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(lastUpdate) / 1000))
    }

    private static func caseName(_ error: any Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
