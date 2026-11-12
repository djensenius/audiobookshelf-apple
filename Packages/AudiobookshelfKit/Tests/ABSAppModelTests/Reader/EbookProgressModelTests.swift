import ABSAPI
import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSAppModel
@testable import ABSData
@testable import ABSPlayback

/// One connection's server for the model's resume GET and the real `ProgressSyncer`'s GETs and
/// PATCHes. Each PATCH is recorded with what the store held for the row when it went out, and
/// applied to the server's progress, dated by `now`. Queued `patchErrors` fail PATCHes in turn;
/// while `holdPatches` is set, each PATCH waits for ``releasePatches()``.
final class FakeProgressServer: ProgressSyncService, EbookProgressService {
    struct Failure: Error {}
    struct Write: Equatable {
        let update: MediaProgressUpdate
        /// The local row's ebook location and dirty flag when the PATCH went out.
        let localLocation: String?
        let localDirty: Bool?
    }

    let serverConnectionID: UUID
    let store: LocalProgressStore
    let now: @Sendable () -> Date
    let writes = Locked<[Write]>([])
    let patchErrors = Locked<[APIError]>([])
    let server = Locked<MediaProgress?>(nil)
    let fetchFails = Locked(false)
    let holdPatches = Locked(false)
    /// PATCHes in flight now, and the most at once.
    let inFlight = Locked((now: 0, most: 0))
    private let held = Locked<[CheckedContinuation<Void, Never>]>([])

    init(serverConnectionID: UUID, store: LocalProgressStore, now: @escaping @Sendable () -> Date) {
        self.serverConnectionID = serverConnectionID
        self.store = store
        self.now = now
    }

    func releasePatches() {
        holdPatches.value = false
        let waiting = held.value
        held.value = []
        for continuation in waiting { continuation.resume() }
    }

    var heldCount: Int { held.value.count }

    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        // The reader's GET (the syncer uses `fetchProgress`): answers what the server held when it
        // arrived, even when held.
        let answer = try await fetchProgress(itemID: itemID, episodeID: episodeID)
        if holdReaderFetches.value {
            await withCheckedContinuation { continuation in heldFetches.value.append(continuation) }
        }
        return answer
    }

    /// Holds the reader's GETs until ``releaseReaderFetches()``.
    let holdReaderFetches = Locked(false)
    private let heldFetches = Locked<[CheckedContinuation<Void, Never>]>([])
    var heldFetchCount: Int { heldFetches.value.count }

    func releaseReaderFetches() {
        holdReaderFetches.value = false
        let waiting = heldFetches.value
        heldFetches.value = []
        for continuation in waiting { continuation.resume() }
    }

    let fetches = Locked(0)

    func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        fetches.value += 1
        if fetchFails.value { throw Failure() }
        return server.value
    }

    func syncSession(id: String, report: PlaybackSyncReport) async throws {}

    /// No playback sessions: none is ever open.
    func openSession(id: String) async throws -> PlaybackSession { throw APIError.notFound }

    func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        let row = try await store.progress(for: key)
        writes.value.append(Write(update: update, localLocation: row?.ebookLocation, localDirty: row?.ebookDirty))
        inFlight.value.now += 1
        inFlight.value.most = max(inFlight.value.most, inFlight.value.now)
        if holdPatches.value {
            await withCheckedContinuation { continuation in held.value.append(continuation) }
        }
        inFlight.value.now -= 1
        var errors = patchErrors.value
        if !errors.isEmpty {
            let error = errors.removeFirst()
            patchErrors.value = errors
            throw error
        }
        var progress = server.value ?? MediaProgress(id: "mp-book", libraryItemId: itemID, episodeId: episodeID)
        if let location = update.ebookLocation { progress.ebookLocation = location }
        if let ebookProgress = update.ebookProgress { progress.ebookProgress = ebookProgress }
        if let currentTime = update.currentTime { progress.currentTime = currentTime }
        if let duration = update.duration { progress.duration = duration }
        if let audioProgress = update.progress { progress.progress = audioProgress }
        if let isFinished = update.isFinished { progress.isFinished = isFinished }
        progress.lastUpdate = Int(now().timeIntervalSince1970 * 1000)
        server.value = progress
    }
}

