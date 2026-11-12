import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "Reader")

/// A reader's position and its sync (#101, ADR 0003 and ADR 0008), for one ebook of one account.
///
/// - **Resume.** ``resume()`` fetches the server's progress and merges it into the local row
///   like a playback start (`captureStartProgress`, then `applyStartProgress`, which creates a
///   clean row when there is none, so an offline reopen finds the position). A newer location
///   from another device thus replaces an older unsent one instead of being PATCHed over later.
///   A turn still waiting is saved before the merge, so it is dated against the server's value
///   rather than taken as newer. It then opens at the newer valid location
///   (``EbookResumePoint/resolve(kind:local:server:)``); a fetched value the store didn't take
///   can't win a tie with the row, and one the store did take is decided by the row: a location
///   the store kept (a newer unsent turn, or one whose PATCH is in flight) isn't reselected by the
///   server's date. If the merge replaced a valid local location with one this reader can't open,
///   the replaced location is still offered.
/// - **Local first, debounced.** ``record(_:progress:)`` takes every page turn at once (for
///   ``location``) but saves it only after ``debounce`` without another turn (ADR 0003: ebook
///   location changes are debounced before they reach the store). Each save goes to
///   `LocalProgressStore.recordEdit` first and only then, once it is committed, to the syncer, so
///   several quick turns make one local write and one PATCH. A turn is dated when it is
///   recorded; if, before it is saved, a merge took a server location dated after it (another
///   device's newer page), the turn is dropped rather than PATCHed over that page
///   (`LocalProgressStore.recordEbookTurn`). ``location`` still shows it until the next turn.
/// - **Sending.** The model never PATCHes itself: it hands the saved row to ``ProgressDraining``
///   (`ProgressSyncer.drainPendingProgress()`), which fetches and merges the server's progress
///   before each PATCH (so an older dirty group doesn't overwrite a newer server value), sends
///   one group per PATCH, runs the confirmation lookup after it, and settles permanent rejections
///   (400, 404, 410, 422) with `rejectSend`. A failed PATCH leaves the ebook group dirty in the
///   store (`needsServerSync`), which survives a relaunch.
/// - **Flush.** The reader container must call ``flush()`` when the reader closes and when the
///   app moves to the background: it saves a waiting turn at once and sends it. A model released
///   with a turn still waiting saves it locally in `deinit`, without sending; the next drain sends
///   it.
/// - **Reconnect.** Dirty rows are the durable queue: `ProgressSyncer` drains them when the
///   network comes back and at launch; ``syncPending()`` drains on demand.
///
/// Local saves run one at a time, in order, and never wait for the network: a save's drain runs
/// on its own queue, after the saves before it, one drain at a time. A slow PATCH therefore
/// can't hold back a later page turn's local save, and a drain doesn't keep the model alive.
@MainActor
@Observable
public final class EbookProgressModel {
    /// Quiet time after the last page turn before it is saved and sent.
    public static let defaultDebounce: Duration = .seconds(2)

    public let key: MediaKey
    public let kind: ReaderKind
    /// The reader's current location: the latest page turn, or where ``resume()`` opened.
    public private(set) var location: EbookLocation?
    /// `0...1` with ``location``; `nil` when unknown.
    public private(set) var progress: Double?
    /// Whether the store holds an ebook change the server hasn't acknowledged, as of the last
    /// resume, save or drain. A page turn still waiting for the debounce isn't counted.
    public private(set) var hasUnsyncedChanges = false
    /// The last failed local save until a save succeeds, else the row's last sync error after a
    /// drain.
    public private(set) var lastError: String?

