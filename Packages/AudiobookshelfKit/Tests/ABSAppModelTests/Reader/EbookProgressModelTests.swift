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
        try await fetchProgress(itemID: itemID, episodeID: episodeID)
    }

    func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
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

    // MARK: - Debounce

    @Test func pageTurnsCoalesceIntoOnePatch() async throws {
        let model = makeModel()
        var sleeps = clock.sleeps.makeAsyncIterator()

        for page in 2...5 {
            turn(model, to: page)
            #expect(await sleeps.next() == .seconds(2))
            clock.advance(by: .seconds(1))
        }
        #expect(model.location == .page(5))
        let task = try #require(model.debounceTask)
        clock.advance(by: .seconds(1))
        await task.value
        // The debounce saves locally and starts the drain without waiting for it.
        await model.drainTail?.value

        #expect(service.writes.value.map(\.update) == [.ebook(location: "5", progress: 0.4)])
        let row = try #require(try await store.progress(for: key))
        #expect(row.ebookLocation == "5")
        #expect(!row.ebookDirty)
        #expect(!model.hasUnsyncedChanges)
    }

    /// Negative control: nothing is saved or sent before the quiet time passes, and a turn after
    /// it makes a second PATCH, so the single PATCH above is the debounce at work.
    @Test func debounceWaitsAndThenSendsEachQuietTurn() async throws {
        let model = makeModel()
        var sleeps = clock.sleeps.makeAsyncIterator()

        turn(model, to: 2)
        #expect(await sleeps.next() == .seconds(2))
        clock.advance(by: .milliseconds(1_999))
        #expect(clock.sleeperCount == 1)
        #expect(service.writes.value.isEmpty)
        #expect(try await store.progress(for: key) == nil)

        let first = try #require(model.debounceTask)
        clock.advance(by: .milliseconds(1))
        await first.value
        await model.drainTail?.value
        turn(model, to: 3)
        #expect(await sleeps.next() == .seconds(2))
        let second = try #require(model.debounceTask)
        clock.advance(by: .seconds(2))
        await second.value
        await model.drainTail?.value

        #expect(service.writes.value.map(\.update.ebookLocation) == ["2", "3"])
    }

    /// Negative control for the coalescing test: the same turns without a debounce make one
    /// PATCH each.
    @Test func withoutADebounceEachTurnIsSent() async throws {
        let model = makeModel(debounce: .zero)
        for page in 2...5 {
            turn(model, to: page)
            await model.debounceTask?.value
            await model.drainTail?.value
        }
        #expect(service.writes.value.map(\.update.ebookLocation) == ["2", "3", "4", "5"])
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

    @Test func flushSavesAndSendsAtOnce() async throws {
        let model = makeModel(.epub)
        model.record(.cfi("epubcfi(/6/4)"), progress: 0.25)
        await model.flush()

        #expect(model.debounceTask == nil)
        #expect(clock.sleeperCount == 0)
        #expect(service.writes.value.map(\.update) == [.ebook(location: "epubcfi(/6/4)", progress: 0.25)])
        // Nothing waits: a second flush sends nothing.
        await model.flush()
        #expect(service.writes.value.count == 1)
    }

    /// A non-finite progress is unknown, not clamped; the PATCH sends 0 for it.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteProgressIsUnknown(value: Double) async throws {
        let model = makeModel()
        model.record(.page(2), progress: value)
        #expect(model.location == .page(2))
        #expect(model.progress == nil)
        await model.flush()
        #expect(service.writes.value.map(\.update) == [.ebook(location: "2", progress: 0)])
    }

    /// A model released with a turn still waiting saves it locally; the next drain sends it.
    @Test func releasedModelSavesAWaitingTurn() async throws {
        var model: EbookProgressModel? = makeModel()
        turn(try #require(model), to: 4)
        model = nil
        for _ in 0..<1_000 where try await store.progress(for: key) == nil {
            await Task.yield()
        }
        let row = try #require(try await store.progress(for: key))
        #expect(row.ebookLocation == "4")
        #expect(row.ebookDirty)
        #expect(service.writes.value.isEmpty)

        await syncer.drainPendingProgress()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["4"])
    }

    // MARK: - Local first

    @Test func savesLocallyBeforeTheNetwork() async throws {
        let model = makeModel()
        model.record(.page(4), progress: 0.3)
        await model.flush()

        let write = try #require(service.writes.value.first)
        #expect(write.localLocation == "4")
        #expect(write.localDirty == true)
    }

    /// Negative control: when the local save fails, nothing is sent; the turn is kept and the
    /// next flush saves and sends it.
    @Test func failedLocalSaveSendsNothing() async throws {
        let model = makeModel()
        model.record(.page(4), progress: 0.3)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await model.flush()

        #expect(service.writes.value.isEmpty)
        #expect(try await store.progress(for: key) == nil)
        #expect(model.lastError != nil)

        await model.flush()
        #expect(service.writes.value.map(\.localLocation) == ["4"])
        #expect(model.lastError == nil)
    }

    /// A retried save keeps the turn's own date: page 4, turned before another device saved page
    /// 8, loses the merge to it when the retry comes later, so it isn't PATCHed over page 8.
    @Test func aRetriedSaveIsDatedWhenTheTurnWasRecorded() async throws {
        let model = makeModel()
        model.record(.page(4), progress: 0.3)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await model.flush()
        #expect(try await store.progress(for: key) == nil)

        service.server.value = serverProgress("8", progress: 0.7, at: t0.addingTimeInterval(10))
        time.value = t0.addingTimeInterval(20)
        await model.flush()

        #expect(service.writes.value.isEmpty)
        let row = try #require(try await store.progress(for: key))
        #expect(row.ebookLocation == "8")
        #expect(!row.ebookDirty)
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

        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(!row.audioDirty)
        #expect(service.writes.value.map(\.update) == [.ebook(location: "3", progress: 0.2)])
    }

    // MARK: - Failures and reconnect

    @Test func failedWriteStaysPendingAndSyncsLater() async throws {
        let model = makeModel()
        service.patchErrors.value = [.http(status: 503, message: nil)]
        model.record(.page(6), progress: 0.5)
        await model.flush()

        #expect(service.writes.value.count == 1)
        #expect(model.hasUnsyncedChanges)
        #expect(model.lastError == "http")
        // Persisted: a fresh store over the same database sees the pending row.
        let reopened = LocalProgressStore(modelContainer: container)
        let pending = try await reopened.pendingSync(for: connection)
        #expect(pending.map(\.ebookLocation) == ["6"])
        #expect(pending.first?.ebookDirty == true)
        #expect(pending.first?.lastSyncError == "http")

        await model.syncPending()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["6", "6"])
        #expect(!model.hasUnsyncedChanges)
        #expect(model.lastError == nil)
        #expect(try await store.pendingSync(for: connection).isEmpty)
    }

    @Test func syncPendingWithNothingPendingSendsNothing() async {
        let model = makeModel()
        await model.syncPending()
        #expect(service.writes.value.isEmpty)
    }

    /// The syncer settles a permanent rejection with `rejectSend`: the row stops being retried
    /// until the next edit. (A 503 stays pending: see the test above.)
    @Test func rejectedWriteIsNotRetried() async throws {
        let model = makeModel()
        service.patchErrors.value = [.notFound]
        model.record(.page(6), progress: 0.5)
        await model.flush()

        let row = try #require(try await store.progress(for: key))
        #expect(!row.needsServerSync)
        #expect(!model.hasUnsyncedChanges)
        #expect(model.lastError == "rejected 404")
        await model.syncPending()
        #expect(service.writes.value.count == 1)
    }

    /// An external drain holds a PATCH of page 3 while the reader saves page 5: the syncer sends
    /// one PATCH at a time, page 3 then page 5, and the row ends clean at 5.
    @Test func modelAndSyncerShareTheRow() async throws {
        try await store.recordEdit(ProgressEdit(ebook: .init(location: "3", progress: 0.2)), for: key, now: t0)
        service.holdPatches.value = true
        let external = Task { await syncer.drainPendingProgress() }
        #expect(await eventually { service.heldCount == 1 })

        let model = makeModel()
        time.value = t0.addingTimeInterval(10)
        turn(model, to: 5)
        let flush = Task { await model.flush() }
        // Saved locally while page 3 is still in flight.
        for _ in 0..<1_000 where try await store.progress(for: key)?.ebookLocation != "5" {
            await Task.yield()
        }
        #expect(try await store.progress(for: key)?.ebookLocation == "5")
        #expect(service.writes.value.count == 1)
        service.releasePatches()
        await external.value
        await flush.value

        #expect(service.writes.value.map(\.update.ebookLocation) == ["3", "5"])
        #expect(service.inFlight.value.most == 1)
        let row = try #require(try await store.progress(for: key))
        #expect(row.ebookLocation == "5")
        #expect(!row.needsServerSync)
        #expect(!model.hasUnsyncedChanges)
    }

    /// Waits until the store holds `location` for the row; `false` if it never does.
    func stored(_ location: String) async -> Bool {
        for attempt in 0..<2_000 {
            if (try? await store.progress(for: key))?.ebookLocation == location { return true }
            if attempt < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
        }
        return false
    }

    /// The model's own drain holds a PATCH of page 3. Later turns are still saved locally, after
    /// their debounce and on flush, before that PATCH finishes; the syncer then sends the latest.
    @Test func aSlowPatchDoesNotHoldBackLaterLocalSaves() async throws {
        service.holdPatches.value = true
        let model = makeModel()
        var sleeps = clock.sleeps.makeAsyncIterator()
        turn(model, to: 3)
        #expect(await sleeps.next() == .seconds(2))
        clock.advance(by: .seconds(2))
        #expect(await eventually { service.heldCount == 1 })

        time.value = t0.addingTimeInterval(10)
        turn(model, to: 4)
        #expect(await sleeps.next() == .seconds(2))
        clock.advance(by: .seconds(2))
        #expect(await stored("4"))

        turn(model, to: 5)
        let flush = Task { await model.flush() }
        #expect(await stored("5"))
        #expect(service.writes.value.map(\.update.ebookLocation) == ["3"])

        service.releasePatches()
        await flush.value
        #expect(service.server.value?.ebookLocation == "5")
        #expect(service.inFlight.value.most == 1)
        #expect(try await store.progress(for: key)?.needsServerSync == false)
        #expect(!model.hasUnsyncedChanges)
    }

    /// A drain held at a PATCH doesn't keep the model alive, so releasing it saves its waiting
    /// turn at once (`deinit`), and the syncer sends it later.
    @Test func aSlowPatchDoesNotKeepAReleasedModel() async throws {
        service.holdPatches.value = true
        var model: EbookProgressModel? = makeModel()
        var sleeps = clock.sleeps.makeAsyncIterator()
        turn(try #require(model), to: 3)
        #expect(await sleeps.next() == .seconds(2))
        clock.advance(by: .seconds(2))
        #expect(await eventually { service.heldCount == 1 })

        weak var released = model
        turn(try #require(model), to: 4)
        model = nil
        #expect(await eventually { released == nil })
        #expect(await stored("4"))

        service.releasePatches()
        await syncer.drainPendingProgress()
        #expect(await eventually { service.server.value?.ebookLocation == "4" })
    }

    /// The syncer fetches before sending: a dirty audio group from older offline listening
    /// doesn't overwrite a newer server position, while one newer than the server is still sent
    /// (negative control).
    @Test(arguments: [(60.0, false), (-60.0, true)])
    func olderOfflineAudioDoesNotOverwriteANewerServerPosition(serverOffset: Double, sendsAudio: Bool) async throws {
        let audio = ProgressEdit.Audio(currentTime: 30, duration: 600, progress: 0.05)
        try await store.recordEdit(ProgressEdit(audio: audio), for: key, now: t0)
        var newer = serverProgress(nil, at: t0.addingTimeInterval(serverOffset))
        newer.currentTime = 500
        newer.duration = 600
        service.server.value = newer
        let model = makeModel()
        time.value = t0.addingTimeInterval(120)
        model.record(.page(2), progress: 0.1)
        await model.flush()

        let audioSent = service.writes.value.contains { $0.update.ebookLocation == nil }
        #expect(audioSent == sendsAudio)
        #expect(service.writes.value.last?.update == .ebook(location: "2", progress: 0.1))
        #expect(try await store.progress(for: key)?.currentTime == (sendsAudio ? 30 : 500))
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

    // MARK: - Resume

    @Test func resumesFromTheNewerServerLocation() async throws {
        try await store.recordEdit(ProgressEdit(ebook: .init(location: "3", progress: 0.2)), for: key, now: t0)
        service.server.value = serverProgress("8", progress: 0.7, at: t0.addingTimeInterval(60))
        let model = makeModel()

        let point = await model.resume()
        #expect(point.location == .page(8))
        #expect(model.location == .page(8))
        // The newer server value is merged into the row, so closing doesn't PATCH page 3 over it.
        let row = try #require(try await store.progress(for: key))
        #expect(row.ebookLocation == "8")
        #expect(!row.ebookDirty)
        #expect(!model.hasUnsyncedChanges)
        await model.flush()
        await model.syncPending()
        #expect(!service.writes.value.contains { $0.update.ebookLocation == "3" })
        #expect(try await store.progress(for: key)?.ebookLocation == "8")
    }

    @Test func resumesFromTheNewerLocalLocation() async throws {
        service.server.value = serverProgress("8", at: t0)
        try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "3", progress: 0.2)), for: key, now: t0.addingTimeInterval(60))
        let model = makeModel()

        #expect(await model.resume() == EbookResumePoint(location: .page(3), progress: 0.2, source: .local))
        // Negative control for the merge: the newer unsent edit stays and is sent.
        #expect(model.hasUnsyncedChanges)
        await model.syncPending()
        #expect(service.writes.value.map(\.update.ebookLocation) == ["3"])
        #expect(try await store.progress(for: key)?.ebookDirty == false)
    }

    /// A newer server CFI can't open in a PDF. The merge still takes the server's values, but the
    /// PDF reader opens at the valid local page it replaced, not the start; an EPUB reader of
    /// the same row opens at the CFI (control).
    @Test(arguments: [
        (ReaderKind.pdf, EbookResumePoint(location: .page(4), progress: 0.3, source: .local)),
        (.epub, EbookResumePoint(location: .cfi("epubcfi(/6/8)"), progress: 0.6, source: .server)),
    ])
    func aNewerLocationForAnotherFormatKeepsTheValidLocalOne(kind: ReaderKind, expected: EbookResumePoint)
        async throws
    {
        try await store.recordEdit(ProgressEdit(ebook: .init(location: "4", progress: 0.3)), for: key, now: t0)
        var newer = serverProgress("epubcfi(/6/8)", progress: 0.6, at: t0.addingTimeInterval(60))
        newer.currentTime = 200
        newer.duration = 600
        service.server.value = newer
        let model = makeModel(kind)

        #expect(await model.resume() == expected)
        #expect(model.location == expected.location)
        // The other groups are still reconciled.
        #expect(try await store.progress(for: key)?.currentTime == 200)
    }

    /// Offline: the known progress is used when the server can't be reached.
    @Test func resumesFromKnownProgressWhenOffline() async throws {
        service.fetchFails.value = true
        let model = makeModel(.epub, serverProgress: serverProgress("epubcfi(/6/4)", at: t0))
        #expect(
            await model.resume() == EbookResumePoint(location: .cfi("epubcfi(/6/4)"), progress: nil, source: .server))
    }

    /// A server that answers with no progress (it was removed) drops the known progress: the
    /// reader opens at the start, and a new row isn't seeded with the removed fields.
    @Test func noServerProgressDropsTheKnownOne() async throws {
        var known = serverProgress("6", at: t0)
        known.currentTime = 300
        known.duration = 600
        let model = makeModel(serverProgress: known)

        #expect(await model.resume() == .beginning)
        #expect(model.location == nil)
        // A failed PATCH leaves the row as saved, without a confirmation merge.
        service.patchErrors.value = [.http(status: 503, message: nil)]
        model.record(.page(3), progress: 0.2)
        await model.flush()
        let row = try #require(try await store.progress(for: key))
        #expect(row.ebookLocation == "3")
        #expect(row.currentTime == 0)
        #expect(row.duration == 0)
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
}