/// No playback: the syncer only drains.
@MainActor
final class IdlePlaybackSource: PlaybackProgressSource {
    var currentTime: Double = 0
    var confirmedPlaybackTime: Double?
    var loadedPositionIsExplicit = false
    var duration: Double = 0
    var isPlaying = false
    var chapterIndex: Int?
    var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackCloseHandoff?)?
    var quiesceProgressTransport: (@MainActor () -> Void)?

    func addObserver(_ handler: @escaping @MainActor (PlaybackCoordinatorEvent) -> Void) -> PlaybackObserverToken {
        PlaybackObserverToken()
    }

    func removeObserver(_ token: PlaybackObserverToken) {}
}

private let connection = UUID()
private let key = MediaKey(serverConnectionID: connection, libraryItemId: "book")
private let t0 = Date(timeIntervalSince1970: 1_000)

private func serverProgress(_ location: String?, progress: Double? = nil, at date: Date) -> MediaProgress {
    MediaProgress(
        id: "mp-book", libraryItemId: "book", ebookLocation: location, ebookProgress: progress,
        lastUpdate: Int(date.timeIntervalSince1970 * 1000))
}

@MainActor
@Suite struct EbookProgressModelTests {
    let container: ModelContainer
    let store: LocalProgressStore
    let service: FakeProgressServer
    let source = IdlePlaybackSource()
    let syncer: ProgressSyncer
    let clock = ManualClock()
    let time = Locked(t0)

    init() throws {
        container = try DataStack(location: .inMemory).container
        store = LocalProgressStore(modelContainer: container)
        let time = time
        service = FakeProgressServer(serverConnectionID: connection, store: store, now: { time.value })
        // Drain retries wait until the syncer goes away.
        syncer = ProgressSyncer(
            source: source, service: service, store: store,
            clock: ProgressSyncClock(
                now: { time.value }, uptime: { 0 }, sleep: { _ in try await Task.sleep(for: .seconds(86_400)) }))
    }

    func makeModel(
        _ kind: ReaderKind = .pdf, serverProgress: MediaProgress? = nil, debounce: Duration = .seconds(2)
    ) -> EbookProgressModel {
        let time = time
        return EbookProgressModel(
            key: key, kind: kind, store: store, service: service, syncer: syncer, serverProgress: serverProgress,
            debounce: debounce, clock: clock, now: { time.value })
    }

    /// Turns to `page` of 10.
    func turn(_ model: EbookProgressModel, to page: Int) {
        model.record(.page(page), progress: EbookLocation.progress(page: page, pageCount: 10))
    }

    func row() async throws -> LocalMediaProgressDTO {
        try #require(try await store.progress(for: key))
    }

    /// A clean row at `location`, acknowledged by the server at `date`.
    func cleanRow(_ location: String, progress: Double? = nil, at date: Date = t0) async throws {
        try await store.recordEdit(
            ProgressEdit(ebook: .init(location: location, progress: progress)), for: key, now: date)
        let patch = try #require(try await store.beginSend(for: key, now: date))
        try await store.completeSend(patch, serverLastUpdate: date)
        service.server.value = serverProgress(location, progress: progress ?? 0, at: date)
    }

