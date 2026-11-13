import ABSAPI
import ABSCore
import Foundation
import SwiftData
import Testing
@preconcurrency import ZIPFoundation

@testable import ABSAppModel
@testable import ABSData
@testable import ABSPlayback

private let connection = UUID()
private let t0 = Date(timeIntervalSince1970: 1_000)

private func request(ext: String = "pdf") -> EbookFileRequest {
    EbookFileRequest(connectionID: connection, itemID: "book", fileIno: "ino_1", fileExtension: ext, version: "1")
}

private func serverProgress(_ location: String?) -> MediaProgress {
    MediaProgress(
        id: "mp-book", libraryItemId: "book", ebookLocation: location, ebookProgress: 0.5,
        lastUpdate: Int(t0.timeIntervalSince1970 * 1000))
}

private enum ReaderTestFailure: Error {
    case notReady
}

/// A CBZ of `pages` entries (`page1.png` …). The bytes aren't images: opening and turning don't
/// decode pages.
private func comicData(pages: Int) throws -> Data {
    let archive = try Archive(accessMode: .create)
    for page in 1...pages {
        let data = Data("page \(page)".utf8)
        try archive.addEntry(
            with: "page\(page).png", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none,
            provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
    }
    return try #require(archive.data)
}

@MainActor
@Suite struct ReaderContainerModelTests {
    let fetcher: FakeEbookFetcher

    init(fetcher: FakeEbookFetcher = FakeEbookFetcher()) {
        self.fetcher = fetcher
    }

    func makeModel(
        _ kind: ReaderKind = .pdf, progress: EbookProgressModel? = nil, server: MediaProgress? = nil
    ) -> ReaderContainerModel {
        let ext =
            switch kind {
            case .epub: "epub"
            case .comic: "cbz"
            default: "pdf"
            }
        return ReaderContainerModel(
            request: request(ext: ext), kind: kind,
            loader: EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher), progress: progress,
            serverProgress: server)
    }

    @Test func unsupportedFormatsFetchNothing() async {
        for (kind, name) in [(ReaderKind.unsupported(.mobi), "MOBI"), (.unsupported(.cbr), "CBR")] {
            let model = makeModel(kind)
            await model.load()
            #expect(model.content == .unsupported)
            #expect(model.display == .unsupported)
            #expect(model.formatName == name)
        }
        #expect(fetcher.calls.value.isEmpty)
        #expect(ReaderContainerModel.opens(.epub))
        #expect(ReaderContainerModel.opens(.pdf))
        #expect(ReaderContainerModel.opens(.comic))
    }

    /// Each format's file goes to its own reader: comics to the comic pager, not the refusal.
    @Test func theFileGoesToItsFormatsReader() async throws {
        let routes: [(ReaderKind, @Sendable (URL) -> ReaderContainerModel.Display)] = [
            (.epub, { .epub($0) }), (.pdf, { .pdf($0) }), (.comic, { .comic($0) }),
        ]
        for (kind, display) in routes {
            let model = makeModel(kind)
            #expect(model.display == .loading)
            await model.load()
            guard case .ready(let url) = model.content else { throw ReaderTestFailure.notReady }
            #expect(model.display == display(url), "\(kind)")
        }
        #expect(fetcher.calls.value.count == routes.count)

        fetcher.fails.value = true
        let failed = makeModel(.comic)
        await failed.load()
        #expect(failed.display == .failed)
    }

    @Test func theLoadedFileStaysPinnedUntilReleased() async throws {
        let model = makeModel()
        await model.load()
        guard case .ready(let url) = model.content else { throw ReaderTestFailure.notReady }
        #expect(EbookFileLoader.pins.isPinned(url))

        model.releaseFile()
        #expect(!EbookFileLoader.pins.isPinned(url))

        // Closed before the load finished: nothing stays pinned.
        let closed = makeModel()
        closed.releaseFile()
        await closed.load()
        guard case .ready(let late) = closed.content else { throw ReaderTestFailure.notReady }
        #expect(!EbookFileLoader.pins.isPinned(late))
    }

    @Test func withoutAProgressModelOpensAtTheServersPositionAndSavesNothing() async throws {
        let model = makeModel(server: serverProgress("5"))

        await model.load()

        guard case .ready(let url) = model.content else {
            Issue.record("Expected a ready file, got \(model.content)")
            return
        }
        #expect(try Data(contentsOf: url) == Data("book".utf8))
        #expect(model.resumePoint == EbookResumePoint(location: .page(5), progress: 0.5, source: .server))
        #expect(model.location == .page(5))
        #expect(!model.savesProgress)

        model.record(.page(6), progress: 0.6)
        #expect(model.location == .page(6))
        #expect(model.progress == 0.6)
        // A CFI isn't a PDF location.
        model.record(.cfi("epubcfi(/6/4)"), progress: 0.9)
        #expect(model.location == .page(6))
    }

    @Test func aFailedFetchShowsTheFailureAndRetries() async {
        fetcher.fails.value = true
        let model = makeModel()

        await model.load()
        #expect(model.content == .failed)

        fetcher.fails.value = false
        await model.load()
        guard case .ready = model.content else {
            Issue.record("Expected a ready file, got \(model.content)")
            return
        }
    }

    @Test func tapsToggleTheChrome() {
        let model = makeModel()
        #expect(model.isChromeVisible)
        model.toggleChrome()
        #expect(!model.isChromeVisible)
        model.toggleChrome()
        #expect(model.isChromeVisible)
    }

    // MARK: With a progress model

    @Test func turnsGoThroughTheProgressModelButOpeningDoesNot() async throws {
        let harness = try ProgressHarness()
        let progress = harness.makeProgressModel()
        let model = makeModel(progress: progress, server: nil)
        harness.service.server.value = serverProgress("3")

        await model.load()
        #expect(model.resumePoint.location == .page(3))
        #expect(model.savesProgress)

        // The reader reports where it opened: not a turn.
        model.record(.page(3), progress: 0.3)
        await model.flush()
        #expect(try await harness.row()?.ebookDirty != true)
        #expect(harness.service.writes.value.isEmpty)

        model.record(.page(4), progress: 0.4)
        await model.flush()
        #expect(try await harness.row()?.ebookLocation == "4")
        #expect(harness.service.writes.value.map(\.update.ebookLocation) == ["4"])

        // Back at the resume point after a turn is a turn.
        model.record(.page(3), progress: 0.3)
        await model.flush()
        #expect(harness.service.writes.value.map(\.update.ebookLocation) == ["4", "3"])
    }

    /// A comic resumes at the saved page, and its turns are saved through the progress model as the
    /// 1-based lower page with the web client's `(page - 1) / pageCount` (ADR 0008 §7).
    @Test func aComicsTurnsAreSavedAsPages() async throws {
        let harness = try ProgressHarness()
        let model = ReaderContainerModelTests(fetcher: FakeEbookFetcher(body: try comicData(pages: 5)))
            .makeModel(.comic, progress: harness.makeProgressModel(kind: .comic), server: nil)
        harness.service.server.value = serverProgress("2")
        await model.load()
        guard case .comic(let url) = model.display else { throw ReaderTestFailure.notReady }
        #expect(model.resumePoint.location == .page(2))

        let comic = ComicReaderModel(
            fileURL: url, cacheDirectory: readerTemporaryDirectory(), startLocation: model.resumePoint.location
        ) { location, progress in
            model.record(location, progress: progress)
        }
        await comic.open()
        #expect(comic.state == .ready)
        #expect(comic.currentPage == 2)
        // Opening at the saved page isn't a turn.
        await model.flush()
        #expect(harness.service.writes.value.isEmpty)

        comic.turn(by: 1)
        await model.flush()
        let row = try await harness.row()
        #expect(row?.ebookLocation == "3")
        #expect(row?.ebookProgress == 0.4)
        #expect(harness.service.writes.value.map(\.update.ebookLocation) == ["3"])
        #expect(harness.service.writes.value.map(\.update.ebookProgress) == [0.4])
    }

    /// epub.js reports where it rendered the book on opening: the first page of an unread book, or
    /// the start of the page holding the saved CFI. Neither is a turn.
    @Test(arguments: [nil, "epubcfi(/6/4!/4/2/1:120)"])
    func anEPUBsOpeningLocationIsNotSaved(saved: String?) async throws {
        let harness = try ProgressHarness()
        let model = makeModel(.epub, progress: harness.makeProgressModel(kind: .epub), server: nil)
        harness.service.server.value = serverProgress(saved)
        await model.load()
        #expect(model.resumePoint.location == saved.map { .cfi($0) })

        let pageStart = EbookLocation.cfi("epubcfi(/6/4!/4/2/1:0)")
        model.recordOpening(pageStart, progress: 0.1)
        model.record(pageStart, progress: 0.1)
        await model.flush()
        #expect(model.location == pageStart)
        #expect(try await harness.row()?.ebookDirty != true)
        #expect(harness.service.writes.value.isEmpty)

        let turned = EbookLocation.cfi("epubcfi(/6/6!/4/2/1:0)")
        model.record(turned, progress: 0.2)
        // Once turned, an opening report changes nothing.
        model.recordOpening(pageStart, progress: 0.1)
        await model.flush()
        #expect(model.location == turned)
        #expect(harness.service.writes.value.map(\.update.ebookLocation) == [turned.stored])
    }
}

