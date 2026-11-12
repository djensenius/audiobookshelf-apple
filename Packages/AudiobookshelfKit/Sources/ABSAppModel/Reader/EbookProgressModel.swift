import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "Reader")

/// A reader's position and its sync (#101, ADR 0003 and ADR 0008), for one ebook of one account.
///
/// Ebook progress is local-authoritative while dirty, like the legacy readers: the store row
/// owns the position, and this model keeps no baseline or history of its own.
///
/// - **Local first.** ``record(_:progress:)`` saves every page turn to the store at once
///   (`LocalProgressStore.recordEbookEdit`: the ebook fields, `ebookDirty`, and `ebookEditedAt` as
///   the edit's identity). Saves run one at a time, in order; turns made while one runs are saved
///   together after it. Each turn reserves its order in the store when it is made, so a retried
///   older turn never replaces a newer one another reader of the same book saved meanwhile.
/// - **Debounced sending.** Only the PATCH waits for ``debounce`` without another turn. The model
///   never PATCHes itself: it drains through ``ProgressDraining`` (`ProgressSyncer`), which sends
///   one group per PATCH, acknowledges by edit identity, runs the confirmation GET and settles
///   permanent rejections. A failed PATCH leaves the row dirty, which survives a relaunch.
/// - **Server values.** The store never lets server progress override a dirty or in-flight ebook
///   group; a clean one takes it. Socket ebook values only prompt a fetch.
/// - **Resume.** ``resume()`` opens at the row's location. A dirty row is used as it is; a clean
///   or missing one is refreshed from the server first (`captureStartProgress`, then
///   `applyStartProgress`, which creates a clean row so an offline reopen finds it). Offline, the
///   persisted row, else the progress known at init. When a merge brought a location for another
///   format, the valid one it replaced is still offered.
/// - **Flush.** The reader container must call ``flush()`` when the reader closes and when the
///   app moves to the background: it sends at once. A model released with a save still queued
///   saves it in `deinit`, without sending; the next drain sends it.
/// - **Reconnect.** Dirty rows are the durable queue: `ProgressSyncer` drains them when the
///   network comes back and at launch; ``syncPending()`` drains on demand.
///
/// A drain runs on its own queue, after the saves before it, so a slow PATCH can't hold back a
/// later local save, and a drain doesn't keep the model alive.
@MainActor
@Observable
public final class EbookProgressModel {
    /// Quiet time after the last page turn before it is sent.
    public static let defaultDebounce: Duration = .seconds(2)

    public let key: MediaKey
    public let kind: ReaderKind
    /// The reader's current location: the latest page turn, or where ``resume()`` opened.
    public private(set) var location: EbookLocation?
    /// `0...1` with ``location``; `nil` when unknown.
    public private(set) var progress: Double?
    /// Whether the store holds an ebook change the server hasn't acknowledged, as of the last
    /// resume, save or drain.
    public private(set) var hasUnsyncedChanges = false
    /// The last failed local save until a save succeeds, else the row's last sync error after a
    /// drain.
    public private(set) var lastError: String?