    /// Applies `progress` as the store's callers do, captured now.
    @discardableResult
    func apply(_ progress: MediaProgress, source: ServerProgressSource = .fetch, currentTime: Double = 0) async throws
        -> Bool
    {
        let server = ProgressBaseline(
            currentTime: currentTime, progress: 0, duration: currentTime > 0 ? 600 : 0, isFinished: false,
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(try #require(progress.lastUpdate)) / 1000))
        let merged = try await store.applyServerProgress(
            [key: server], capturedAt: await store.captureGeneration(), source: source)
        return merged.contains(key)
    }

    // MARK: - Local first, debounced sending

    /// Each turn is saved at once, as a dirty edit; only the PATCH waits for the quiet time, and
    /// quick turns make one PATCH.
    @Test func turnsAreSavedAtOnceAndSentOnceAfterTheDebounce() async throws {
        let model = makeModel()
        var sleeps = clock.sleeps.makeAsyncIterator()

        for page in 2...5 {
            turn(model, to: page)
            #expect(await sleeps.next() == .seconds(2))
            await model.saveTail?.value
            #expect(try await row().ebookLocation == String(page))
            clock.advance(by: .seconds(1))
        }
        #expect(try await row().ebookDirty)
        #expect(model.hasUnsyncedChanges)
        #expect(service.writes.value.isEmpty)

        let task = try #require(model.debounceTask)
        clock.advance(by: .seconds(1))
        await task.value
        await model.drainTail?.value

        #expect(service.writes.value.map(\.update) == [.ebook(location: "5", progress: 0.4)])
        #expect(try await !row().ebookDirty)
        #expect(!model.hasUnsyncedChanges)
    }

    @Test func repeatedAndInvalidLocationsAreIgnored() async throws {
        let model = makeModel(.epub)
        model.record(.page(3), progress: 0.2)
        #expect(model.debounceTask == nil)
        model.record(.cfi("chapter1.xhtml"), progress: 0.2)
        #expect(model.debounceTask == nil)
        model.record(.cfi("epubcfi(/6/2)"), progress: 0.2)
        let task = try #require(model.debounceTask)
        model.record(.cfi("epubcfi(/6/2)"), progress: 0.2)
        #expect(model.debounceTask == task)
    }

    @Test func flushSendsAtOnce() async throws {
        let model = makeModel(.epub)
        model.record(.cfi("epubcfi(/6/4)"), progress: 0.25)
        await model.flush()

        #expect(model.debounceTask == nil)
        #expect(service.writes.value.map(\.update) == [.ebook(location: "epubcfi(/6/4)", progress: 0.25)])
        // The PATCH went out after the local save.
        #expect(service.writes.value.first?.localDirty == true)
        await model.flush()
        #expect(service.writes.value.count == 1)
    }

    /// A non-finite progress is unknown, not clamped; the PATCH sends 0 for it.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteProgressIsUnknown(value: Double) async throws {
        let model = makeModel()
        model.record(.page(2), progress: value)
        #expect(model.progress == nil)
        await model.flush()
        #expect(service.writes.value.map(\.update) == [.ebook(location: "2", progress: 0)])
    }

    /// A model released before its save ran saves the turn in `deinit`; the next drain sends it.
    @Test func releasedModelSavesItsTurn() async throws {
        var model: EbookProgressModel? = makeModel()
        turn(try #require(model), to: 4)
        model = nil
        #expect(await stored("4"))
        #expect(try await row().ebookDirty)
        #expect(service.writes.value.isEmpty)

        await syncer.drainPendingProgress()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["4"])
    }

    /// When the local save fails, nothing is sent; the turn is kept and the next flush saves and
    /// sends it.
    @Test func failedLocalSaveSendsNothing() async throws {
        let model = makeModel()
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        model.record(.page(4), progress: 0.3)
        await model.saveTail?.value
        await syncer.drainPendingProgress()

        #expect(service.writes.value.isEmpty)
        #expect(try await store.progress(for: key) == nil)
        #expect(model.lastError != nil)

        await model.flush()
        #expect(service.writes.value.map(\.localLocation) == ["4"])
        #expect(model.lastError == nil)
    }

    /// A turn made while the debounced task waits for a save cancels that task, so the new turn
    /// gets its own quiet period before anything is sent.
    @Test func aNewTurnCancelsADrainWaitingForItsSave() async throws {
        let model = makeModel()
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        turn(model, to: 1)
        let failed = try #require(model.saveTail)
        #expect(await failed.value == false)

        // The debounce retries the failed save; turn while that save is in the store.
        clock.advance(by: .seconds(2))
        while model.saveTail == failed { await Task.yield() }
        turn(model, to: 2)
        await model.saveTail?.value
        await model.drainTail?.value
        #expect(service.writes.value.isEmpty)

        clock.advance(by: .seconds(2))
        while model.drainTail == nil { await Task.yield() }
        await model.drainTail?.value
        #expect(service.writes.value.map(\.update.ebookLocation) == ["2"])
    }

    /// The reconnect hook saves a turn whose save failed before it sends, so the turn isn't
    /// left behind waiting for another page change.
    @Test func syncPendingSavesAFailedTurnFirst() async throws {
        let model = makeModel()
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        turn(model, to: 3)
        #expect(await model.saveTail?.value == false)

        await model.syncPending()
        #expect(try await row().ebookLocation == "3")
        #expect(service.writes.value.map(\.update.ebookLocation) == ["3"])
    }

    /// A new row is seeded from known server progress (ADR 0003), so only the ebook group is
    /// dirty and the audio fields aren't sent.
    @Test func seedsANewRowFromServerProgress() async throws {
        var known = serverProgress("2", at: t0)
        known.currentTime = 300
        known.duration = 600
        service.server.value = known
        let model = makeModel(serverProgress: known)
        time.value = t0.addingTimeInterval(60)
        model.record(.page(3), progress: 0.2)
        await model.flush()

        #expect(try await row().currentTime == 300)
        #expect(try await !row().audioDirty)
        #expect(service.writes.value.map(\.update) == [.ebook(location: "3", progress: 0.2)])
    }

    // MARK: - Failures and reconnect

    @Test func failedWriteStaysPendingAndSyncsLater() async throws {
        let model = makeModel()
        service.patchErrors.value = [.http(status: 503, message: nil)]
        model.record(.page(6), progress: 0.5)
        await model.flush()

        #expect(model.hasUnsyncedChanges)
        #expect(model.lastError == "http")
        // Persisted: a fresh store over the same database sees the pending row.
        let pending = try await LocalProgressStore(modelContainer: container).pendingSync(for: connection)
        #expect(pending.map(\.ebookLocation) == ["6"])
        #expect(pending.first?.ebookDirty == true)

        await model.syncPending()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["6", "6"])
        #expect(!model.hasUnsyncedChanges)
        #expect(model.lastError == nil)
    }