/// A reader restored with its window, before the session's progress seed arrived (#495).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ReaderProgressSeedTests {
    let fetcher = FakeEbookFetcher()
    let me = GatedCalls<Void, [MediaProgress]>()

    private func makeParticipant(_ store: LibraryStore) -> LibraryParticipant {
        LibraryParticipant(
            store: store, service: { _ in FakeLibraryService() },
            fetchProgress: { [me] _ in UserProgressResponse(mediaProgress: try await me.call(()), skippedRows: 0) },
            sleep: { _ in })
    }

    /// Starts a session as the lifecycle does: start, boundary, then the seed in its own task.
    private func start(_ participant: LibraryParticipant, isOffline: Bool) async throws -> Task<Void, Never> {
        let context = SessionContext(
            identity: SessionIdentity(connectionID: connection, userID: "a"),
            client: isOffline ? nil : try makeClient(),
            isOffline: isOffline, sessionID: 1)
        await participant.sessionDidStart(context)
        await participant.beginSeed(context)
        return Task { await participant.seed(context) }
    }

    private func makeModel(_ store: LibraryStore, progress: EbookProgressModel? = nil) -> ReaderContainerModel {
        ReaderContainerModel(
            request: request(), kind: .pdf,
            loader: EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher), progress: progress
        ) {
            await store.seededProgress(libraryItemID: "book")
        }
    }

    @Test func aReaderOpenedBeforeTheSeedOpensAtTheServersLocationOnceItArrives() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            let seed = try await start(makeParticipant(store), isOffline: false)
            var requests = me.calls.makeAsyncIterator()
            let request = try #require(await requests.next())
            // The snapshot a reader took here was empty.
            #expect(store.progress.progress(libraryItemID: "book") == nil)
            let model = makeModel(store)

            let load = Task { await model.load() }
            #expect(await eventually { !fetcher.calls.value.isEmpty })
            for _ in 0..<50 { await Task.yield() }
            // The file is there, but the book waits for the seed.
            #expect(model.content == .loading)

            request.reply.resume(returning: [serverProgress("5")])
            await seed.value
            await load.value

            guard case .ready = model.content else {
                Issue.record("Expected a ready file, got \(model.content)")
                return
            }
            #expect(model.resumePoint == EbookResumePoint(location: .page(5), progress: 0.5, source: .server))
            #expect(!store.isProgressSeedPending)
        }
    }

    @Test func offlineAReaderOpensAtOnceAtTheCachedLocation() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            _ = try await start(makeParticipant(store), isOffline: true)
            let harness = try ProgressHarness()
            harness.service.fetchFails.value = true
            _ = try await harness.store.recordEbookEdit(
                .init(location: "7", progress: 0.7), for: harness.key,
                token: harness.store.reserveEbookEdit(for: harness.key), now: t0)
            let model = makeModel(store, progress: harness.makeProgressModel())

            let load = Task { await model.load() }
            // Nothing to wait for offline: no seed comes.
            #expect(await eventually { model.content != .loading })
            await load.value

            #expect(model.resumePoint.location == .page(7))
            #expect(model.resumePoint.progress == 0.7)
        }
    }
}

/// A real store and syncer over ``FakeProgressServer``, as in `EbookProgressModelTests`.
@MainActor
private struct ProgressHarness {
    let key = MediaKey(serverConnectionID: connection, libraryItemId: "book")
    let store: LocalProgressStore
    let service: FakeProgressServer
    let syncer: ProgressSyncer
    let source = IdlePlaybackSource()

    init() throws {
        store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        service = FakeProgressServer(serverConnectionID: connection, store: store, now: { t0 })
        syncer = ProgressSyncer(
            source: source, service: service, store: store,
            clock: ProgressSyncClock(
                now: { t0 }, uptime: { 0 }, sleep: { _ in try await Task.sleep(for: .seconds(86_400)) }))
    }

    func makeProgressModel(kind: ReaderKind = .pdf) -> EbookProgressModel {
        EbookProgressModel(
            key: key, kind: kind, store: store, service: service, syncer: syncer, clock: ManualClock(), now: { t0 })
    }

    func row() async throws -> LocalMediaProgressDTO? {
        try await store.progress(for: key)
    }
}