    /// The waiting debounce before a drain. Readable for tests.
    @ObservationIgnored private(set) var debounceTask: Task<Void, Never>?
    /// The latest local save; the next save waits for it. Readable for tests.
    @ObservationIgnored private(set) var saveTail: Task<Bool, Never>?
    /// The latest drain; the next drain waits for it. Readable for tests.
    @ObservationIgnored private(set) var drainTail: Task<Void, Never>?
    /// The latest turn not yet saved, dated and ordered when it was recorded; kept after a failed
    /// save. The store drops it if another reader's later turn for the key was saved meanwhile.
    @ObservationIgnored private var unsaved: Unsaved?
    /// The last local save's failure; a drain finishing meanwhile doesn't hide it.
    @ObservationIgnored private var saveError: String?
    /// Counts updates of ``hasUnsyncedChanges`` from saves and drains, so ``resume()`` doesn't
    /// replace a newer one with the row it read before.
    @ObservationIgnored private var syncStateRevision = 0
    /// Server progress known for the media: seeds a new row (ADR 0003 seeding) and is the resume
    /// fallback without a row.
    @ObservationIgnored private var knownServerProgress: MediaProgress?
    @ObservationIgnored private let store: LocalProgressStore
    @ObservationIgnored private let service: any EbookProgressService
    @ObservationIgnored private let syncer: any ProgressDraining
    @ObservationIgnored private let localLibraryItemID: UUID?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - syncer: Sends saved rows: the account's `ProgressSyncer`, which must use `store`.
    ///   - localLibraryItemID: The downloaded item, if any, linked to the row on save.
    ///   - serverProgress: Progress already known (for example from `ProgressCache`), used when
    ///     ``resume()`` can't reach the server and there is no row.
    ///   - clock: Times the debounce; tests pass a manual clock.
    ///   - now: Dates local edits, when a page turn is recorded.
    public init(
        key: MediaKey, kind: ReaderKind, store: LocalProgressStore, service: any EbookProgressService,
        syncer: any ProgressDraining, localLibraryItemID: UUID? = nil, serverProgress: MediaProgress? = nil,
        debounce: Duration = defaultDebounce, clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.key = key
        self.kind = kind
        self.store = store
        self.service = service
        self.syncer = syncer
        self.localLibraryItemID = localLibraryItemID
        self.debounce = debounce
        self.clock = clock
        self.now = now
        knownServerProgress = serverProgress.flatMap { Self.matching($0, key) }
    }

    /// Saves a turn whose save hadn't run (or failed) locally; the syncer's next drain sends it.
    isolated deinit {
        debounceTask?.cancel()
        guard let pending = unsaved else { return }
        let (store, key, seed, itemID) = (store, key, knownServerProgress.flatMap(Self.baseline), localLibraryItemID)
        Task {
            do {
                try await store.recordEbookEdit(
                    pending.edit, for: key, token: pending.token, serverProgress: seed, localLibraryItemID: itemID,
                    now: pending.at)
            } catch {
                logger.error("Saving ebook progress on close failed: \(Self.caseName(error), privacy: .public)")
            }
        }
    }

    /// Where to open: the row's location (see the type's documentation). Sets ``location`` unless
    /// a page was already turned.
    @discardableResult
    public func resume() async -> EbookResumePoint {
        guard kind.isSupported else { return .beginning }
        // This reader's own turns reach the owner first.
        _ = await saveTail?.value
        let before = await readLocal()
        if before?.ebookDirty != true {
            await refresh()
        }
        let revision = syncStateRevision
        let local = await readLocal()
        let point = EbookResumePoint.resolve(
            kind: kind, local: local, replaced: before, server: local == nil ? knownServerProgress : nil)
        if location == nil {
            location = point.location
            progress = point.progress
        }
        if revision == syncStateRevision {
            hasUnsyncedChanges = local?.ebookDirty ?? false
        }
        return point
    }