    /// The syncer settles a permanent rejection: the row stops being retried until the next edit.
    @Test func rejectedWriteIsNotRetried() async throws {
        let model = makeModel()
        service.patchErrors.value = [.notFound]
        model.record(.page(6), progress: 0.5)
        await model.flush()

        #expect(try await !row().needsServerSync)
        #expect(model.lastError == "rejected 404")
        await model.syncPending()
        #expect(service.writes.value.count == 1)
    }

    /// Waits until the store holds `location` for the row; `false` if it never does.
    func stored(_ location: String) async -> Bool {
        for attempt in 0..<2_000 {
            if (try? await store.progress(for: key))?.ebookLocation == location { return true }
            if attempt < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
        }
        return false
    }

    /// A held PATCH of page 3 doesn't hold back later local saves; the syncer then sends the
    /// latest, one PATCH at a time.
    @Test func aSlowPatchDoesNotHoldBackLaterLocalSaves() async throws {
        service.holdPatches.value = true
        let model = makeModel()
        turn(model, to: 3)
        let first = Task { await model.flush() }
        #expect(await eventually { service.heldCount == 1 })

        time.value = t0.addingTimeInterval(10)
        turn(model, to: 4)
        #expect(await stored("4"))
        turn(model, to: 5)
        let flush = Task { await model.flush() }
        #expect(await stored("5"))
        #expect(service.writes.value.map(\.update.ebookLocation) == ["3"])

        service.releasePatches()
        await first.value
        await flush.value
        #expect(service.server.value?.ebookLocation == "5")
        #expect(service.inFlight.value.most == 1)
        #expect(try await !row().needsServerSync)
    }