/// ``EbookResumePoint/resolve(kind:local:server:)`` against rows built by the real store.
@Suite struct EbookResumePointTests {
    let store: LocalProgressStore

    init() throws {
        store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    private func baseline(_ location: String?, at date: Date) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: 0, progress: 0, duration: 0, isFinished: false, ebookLocation: location, lastUpdate: date)
    }

    @Test func noSavedLocationStartsAtTheBeginning() {
        #expect(EbookResumePoint.resolve(kind: .pdf, local: nil, server: nil) == .beginning)
        let empty = serverProgress(nil, at: t0)
        #expect(EbookResumePoint.resolve(kind: .pdf, local: nil, server: empty) == .beginning)
    }

    @Test func invalidLocationsAreRejected() async throws {
        // A CFI saved for a PDF and a page saved for an EPUB are not candidates.
        let server = serverProgress("epubcfi(/6/2)", at: t0.addingTimeInterval(60))
        #expect(EbookResumePoint.resolve(kind: .pdf, local: nil, server: server) == .beginning)
        let local = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "4", progress: nil)), for: key, now: t0)
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: server).location == .page(4))
        #expect(EbookResumePoint.resolve(kind: .epub, local: local, server: server).source == .server)
    }

    /// On equal dates the server wins; an unsent edit wins only when strictly newer.
    @Test func serverWinsTies() async throws {
        let local = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "4", progress: nil)), for: key, now: t0)
        let server = serverProgress("9", at: t0)
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: server).source == .server)
        let older = serverProgress("9", at: t0.addingTimeInterval(-1))
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: older).source == .local)
    }

    /// The server's date is row-wide: another device's audio change makes it newer without
    /// changing the ebook location. The unsent page turn made here still wins; a real ebook
    /// change from elsewhere wins (negative control).
    @Test func unsentEditBeatsAServerDateMovedByAudio() async throws {
        let local = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "5", progress: 0.4)), for: key,
            serverProgress: baseline("2", at: t0), now: t0.addingTimeInterval(10))
        #expect(local.ebookDirty)

        var audioElsewhere = serverProgress("2", at: t0.addingTimeInterval(60))
        audioElsewhere.currentTime = 120
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: audioElsewhere).source == .local)

        let ebookElsewhere = serverProgress("7", at: t0.addingTimeInterval(60))
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: ebookElsewhere).source == .server)
    }

    /// An unsent edit this reader can't open (an EPUB CFI for a PDF) doesn't hide the server's
    /// unchanged page; the EPUB reader still opens at its own unsent edit (control).
    @Test func anUnopenableUnsentEditKeepsTheUnchangedServerLocation() async throws {
        let local = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "epubcfi(/6/8)", progress: 0.6)), for: key,
            serverProgress: baseline("4", at: t0), now: t0.addingTimeInterval(10))
        #expect(local.ebookDirty)
        let server = serverProgress("4", at: t0)

        #expect(
            EbookResumePoint.resolve(kind: .pdf, local: local, server: server)
                == EbookResumePoint(location: .page(4), progress: nil, source: .server))
        #expect(
            EbookResumePoint.resolve(kind: .epub, local: local, server: server)
                == EbookResumePoint(location: .cfi("epubcfi(/6/8)"), progress: 0.6, source: .local))
    }

    /// A clean row is dated by the baseline's `lastUpdate` when it is later than the edit.
    @Test func cleanRowIsDatedByItsBaseline() async throws {
        _ = try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "5", progress: nil)), for: key,
            serverProgress: baseline("5", at: t0.addingTimeInterval(120)), now: t0)
        let patch = try #require(try await store.beginSend(for: key, now: t0))
        try await store.completeSend(patch, serverLastUpdate: t0.addingTimeInterval(120))
        let local = try #require(try await store.progress(for: key))
        #expect(!local.ebookDirty)
        #expect(local.ebookSavedAt == t0.addingTimeInterval(120))

        let older = serverProgress("1", at: t0.addingTimeInterval(60))
        #expect(EbookResumePoint.resolve(kind: .pdf, local: local, server: older).location == .page(5))
    }
}
