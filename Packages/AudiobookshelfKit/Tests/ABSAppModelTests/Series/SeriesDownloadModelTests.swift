import ABSAPI
import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SeriesDownloadModelTests {
    private struct Failure: Error {}
    private let connection = UUID()

    /// The series endpoints of ``FakeSeriesAuthorsService`` plus an item endpoint.
    private struct Service: SeriesAuthorsService, ItemDetailService {
        var books = FakeSeriesAuthorsService()
        var itemHandler: @Sendable (String) async throws -> LibraryItem = { SeriesAuthorsFixtures.book($0) }

        func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
            try await books.seriesPage(libraryID: libraryID, query: query)
        }
        func authorList(libraryID: String) async throws -> [Author] { try await books.authorList(libraryID: libraryID) }
        func seriesDetail(id: String) async throws -> SeriesDetailResponse { try await books.seriesDetail(id: id) }
        func authorDetail(id: String) async throws -> AuthorDetailResponse { try await books.authorDetail(id: id) }
        func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
            try await books.filteredBooksPage(libraryID: libraryID, query: query)
        }
        func item(id: String) async throws -> LibraryItem { try await itemHandler(id) }
    }

    /// Records each request and answers with ``outcome``.
    private final class Requester: DownloadRequesting {
        var requested: [(id: String, metered: Bool, connectionID: UUID)] = []
        var outcome: (String, Bool) -> DownloadRequestOutcome = { _, _ in .started(.started(UUID())) }

        func request(item: LibraryItem, episodeID: String?, connectionID: UUID) async -> DownloadRequestOutcome {
            requested.append((item.id, false, connectionID))
            return outcome(item.id, false)
        }
        func confirmMeteredDownload(
            item: LibraryItem, episodeID: String?, connectionID: UUID
        ) async -> DownloadRequestOutcome {
            requested.append((item.id, true, connectionID))
            return outcome(item.id, true)
        }
    }

    private struct Status: DownloadStatusReading {
        var ids: Set<String> = []
        func downloadedOrQueuedItemIDs(connectionID: UUID) async throws -> Set<String> { ids }
    }

    nonisolated private static func book(_ id: String, files: Int? = 2, size: Int? = 100) -> LibraryItem {
        LibraryItem(id: id, libraryId: "lib", mediaType: .book, numFiles: files, size: size)
    }

    private func model(
        books: [LibraryItem], skipping: Set<String> = [], requester: Requester, pageSize: Int = 50,
        service: Service = Service()
    ) -> SeriesDownloadModel {
        var service = service
        service.books.booksHandler = { _, query in
            let page = query.page ?? 0
            let limit = query.limit ?? books.count
            let slice = Array(books.dropFirst(page * limit).prefix(limit))
            return PagedResults(results: slice, total: books.count, limit: limit, page: page)
        }
        return SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: service,
            access: DownloadAccess(requester: requester, status: Status(ids: skipping)), permitted: { true },
            pageSize: pageSize)
    }

    @Test func queuesOnlyBooksNotDownloadedOrQueued() async {
        let requester = Requester()
        let model = model(
            books: ["a", "b", "c", "d"].map { Self.book($0) }, skipping: ["b", "d", "other"], requester: requester)
        await model.start(libraryID: "lib")
        #expect(model.prompt == .confirm(SeriesDownloadPlan(itemIDs: ["a", "c"], fileCount: 4, size: 200)))
        model.prompt = nil
        await model.confirm()
        #expect(requester.requested.map(\.id) == ["a", "c"])
        #expect(requester.requested.allSatisfy { !$0.metered && $0.connectionID == connection })
        #expect(model.prompt == nil && !model.isWorking)
    }

    @Test func pagesWithTheSeriesFilterAndNoCollapse() async {
        let queries = Recorder<LibraryQuery>()
        var service = Service()
        let books = (1...5).map { Self.book("b\($0)") }
        service.books.booksHandler = { _, query in
            await queries.append(query)
            let page = query.page ?? 0
            let limit = query.limit ?? 0
            return PagedResults(
                results: Array(books.dropFirst(page * limit).prefix(limit)), total: books.count, limit: limit,
                page: page)
        }
        let model = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: service,
            access: DownloadAccess(requester: Requester(), status: Status()), permitted: { true }, pageSize: 2)
        await model.start(libraryID: "lib")
        let sent = queries.values
        #expect(sent.map(\.page) == [0, 1, 2])
        #expect(sent.allSatisfy { $0.filter == .series(id: "ser_1") && !$0.collapseSeries && $0.limit == 2 })
        #expect(model.prompt == .confirm(SeriesDownloadPlan(itemIDs: books.map(\.id), fileCount: 10, size: 500)))
    }

    @Test func everythingDownloadedOrQueuedSaysSo() async {
        let requester = Requester()
        let model = model(books: [Self.book("a"), Self.book("b")], skipping: ["a", "b"], requester: requester)
        await model.start(libraryID: "lib")
        #expect(model.prompt == .alreadyDownloaded)
        await model.confirm()
        #expect(requester.requested.isEmpty)
    }

    @Test func meteredPathAsksOnceThenQueuesTheRest() async {
        let requester = Requester()
        requester.outcome = { _, metered in metered ? .started(.started(UUID())) : .needsConfirmation(.cellular) }
        let model = model(books: ["a", "b", "c"].map { Self.book($0) }, requester: requester)
        await model.start(libraryID: "lib")
        await model.confirm()
        #expect(model.prompt == .meteredConfirmation)
        #expect(requester.requested.map(\.id) == ["a"])
        model.prompt = nil
        await model.confirmMetered()
        #expect(requester.requested.map(\.id) == ["a", "a", "b", "c"])
        #expect(requester.requested.dropFirst().allSatisfy { $0.metered })
        #expect(model.prompt == nil)
    }

    @Test func deniedOnMeteredPathStops() async {
        let requester = Requester()
        requester.outcome = { _, _ in .denied(.cellular) }
        let model = model(books: ["a", "b"].map { Self.book($0) }, requester: requester)
        await model.start(libraryID: "lib")
        await model.confirm()
        #expect(model.prompt == .meteredDenied)
        #expect(requester.requested.map(\.id) == ["a"])
        await model.confirmMetered()
        #expect(requester.requested.count == 1)
    }

    @Test func countsBooksThatCouldNotBeQueued() async {
        let requester = Requester()
        requester.outcome = { id, _ in id == "c" ? .failed(.noDownloadableMedia) : .started(.started(UUID())) }
        var service = Service()
        service.itemHandler = { id in
            if id == "b" { throw Failure() }
            return Self.book(id)
        }
        let model = model(books: ["a", "b", "c", "d"].map { Self.book($0) }, requester: requester, service: service)
        await model.start(libraryID: "lib")
        await model.confirm()
        #expect(requester.requested.map(\.id) == ["a", "c", "d"])
        #expect(model.prompt == .queueFailed(count: 2))
    }

    @Test func listingFailureAndSignOutPrompt() async {
        var failing = Service()
        failing.books.booksHandler = { _, _ in throw Failure() }
        let failed = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: failing,
            access: DownloadAccess(requester: Requester(), status: Status()), permitted: { true })
        await failed.start(libraryID: "lib")
        #expect(failed.prompt == .loadFailed)

        // Signed out or switched account: the services throw CancellationError, and nothing is said.
        var signedOut = Service()
        signedOut.books.booksHandler = { _, _ in throw CancellationError() }
        let cancelled = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: signedOut,
            access: DownloadAccess(requester: Requester(), status: Status()), permitted: { true })
        await cancelled.start(libraryID: "lib")
        #expect(cancelled.prompt == nil && !cancelled.isWorking)
    }

    @Test func signOutWhileQueueingStopsWithoutPrompt() async {
        let requester = Requester()
        var service = Service()
        service.itemHandler = { id in
            if id == "b" { throw CancellationError() }
            return Self.book(id)
        }
        let model = model(books: ["a", "b", "c"].map { Self.book($0) }, requester: requester, service: service)
        await model.start(libraryID: "lib")
        model.prompt = nil
        await model.confirm()
        #expect(requester.requested.map(\.id) == ["a"])
        #expect(model.prompt == nil)
    }

    @Test func availabilityNeedsDownloadsAnAccountAndPermission() {
        let id = UUID()
        func availability(_ connectionID: UUID?, _ hasDownloads: Bool, _ canDownload: Bool = true)
            -> SeriesDownloadAvailability
        {
            SeriesDownloadAvailability(connectionID: connectionID, hasDownloads: hasDownloads, canDownload: canDownload)
        }
        #expect(availability(id, true) == .available(connectionID: id))
        #expect(availability(id, true, false) == .notPermitted)
        #expect(availability(id, true, false).connectionID == nil)
        #expect(availability(nil, true) == .signedOut)
        #expect(availability(id, false) == .unsupported)
        #expect(availability(nil, false) == .unsupported)
        #expect(availability(nil, true).connectionID == nil)
        #expect(availability(id, false).connectionID == nil)
    }

    @Test func withoutPermissionNothingIsListedOrQueued() async {
        let requester = Requester()
        let listed = Recorder<LibraryQuery>()
        var permitted = false
        var service = Service()
        service.books.booksHandler = { _, query in
            await listed.append(query)
            return PagedResults(results: [Self.book("a")], total: 1, limit: 50, page: 0)
        }
        let model = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: service,
            access: DownloadAccess(requester: requester, status: Status()), permitted: { permitted })
        await model.start(libraryID: "lib")
        #expect(listed.values.isEmpty && model.prompt == nil)
        permitted = true
        await model.start(libraryID: "lib")
        permitted = false  // revoked while the user decided
        await model.confirm()
        #expect(requester.requested.isEmpty)
    }

    @Test func overflowingCountsAndSizesSaturate() {
        let books = [Self.book("a", files: .max, size: .max), Self.book("b", files: 1, size: 1)]
        let plan = SeriesDownloadPlan(books: books + [Self.book("c", files: -5, size: -5)], skipping: [])
        #expect(plan.fileCount == .max && plan.size == .max)
        #expect(
            SeriesDownloadPlan(
                books: [Self.book("n", files: -5, size: -5), Self.book("m", files: nil, size: nil)], skipping: [])
                == SeriesDownloadPlan(itemIDs: ["n", "m"], fileCount: 0, size: 0))
    }

    @Test func listingStopsAtAPageWithNoNewBooks() async {
        let queries = Recorder<LibraryQuery>()
        var service = Service()
        // Claims a huge series but keeps returning the same full page.
        service.books.booksHandler = { _, query in
            await queries.append(query)
            return PagedResults(
                results: [Self.book("a"), Self.book("b")], total: 1_000_000, limit: 2, page: query.page ?? 0)
        }
        let model = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: service,
            access: DownloadAccess(requester: Requester(), status: Status()), permitted: { true }, pageSize: 2)
        await model.start(libraryID: "lib")
        #expect(queries.values.count == 2)
        #expect(model.prompt == .confirm(SeriesDownloadPlan(itemIDs: ["a", "b"], fileCount: 4, size: 200)))
    }

    @Test func listingPastTheCapFails() async {
        let queries = Recorder<LibraryQuery>()
        var service = Service()
        // Claims a huge series of distinct books.
        service.books.booksHandler = { _, query in
            await queries.append(query)
            let page = query.page ?? 0
            return PagedResults(
                results: [Self.book("x\(page * 2)"), Self.book("x\(page * 2 + 1)")], total: 1_000_000, limit: 2,
                page: page)
        }
        let model = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: service,
            access: DownloadAccess(requester: Requester(), status: Status()), permitted: { true }, pageSize: 2,
            maxBooks: 5)
        await model.start(libraryID: "lib")
        #expect(queries.values.count == 3)
        #expect(model.prompt == .loadFailed)
    }

    @Test func cancellingTheListingSaysNothing() async {
        let (started, began) = AsyncStream.makeStream(of: Void.self)
        var service = Service()
        // URLSession reports a cancelled request as `URLError.cancelled`, not `CancellationError`.
        service.books.booksHandler = { _, _ in
            began.yield()
            try? await Task.sleep(for: .seconds(30))
            throw URLError(.cancelled)
        }
        let model = SeriesDownloadModel(
            seriesID: "ser_1", connectionID: connection, service: service,
            access: DownloadAccess(requester: Requester(), status: Status()), permitted: { true })
        let task = Task { await model.start(libraryID: "lib") }
        for await _ in started { break }
        task.cancel()
        await task.value
        #expect(model.prompt == nil && !model.isWorking)
    }

    /// Through the real stores: downloaded books and book records count; cover-only and episode
    /// records, and other connections' items, don't.
    @Test func storedStatusReadsDownloadsAndRecordsOfTheConnection() async throws {
        let container = try DataStack(location: .inMemory).container
        let connections = ServerConnectionStore(modelContainer: container)
        let mine = try await connections.upsertLogin(
            address: try #require(ServerAddress("https://abs.example.com")), userId: "usr_1", username: "user",
            authMethod: .local, serverVersion: nil)
        let other = try await connections.upsertLogin(
            address: try #require(ServerAddress("https://other.example.com")), userId: "usr_2", username: "user",
            authMethod: .local, serverVersion: nil)
        let localItems = LocalItemStore(modelContainer: container)
        let records = DownloadStore(modelContainer: container)

        func record(_ id: String, _ connection: UUID, episode: String? = nil, kind: DownloadPartKind = .audio)
            -> DownloadRecordDTO
        {
            let part = DownloadPartDTO(
                kind: kind, serverPath: "/api/items/\(id)/file", filename: "a.mp3", mimeType: "audio/mpeg",
                destinationRelativePath: "\(id)/a.mp3", state: .completed)
            return DownloadRecordDTO(
                key: MediaKey(serverConnectionID: connection, libraryItemId: id, episodeId: episode),
                mediaType: episode == nil ? .book : .podcast, title: id, relativeDirectory: id,
                media: LocalMediaSnapshot(metadata: .init(title: id)), parts: [part])
        }
        try await localItems.upsertFromDownload(record("downloaded", mine.id))
        try await localItems.upsertFromDownload(record("elsewhere", other.id))
        try await records.upsertRecord(record("queued", mine.id))
        try await records.upsertRecord(record("cover", mine.id, kind: .cover))
        try await records.upsertRecord(record("pod", mine.id, episode: "ep_1"))
        try await records.upsertRecord(record("queuedElsewhere", other.id))

        let status = StoredDownloadStatus(localItems: localItems, records: records)
        let ids = try await status.downloadedOrQueuedItemIDs(connectionID: mine.id)
        #expect(ids == ["downloaded", "queued"])
    }
}