    /// A debounced drain held at a PATCH doesn't keep the model alive.
    @Test func aSlowPatchDoesNotKeepAReleasedModel() async throws {
        service.holdPatches.value = true
        var model: EbookProgressModel? = makeModel()
        var sleeps = clock.sleeps.makeAsyncIterator()
        turn(try #require(model), to: 3)
        #expect(await sleeps.next() == .seconds(2))
        clock.advance(by: .seconds(2))
        #expect(await eventually { service.heldCount == 1 })

        weak var released = model
        model = nil
        #expect(await eventually { released == nil })
        service.releasePatches()
    }

    /// The store hands out dirty audio before ebook (#53), so a save sends both, in that order.
    @Test func sendsDirtyAudioBeforeTheEbookGroup() async throws {
        let audio = ProgressEdit.Audio(currentTime: 30, duration: 600, progress: 0.05)
        try await store.recordEdit(ProgressEdit(audio: audio), for: key, now: t0)
        let model = makeModel()
        model.record(.page(2), progress: 0.1)
        await model.flush()

        #expect(
            service.writes.value.map(\.update) == [
                .audio(currentTime: 30, duration: 600, progress: 0.05), .ebook(location: "2", progress: 0.1),
            ])
    }

    // MARK: - Local-authoritative ebook group (ADR 0003)