    /// A page turn or relocation. Ignored when it isn't valid for ``kind`` or repeats the current
    /// location and progress; otherwise saved at once and sent after ``debounce`` without another
    /// one. A non-finite progress counts as unknown.
    public func record(_ location: EbookLocation, progress: Double?) {
        guard location.isValid(for: kind) else { return }
        let progress = EbookResumePoint.normalized(progress)
        guard location != self.location || progress != self.progress else { return }
        self.location = location
        self.progress = progress
        unsaved = Unsaved(
            edit: .init(location: location.stored, progress: progress), at: now(),
            token: store.reserveEbookEdit(for: key))
        enqueueSave()
        debounceTask?.cancel()
        let (clock, debounce) = (clock, debounce)
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            // A newer turn or a flush cancels this task, also while it waits for the save.
            guard let self, !Task.isCancelled else { return }
            // A failed save is retried first; the drain isn't awaited, so this task doesn't keep
            // the model.
            guard await enqueueSave().value, !Task.isCancelled else { return }
            enqueueDrain()
        }
    }

    /// Saves anything unsaved and sends at once. Call when the reader closes and when the app
    /// moves to the background; returns when done.
    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard await enqueueSave().value else { return }
        await enqueueDrain().value
    }

    /// Sends unsent changes without a new page turn: the reconnect hook. A turn whose save failed
    /// is saved first; nothing is sent while it can't be.
    public func syncPending() async {
        guard await enqueueSave().value else { return }
        await enqueueDrain().value
    }

    // MARK: - Private

    /// Merges the server's progress into a clean or missing row, as a playback start does. The
    /// store applies it only if the row didn't change since the capture, and never over a dirty
    /// or in-flight ebook group.
    private func refresh() async {
        do {
            let capture = try await store.captureStartProgress(for: key)
            let fetched = try await service.mediaProgress(itemID: key.libraryItemId, episodeID: key.episodeId)
            guard let fetched else {
                // The server has no progress: the known one is stale, to open at or to seed from,
                // and a socket's request to fetch the row is answered.
                knownServerProgress = nil
                await store.answerEbookFetch(captured: capture)
                return
            }
            guard let matching = Self.matching(fetched, key) else { return }
            knownServerProgress = matching
            try await store.applyStartProgress(matching, captured: capture)
        } catch {
            logger.info("Ebook progress unavailable: \(Self.caseName(error), privacy: .public)")
        }
    }

    /// The local row, or `nil` when there is none or it can't be read.
    private func readLocal() async -> LocalMediaProgressDTO? {
        do {
            return try await store.progress(for: key)
        } catch {
            logger.error("Reading local ebook progress failed: \(Self.caseName(error), privacy: .public)")
            return nil
        }
    }

    /// Queues ``save()`` behind the previous save only. Its value is whether to drain.
    @discardableResult
    private func enqueueSave() -> Task<Bool, Never> {
        let previous = saveTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            return await self?.save() ?? false
        }
        saveTail = task
        return task
    }

    /// Queues a drain behind the previous drain and the saves queued so far. It holds the model
    /// weakly, so a slow PATCH doesn't delay its `deinit`.
    @discardableResult
    private func enqueueDrain() -> Task<Void, Never> {
        let (previous, saves) = (drainTail, saveTail)
        let (syncer, store, key) = (syncer, store, key)
        let task = Task { @MainActor [weak self] in
            await previous?.value
            _ = await saves?.value
            await syncer.drainPendingProgress()
            let row: LocalMediaProgressDTO?
            do {
                row = try await store.progress(for: key)
            } catch {
                logger.error("Reading local ebook progress failed: \(Self.caseName(error), privacy: .public)")
                return
            }
            guard let self else { return }
            syncStateRevision += 1
            hasUnsyncedChanges = row?.ebookDirty ?? false
            lastError = saveError ?? row?.lastSyncError
        }
        drainTail = task
        return task
    }

    /// Saves the latest unsaved turn. Returns `false` when the save failed, so nothing is sent;
    /// the turn is kept for the next save, unless a newer one replaced it.
    private func save() async -> Bool {
        guard let pending = unsaved else { return true }
        unsaved = nil
        do {
            let row = try await store.recordEbookEdit(
                pending.edit, for: key, token: pending.token,
                serverProgress: knownServerProgress.flatMap(Self.baseline),
                localLibraryItemID: localLibraryItemID, now: pending.at)
            // `nil`: a later turn for the key, from another reader, is saved; it stays.
            if let row {
                syncStateRevision += 1
                hasUnsyncedChanges = row.ebookDirty
            }
            saveError = nil
            return true
        } catch {
            if unsaved == nil { unsaved = pending }
            saveError = Self.caseName(error)
            lastError = saveError
            logger.error("Saving ebook progress failed: \(Self.caseName(error), privacy: .public)")
            return false
        }
    }

    private struct Unsaved {
        let edit: ProgressEdit.Ebook
        let at: Date
        let token: EbookEditToken
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