    /// The waiting debounce. Readable for tests.
    @ObservationIgnored private(set) var debounceTask: Task<Void, Never>?
    /// The latest local save; the next save waits for it.
    @ObservationIgnored private var saveTail: Task<Bool, Never>?
    /// The latest drain; the next drain waits for it. Readable for tests.
    @ObservationIgnored private(set) var drainTail: Task<Void, Never>?
    /// The waiting turn, dated and ordered when it was recorded so a delayed or retried save keeps
    /// its age and its place.
    @ObservationIgnored private var unsaved:
        (
            location: EbookLocation, progress: Double?, at: Date, intent: EbookTurnIntent,
            knownPositions: [EbookPosition]?
        )?
    /// The server ebook positions accounted for: the row's baseline, unsent and in-flight values
    /// as last read, and the values saved since. A turn takes a copy; `nil` before the first read.
    @ObservationIgnored private var knownPositions: [EbookPosition]?
    /// Awaited by a save after it took the waiting turn, before writing it. Settable for tests,
    /// to turn a page during a local save.
    @ObservationIgnored var willSave: (@MainActor () async -> Void)?
    /// The last local save's failure; a drain finishing meanwhile doesn't hide it.
    @ObservationIgnored private var saveError: String?
    /// Counts updates of ``hasUnsyncedChanges`` from saves and drains, so ``resume()`` doesn't
    /// replace a newer one with the row it read before.
    @ObservationIgnored private var syncStateRevision = 0
    /// Server progress known for the media, to seed a new row (ADR 0003 seeding).
    @ObservationIgnored private var serverSeed: ProgressBaseline?
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
    ///     ``resume()`` can't reach the server.
    ///   - clock: Times the debounce; tests pass a manual clock.
    ///   - now: Dates local edits, when a page turn is recorded rather than when it is saved.
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
        serverSeed = knownServerProgress.flatMap(Self.baseline)
    }

    /// Saves a turn still waiting for the debounce locally, so closing without ``flush()``
    /// doesn't lose it; the syncer's next drain sends it.
    isolated deinit {
        debounceTask?.cancel()
        guard let pending = unsaved else { return }
        let (store, key, seed, itemID) = (store, key, serverSeed, localLibraryItemID)
        let ebook = ProgressEdit.Ebook(location: pending.location.stored, progress: pending.progress)
        Task {
            do {
                try await store.recordEbookTurn(
                    ebook, for: key, intent: pending.intent, knownPositions: pending.knownPositions,
                    serverProgress: seed, localLibraryItemID: itemID, now: pending.at)
            } catch {
                logger.error("Saving ebook progress on close failed: \(Self.caseName(error), privacy: .public)")
            }
        }
    }

    /// Where to open: the newer of the local and the server location, or the start. Sets
    /// ``location`` unless a page was already turned.
    @discardableResult
    public func resume() async -> EbookResumePoint {
        guard kind.isSupported else { return .beginning }
        let capture: PlaybackStartProgressCapture?
        do {
            capture = try await store.captureStartProgress(for: key)
        } catch {
            capture = nil
            logger.error("Reading local ebook progress failed: \(Self.caseName(error), privacy: .public)")
        }
        // The merge below may replace a valid local location with one this reader can't open.
        let beforeMerge = await readLocal()
        // A fetched value the store didn't take (the row changed since the capture) is no newer
        // than the row: it can't win a tie with it.
        var unmerged: MediaProgress?
        var merged = false
        do {
            let fetched = try await service.mediaProgress(itemID: key.libraryItemId, episodeID: key.episodeId)
            // A turn not yet saved would be judged against the fetched baseline as if it were newer:
            // save it first. The store then sees the row changed since the capture and leaves the
            // merge to the next drain, which dates both. A turn that can't be saved keeps the old
            // seed and baseline.
            let saved = await enqueueSave().value
            if fetched == nil {
                // The server has no progress: the known one is stale, to open at or to seed from.
                knownServerProgress = nil
                serverSeed = nil
            } else if let matching = fetched.flatMap({ Self.matching($0, key) }) {
                knownServerProgress = matching
                unmerged = matching
                if saved {
                    serverSeed = Self.baseline(matching) ?? serverSeed
                    // Creates a clean row when there is none, so an offline reopen finds it.
                    if let capture, try await store.applyStartProgress(matching, captured: capture) {
                        unmerged = nil
                        merged = true
                    }
                }
            }
        } catch {
            logger.info("Ebook progress unavailable: \(Self.caseName(error), privacy: .public)")
        }
        let revision = syncStateRevision
        let local = await readLocal()
        noteRead(local)
        // Every group stays merged, but when the merge brought an ebook location this reader can't
        // open (another format's CFI or page), the valid one it replaced is still a candidate. A
        // location the server cleared isn't restored.
        let style = kind.locationStyle
        let candidate =
            local?.ebookLocation != nil && EbookLocation(local?.ebookLocation, style: style) == nil
                && EbookLocation(beforeMerge?.ebookLocation, style: style) != nil
            ? beforeMerge : local
        var server = knownServerProgress
        // Nor can it win against the server progress the row accepted since: a tie with that
        // baseline's date is the accepted value's.
        if let unmerged,
            let floor = [candidate?.ebookSavedAt, candidate?.serverBaseline?.lastUpdate].compactMap({ $0 }).max(),
            Self.baseline(unmerged).map({ $0.lastUpdate <= floor }) ?? true
        {
            server = nil
        }
        // A fetched value the store didn't take that echoes one of the row's own sends still
        // awaiting acknowledgement (the same position, as the store matches a send) isn't another
        // device's page: its server date is the PATCH's, not the page's. A newer unsent location
        // the row holds stays ahead of it.
        if let unmerged, let candidate, candidate.ebookDirty,
            EbookLocation(candidate.ebookLocation, style: style) != nil,
            candidate.unacknowledgedSends.contains(where: { send in
                guard let sent = send.ebook else { return false }
                return EbookPosition(location: sent.ebookLocation, progress: sent.ebookProgress).acknowledgeable
                    .contains { $0.matches(unmerged.ebookPosition) }
            })
        {
            server = nil
        }
        // The store merged the fetched value: the row holds its decision. A position it kept over
        // the fetched one (a newer unsent turn, or one whose PATCH is in flight), even at the same
        // location, mustn't lose to the raw value's date. The server stays a fallback when the row
        // has nothing this reader can open, and the source of a position the row took from it.
        if merged, let candidate, EbookLocation(candidate.ebookLocation, style: style) != nil,
            server.map({ !candidate.ebookPosition.matches($0.ebookPosition) }) ?? true
        {
            server = nil
        }
        let point = EbookResumePoint.resolve(kind: kind, local: candidate, server: server)
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
    /// location and progress; otherwise saved and sent after ``debounce`` without another one.
    /// A non-finite progress counts as unknown.
    public func record(_ location: EbookLocation, progress: Double?) {
        guard location.isValid(for: kind) else { return }
        let progress = EbookResumePoint.normalized(progress)
        guard location != self.location || progress != self.progress else { return }
        self.location = location
        self.progress = progress
        unsaved = (location, progress, now(), EbookTurnIntent.next(), knownPositions)
        debounceTask?.cancel()
        let (clock, debounce) = (clock, debounce)
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            // A newer turn cancels this task before replacing it.
            guard let self, !Task.isCancelled else { return }
            debounceTask = nil
            // Saved locally here; the drain isn't awaited, so this task doesn't keep the model.
            if await enqueueSave().value { enqueueDrain() }
        }
    }

    /// Saves a waiting page turn at once and sends it. Call when the reader closes and when the
    /// app moves to the background; returns when done.
    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard await enqueueSave().value else { return }
        await enqueueDrain().value
    }

    /// Sends unsent changes without a new page turn: the reconnect hook.
    public func syncPending() async {
        await enqueueDrain().value
    }

    // MARK: - Private

    /// The local row, or `nil` when there is none or it can't be read.
    private func readLocal() async -> LocalMediaProgressDTO? {
        do {
            return try await store.progress(for: key)
        } catch {
            logger.error("Reading local ebook progress failed: \(Self.caseName(error), privacy: .public)")
            return nil
        }
    }

    /// Takes the server ebook positions a row accounts for: its baseline's, its unsent value and
    /// its sends' (whose acknowledgement moves the baseline). Without a row, the seed's, which a
    /// first save copies into the new row's baseline.
    private func noteRead(_ row: LocalMediaProgressDTO?) {
        guard let row else {
            knownPositions = [serverSeed?.ebookPosition ?? EbookPosition(location: nil, progress: nil)]
            return
        }
        knownPositions =
            [row.serverBaseline?.ebookPosition].compactMap { $0 } + row.ebookPosition.acknowledgeable
            + row.unacknowledgedSends.compactMap(\.ebook).map {
                EbookPosition(location: $0.ebookLocation, progress: $0.ebookProgress)
            }
    }

    /// Queues ``save()`` behind the previous save only. Its value is whether to drain.
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
            noteRead(row)
            syncStateRevision += 1
            hasUnsyncedChanges = row?.ebookDirty ?? false
            lastError = saveError ?? row?.lastSyncError
        }
        drainTail = task
        return task
    }

    /// Saves the waiting turn locally. Returns `false` when the save failed, so nothing is sent;
    /// the turn is kept for the next save, unless a newer one replaced it.
    private func save() async -> Bool {
        guard let pending = unsaved else { return true }
        unsaved = nil
        let ebook = ProgressEdit.Ebook(location: pending.location.stored, progress: pending.progress)
        await willSave?()
        do {
            guard
                let row = try await store.recordEbookTurn(
                    ebook, for: key, intent: pending.intent, knownPositions: pending.knownPositions,
                    serverProgress: serverSeed, localLibraryItemID: localLibraryItemID, now: pending.at)
            else {
                // A later turn was saved first, or a newer server position was merged since the
                // turn: it wins, as it would have had the turn been saved at once.
                logger.info("Dropped an ebook turn older than the saved position")
                saveError = nil
                return true
            }
            let saved = EbookPosition(location: ebook.location, progress: ebook.progress).acknowledgeable
            knownPositions = (knownPositions ?? []) + saved
            // A turn recorded during this save took its snapshot before this position: the
            // acknowledgement of this save mustn't drop it as another device's newer page.
            if var waiting = unsaved, let known = waiting.knownPositions {
                waiting.knownPositions = known + saved
                unsaved = waiting
            }
            syncStateRevision += 1
            hasUnsyncedChanges = row.ebookDirty
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