    /// A dirty ebook edit survives another device's value dated before, with or after it, from a
    /// fetch or a socket, and is then sent. Audio from the same values still merges (control).
    @Test(arguments: [-20.0, 0, 60], [ServerProgressSource.fetch, .socket])
    func aDirtyEditSurvivesAnyServerValue(offset: TimeInterval, source: ServerProgressSource) async throws {
        try await cleanRow("2")
        let model = makeModel()
        time.value = t0.addingTimeInterval(30)
        turn(model, to: 4)
        await model.saveTail?.value

        let elsewhere = serverProgress("8", progress: 0.7, at: t0.addingTimeInterval(30 + offset))
        service.server.value = elsewhere
        try await apply(elsewhere, source: source, currentTime: 120)
        #expect(try await row().ebookLocation == "4")
        #expect(try await row().ebookDirty)
        #expect(try await row().currentTime == 120)

        await model.flush()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["4"])
        #expect(try await !row().ebookDirty)
    }

    /// The ack of page 3 doesn't clear page 4, saved while it was in flight: identity, not value,
    /// settles the edit, so page 4 stays dirty and is sent next.
    @Test func anAckOfAnOlderEditDoesNotClearANewerOne() async throws {
        let model = makeModel()
        turn(model, to: 3)
        await model.saveTail?.value
        let patch = try #require(try await store.beginSend(for: key, now: t0))
        time.value = t0.addingTimeInterval(5)
        turn(model, to: 4)
        await model.saveTail?.value
        try await store.completeSend(patch, serverLastUpdate: t0.addingTimeInterval(1))

        let afterAck = try await row()
        #expect(afterAck.ebookLocation == "4")
        #expect(afterAck.ebookDirty)
        #expect(afterAck.serverBaseline?.ebookLocation == "3")
        await model.flush()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["4"])
    }

    /// A clean row takes a newer server value; one older than its baseline is still dropped.
    @Test func aCleanRowTakesTheServerValue() async throws {
        try await cleanRow("2", at: t0.addingTimeInterval(10))
        #expect(try await !apply(serverProgress("9", at: t0)))
        #expect(try await row().ebookLocation == "2")

        #expect(try await apply(serverProgress("8", progress: 0.7, at: t0.addingTimeInterval(20))))
        #expect(try await row().ebookLocation == "8")
        #expect(try await !row().ebookDirty)
    }

    /// A socket's ebook values aren't merged: they request a fetch, which the next drain makes,
    /// and the fetched value is merged into the clean row.
    @Test func aSocketEbookUpdateRequestsAFetch() async throws {
        try await cleanRow("2")
        service.server.value = serverProgress("9", progress: 0.8, at: t0.addingTimeInterval(20))
        try await apply(serverProgress("9", progress: 0.8, at: t0.addingTimeInterval(20)), source: .socket)
        #expect(try await row().ebookLocation == "2")
        #expect(await store.needsEbookFetch == [key])

        await syncer.drainPendingProgress()
        #expect(try await row().ebookLocation == "9")
        #expect(await store.needsEbookFetch.isEmpty)
        #expect(service.writes.value.isEmpty)
    }

    /// A fetch issued after the request that finds no progress (404) answers it too, so later
    /// drains don't fetch again; one issued before the request doesn't.
    @Test func noProgressOnTheServerAnswersAnEbookFetchRequest() async throws {
        try await cleanRow("2")
        let early = await store.captureGeneration()
        try await apply(serverProgress("9", progress: 0.8, at: t0.addingTimeInterval(20)), source: .socket)
        await store.answerEbookFetch(for: key, capturedAt: early)
        #expect(await store.needsEbookFetch == [key])

        service.server.value = nil
        await syncer.drainPendingProgress()
        #expect(await store.needsEbookFetch.isEmpty)
        #expect(try await row().ebookLocation == "2")
        let fetches = service.fetches.value
        await syncer.drainPendingProgress()
        #expect(service.fetches.value == fetches)
    }

    // MARK: - Resume

    /// Dirty: the row's unsent page wins over a newer server page, without a fetch.
    @Test func resumeWhenDirtyKeepsTheLocalPage() async throws {
        try await store.recordEdit(ProgressEdit(ebook: .init(location: "3", progress: 0.2)), for: key, now: t0)
        service.server.value = serverProgress("8", progress: 0.7, at: t0.addingTimeInterval(60))
        let model = makeModel()

        #expect(await model.resume() == EbookResumePoint(location: .page(3), progress: 0.2, source: .local))
        #expect(model.hasUnsyncedChanges)
        await model.syncPending()
        #expect(service.server.value?.ebookLocation == "3")
    }

    /// Clean: the row is refreshed from the server first, so it opens at the newer page and
    /// nothing is sent over it.
    @Test func resumeWhenCleanRefreshesFromTheServer() async throws {
        try await cleanRow("3")
        service.server.value = serverProgress("8", progress: 0.7, at: t0.addingTimeInterval(60))
        let model = makeModel()

        #expect(await model.resume() == EbookResumePoint(location: .page(8), progress: 0.7, source: .local))
        #expect(!model.hasUnsyncedChanges)
        await model.syncPending()
        #expect(service.writes.value.isEmpty)
    }

    /// Offline: the persisted row, else the progress known at init; the first online resume
    /// creates the row an offline reopen finds.
    @Test func resumeWhenOfflineUsesPersistedState() async throws {
        service.fetchFails.value = true
        let known = serverProgress("epubcfi(/6/4)", at: t0)
        #expect(
            await makeModel(.epub, serverProgress: known).resume()
                == EbookResumePoint(location: .cfi("epubcfi(/6/4)"), progress: nil, source: .server))

        service.fetchFails.value = false
        service.server.value = serverProgress("6", progress: 0.5, at: t0)
        #expect(await makeModel().resume().location == .page(6))
        service.fetchFails.value = true
        #expect(await makeModel().resume() == EbookResumePoint(location: .page(6), progress: 0.5, source: .local))
    }

    /// A merge bringing a location for another format keeps the valid page it replaced for a PDF;
    /// an EPUB reader opens at the merged CFI. The other groups are still merged.
    @Test(arguments: [
        (ReaderKind.pdf, EbookResumePoint(location: .page(4), progress: 0.3, source: .local)),
        (.epub, EbookResumePoint(location: .cfi("epubcfi(/6/8)"), progress: 0.6, source: .local)),
    ])
    func aMergedLocationForAnotherFormatKeepsTheValidOne(kind: ReaderKind, expected: EbookResumePoint)
        async throws
    {
        try await cleanRow("4", progress: 0.3)
        var newer = serverProgress("epubcfi(/6/8)", progress: 0.6, at: t0.addingTimeInterval(60))
        newer.currentTime = 200
        newer.duration = 600
        service.server.value = newer

        #expect(await makeModel(kind).resume() == expected)
        #expect(try await row().currentTime == 200)
    }

    /// A newer server value that clears the location clears a clean row, and the reader opens at
    /// the start rather than at the page the row held before.
    @Test func aClearedLocationIsNotRestored() async throws {
        try await cleanRow("4", progress: 0.3)
        service.server.value = serverProgress(nil, at: t0.addingTimeInterval(60))

        #expect(await makeModel().resume() == .beginning)
        #expect(try await row().ebookLocation == nil)
    }

    /// A server without progress drops the known one: the reader opens at the start, and a new
    /// row isn't seeded with the removed fields.
    @Test func noServerProgressDropsTheKnownOne() async throws {
        var known = serverProgress("6", at: t0)
        known.currentTime = 300
        known.duration = 600
        let model = makeModel(serverProgress: known)

        #expect(await model.resume() == .beginning)
        model.record(.page(3), progress: 0.2)
        await model.saveTail?.value
        #expect(try await row().currentTime == 0)
    }

    @Test func resumeDoesNotMoveAnAlreadyTurnedPage() async throws {
        service.server.value = serverProgress("8", at: t0)
        let model = makeModel()
        model.record(.page(2), progress: 0.1)
        _ = await model.resume()
        #expect(model.location == .page(2))
    }

    @Test func unsupportedFormatsStartAtTheBeginning() async throws {
        service.server.value = serverProgress("3", at: t0)
        let model = makeModel(.unsupported(.mobi))
        #expect(await model.resume() == .beginning)
        model.record(.page(3), progress: 0.2)
        #expect(model.debounceTask == nil)
    }

    // MARK: - Review scenarios (#420)

    /// Page 2, page 3 sent, page 4 saved meanwhile; page 3 is acknowledged, then another device's
    /// later return to page 2 is fetched. Page 2 can't claim the acknowledgement or replace page
    /// 4: the newest local edit is kept and sent (the accepted trade-off).
    @Test func aReturnToAnEarlierPageDoesNotSettleANewerEdit() async throws {
        try await cleanRow("2")
        let model = makeModel()
        time.value = t0.addingTimeInterval(10)
        turn(model, to: 3)
        await model.saveTail?.value
        let patch = try #require(try await store.beginSend(for: key, now: time.value))
        time.value = t0.addingTimeInterval(20)
        turn(model, to: 4)
        await model.saveTail?.value
        try await store.completeSend(patch, serverLastUpdate: t0.addingTimeInterval(10))

        service.server.value = serverProgress("2", at: t0.addingTimeInterval(30))
        try await apply(serverProgress("2", at: t0.addingTimeInterval(30)))
        #expect(try await row().ebookLocation == "4")
        #expect(try await row().ebookDirty)
        await model.flush()
        #expect(service.server.value?.ebookLocation == "4")
    }

    /// A PDF resume of clean page 4 holds its GET (page 7, dated t+10) while a socket reports a
    /// CFI dated t+20. The CFI isn't merged (it requests a fetch), and the held GET, older than
    /// the baseline the socket's audio advanced, is dropped: the reader opens at page 4.
    @Test func aHeldResumeFetchAcrossASocketUpdateDoesNotWin() async throws {
        try await cleanRow("4", progress: 0.3)
        service.server.value = serverProgress("7", progress: 0.6, at: t0.addingTimeInterval(10))
        service.holdReaderFetches.value = true
        let model = makeModel()
        let resume = Task { await model.resume() }
        #expect(await eventually { service.heldFetchCount == 1 })

        try await apply(
            serverProgress("epubcfi(/6/8)", at: t0.addingTimeInterval(20)), source: .socket, currentTime: 50)
        service.releaseReaderFetches()

        #expect(await resume.value.location == .page(4))
        #expect(try await row().ebookLocation == "4")
        #expect(await store.needsEbookFetch == [key])
    }

    /// A page sent with unknown progress is confirmed as progress 0; a later page turn isn't
    /// mistaken for that send or dropped, whatever form the server stores it in.
    @Test func aConfirmationWithNormalizedProgressKeepsALaterTurn() async throws {
        let model = makeModel()
        model.record(.page(3), progress: nil)
        await model.saveTail?.value
        let patch = try #require(try await store.beginSend(for: key, now: t0))
        #expect(patch.values.ebook?.ebookProgress == 0)
        time.value = t0.addingTimeInterval(5)
        turn(model, to: 4)
        await model.saveTail?.value
        try await store.completeSend(patch, serverLastUpdate: nil)
        try await apply(serverProgress("3", progress: 0, at: t0.addingTimeInterval(1)))

        #expect(try await row().ebookLocation == "4")
        await model.flush()
        #expect(service.server.value?.ebookLocation == "4")
    }

    /// Before any resume: seeded page 2, page 3 saved and held, page 4 turned; a later-dated
    /// audio-only merge that keeps page 2 doesn't drop page 4, which reads the shared row.
    @Test func aSaveBeforeTheFirstResumeKeepsLaterTurns() async throws {
        let seed = serverProgress("2", at: t0)
        service.server.value = seed
        let model = makeModel(serverProgress: seed)
        service.holdPatches.value = true
        time.value = t0.addingTimeInterval(10)
        turn(model, to: 3)
        let flush = Task { await model.flush() }
        #expect(await eventually { service.heldCount == 1 })
        time.value = t0.addingTimeInterval(20)
        turn(model, to: 4)
        await model.saveTail?.value
        try await apply(serverProgress("2", at: t0.addingTimeInterval(30)), currentTime: 90)
        service.releasePatches()
        await flush.value
        await model.flush()

        #expect(try await row().ebookLocation == "4")
        #expect(service.server.value?.ebookLocation == "4")
    }
}

