import ABSAPI
import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSAppModel
@testable import ABSData

/// Records each PATCH with what the store held for the row when it was sent; fails while
/// `fails` is set.
final class FakeEbookProgressService: EbookProgressService {
    struct Failure: Error {}
    struct Write: Equatable {
        let update: MediaProgressUpdate
        /// The local row's ebook location and dirty flag when the PATCH went out.
        let localLocation: String?
        let localDirty: Bool?
    }

    let store: LocalProgressStore
    let writes = Locked<[Write]>([])
    let fails = Locked(false)
    let server = Locked<MediaProgress?>(nil)
    let fetchFails = Locked(false)

    init(store: LocalProgressStore) {
        self.store = store
    }

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        let row = try await store.progress(for: key)
        writes.value.append(Write(update: update, localLocation: row?.ebookLocation, localDirty: row?.ebookDirty))
        if fails.value { throw Failure() }
    }

    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        if fetchFails.value { throw Failure() }
        return server.value
    }
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
    let service: FakeEbookProgressService
    let clock = ManualClock()
    let time = Locked(t0)

    init() throws {
        container = try DataStack(location: .inMemory).container
        store = LocalProgressStore(modelContainer: container)
        service = FakeEbookProgressService(store: store)
    }

    func makeModel(
        _ kind: ReaderKind = .pdf, serverProgress: MediaProgress? = nil, debounce: Duration = .seconds(2)
    ) -> EbookProgressModel {
        let time = time
        return EbookProgressModel(
            key: key, kind: kind, store: store, service: service, serverProgress: serverProgress,
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
        turn(model, to: 3)
        #expect(await sleeps.next() == .seconds(2))
        let second = try #require(model.debounceTask)
        clock.advance(by: .seconds(2))
        await second.value

        #expect(service.writes.value.map(\.update.ebookLocation) == ["2", "3"])
    }

    /// Negative control for the coalescing test: the same turns without a debounce make one
    /// PATCH each.
    @Test func withoutADebounceEachTurnIsSent() async throws {
        let model = makeModel(debounce: .zero)
        for page in 2...5 {
            turn(model, to: page)
            await model.debounceTask?.value
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

    /// A new row is seeded from known server progress (ADR 0003), so only the ebook group is
    /// dirty and the audio fields aren't sent.
    @Test func seedsANewRowFromServerProgress() async throws {
        var known = serverProgress("2", at: t0)
        known.currentTime = 300
        known.duration = 600
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
        service.fails.value = true
        model.record(.page(6), progress: 0.5)
        await model.flush()

        #expect(service.writes.value.count == 1)
        #expect(model.hasUnsyncedChanges)
        #expect(model.lastError == "Failure")
        // Persisted: a fresh store over the same database sees the pending row.
        let reopened = LocalProgressStore(modelContainer: container)
        let pending = try await reopened.pendingSync(for: connection)
        #expect(pending.map(\.ebookLocation) == ["6"])
        #expect(pending.first?.ebookDirty == true)
        #expect(pending.first?.lastSyncError == "Failure")

        service.fails.value = false
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
        #expect(point == EbookResumePoint(location: .page(8), progress: 0.7, source: .server))
        #expect(model.location == .page(8))
        #expect(model.hasUnsyncedChanges)
    }

    @Test func resumesFromTheNewerLocalLocation() async throws {
        service.server.value = serverProgress("8", at: t0)
        try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "3", progress: 0.2)), for: key, now: t0.addingTimeInterval(60))
        let model = makeModel()

        #expect(await model.resume() == EbookResumePoint(location: .page(3), progress: 0.2, source: .local))
    }

    /// Offline: the known progress is used when the server can't be reached.
    @Test func resumesFromKnownProgressWhenOffline() async throws {
        service.fetchFails.value = true
        let model = makeModel(.epub, serverProgress: serverProgress("epubcfi(/6/4)", at: t0))
        #expect(
            await model.resume() == EbookResumePoint(location: .cfi("epubcfi(/6/4)"), progress: nil, source: .server))
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
