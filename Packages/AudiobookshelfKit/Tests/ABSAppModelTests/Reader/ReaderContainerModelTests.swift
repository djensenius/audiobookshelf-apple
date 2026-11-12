import ABSAPI
import ABSCore
import Foundation
import SwiftData
import Testing

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

@MainActor
@Suite struct ReaderContainerModelTests {
    let fetcher = FakeEbookFetcher()

    func makeModel(
        _ kind: ReaderKind = .pdf, progress: EbookProgressModel? = nil, server: MediaProgress? = nil
    ) -> ReaderContainerModel {
        ReaderContainerModel(
            request: request(ext: kind == .epub ? "epub" : "pdf"), kind: kind,
            loader: EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher), progress: progress,
            serverProgress: server)
    }

    @Test func unsupportedFormatsFetchNothing() async {
        for (kind, name) in [(ReaderKind.comic, "CBZ"), (.unsupported(.mobi), "MOBI"), (.unsupported(.cbr), "CBR")] {
            let model = makeModel(kind)
            await model.load()
            #expect(model.content == .unsupported)
            #expect(model.formatName == name)
        }
        #expect(fetcher.calls.value.isEmpty)
        #expect(ReaderContainerModel.opens(.epub))
        #expect(ReaderContainerModel.opens(.pdf))
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