/// ``EbookResumePoint/resolve(kind:local:replaced:server:)``.
@Suite struct EbookResumePointTests {
    let store: LocalProgressStore

    init() throws {
        store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    @Test func noSavedLocationStartsAtTheBeginning() {
        #expect(EbookResumePoint.resolve(kind: .pdf, local: nil, server: nil) == .beginning)
        #expect(EbookResumePoint.resolve(kind: .pdf, local: nil, server: serverProgress(nil, at: t0)) == .beginning)
    }

    /// The row wins over the server whatever the dates; a location invalid for the reader isn't a
    /// candidate.
    @Test func theRowWinsAndInvalidLocationsAreSkipped() async throws {
        let server = serverProgress("epubcfi(/6/2)", at: t0.addingTimeInterval(60))
        #expect(EbookResumePoint.resolve(kind: .pdf, local: nil, server: server) == .beginning)
        let local = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "4", progress: nil)), for: key, now: t0)
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: server).location == .page(4))
        #expect(EbookResumePoint.resolve(kind: .epub, local: local, server: server).source == .server)
        let newer = serverProgress("9", at: t0.addingTimeInterval(60))
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: newer).location == .page(4))
    }

    /// A chosen progress is normalized like a recorded one.
    @Test(arguments: [(Double.nan, nil), (.infinity, nil), (1.7, 1), (-0.2, 0), (0.4, 0.4)] as [(Double, Double?)])
    func chosenProgressIsNormalized(saved: Double, expected: Double?) async throws {
        var local = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "4", progress: 0.3)), for: key, now: t0)
        local.ebookProgress = saved
        #expect(
            EbookResumePoint.resolve(kind: .pdf, local: local, server: nil)
                == EbookResumePoint(location: .page(4), progress: expected, source: .local))
    }
}
