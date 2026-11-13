import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

/// A path source that reports one path as soon as it is monitored.
private struct OnePathSource: NetworkPathSource {
    let path: NetworkPath

    func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in continuation.yield(path) }
    }
}

/// A ``DownloadControlling`` that records its calls and can be told to fail.
private actor FakeControl: DownloadControlling {
    private(set) var cancels: [UUID] = []
    private(set) var retries: [UUID] = []
    private(set) var deletedItems: [UUID] = []
    private(set) var deletedEpisodes: [String] = []
    private var failure: DownloadManagerError?
    private var subscribers: [AsyncStream<DownloadManagerEvent>.Continuation] = []

    func fail(with error: DownloadManagerError?) {
        failure = error
    }

    func events() -> AsyncStream<DownloadManagerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadManagerEvent.self)
        subscribers.append(continuation)
        return stream
    }

    func send(_ event: DownloadManagerEvent) {
        for subscriber in subscribers { subscriber.yield(event) }
    }

    func enqueue(
        item: LibraryItem, episodeID: String?, connectionID: UUID, replacingExisting: Bool
    ) async throws(DownloadManagerError) -> DownloadManager.EnqueueResult {
        .started(UUID())
    }

    func restartActiveTransfers() async throws(DownloadManagerError) {}

    func cancel(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        if let failure { throw failure }
        cancels.append(recordID)
        return true
    }

    func retry(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        if let failure { throw failure }
        retries.append(recordID)
        return true
    }

    func deleteLocalItem(id: UUID) async throws(DownloadManagerError) -> Bool {
        if let failure { throw failure }
        deletedItems.append(id)
        return true
    }

    func deleteEpisode(itemID: UUID, episodeId: String) async throws(DownloadManagerError) -> Bool {
        if let failure { throw failure }
        deletedEpisodes.append(episodeId)
        return true
    }
}

/// The items a test hands to the model, and how often they were read.
private actor ItemSource {
    private(set) var reads = 0
    var items: [LocalLibraryItemDTO] = []

    func set(_ items: [LocalLibraryItemDTO]) {
        self.items = items
    }

    func read(_ connectionID: UUID) -> [LocalLibraryItemDTO] {
        reads += 1
        return items.filter { $0.serverConnectionID == connectionID }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DownloadsTabModelTests {
    static let connection = DownloadsListingTests.connection

    /// A started model over `control`, observing ``connection`` until `cleanUp`; returns after
    /// the first read.
    private func makeModel(
        path: NetworkPath = .wifi, policy: CellularPolicy = .always, control: FakeControl = FakeControl(),
        source: ItemSource = ItemSource(), records: [DownloadRecordDTO] = []
    ) async throws -> (DownloadsTabModel, cleanUp: () -> Void) {
        let suiteName = "ABSAppModelTests.DownloadsTab.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.downloadUsingCellular = policy
        let monitor = NetworkMonitor(source: OnePathSource(path: path))
        monitor.start()
        let controller = DownloadsController(
            manager: control, monitor: monitor, settings: settings,
            networkAccess: DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: false),
            storedRecords: { records }, pathTimeout: .seconds(30))
        await controller.start()
        let model = DownloadsTabModel(
            services: DownloadsServices(
                controller: controller, control: control, localItems: { await source.read($0) },
                availableCapacity: { 1_000 }))
        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        model.reloaded = { report.yield() }
        let observing = Task { await model.observe(connectionID: Self.connection) }
        for await _ in reloads { break }
        model.reloaded = nil
        return (
            model,
            {
                observing.cancel(); defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    @Test func observingReadsTheItemsAndAgainAfterACompletion() async throws {
        let control = FakeControl()
        let source = ItemSource()
        await source.set([DownloadsListingTests.item("Walden")])
        let (model, cleanUp) = try await makeModel(control: control, source: source)
        defer { cleanUp() }
        #expect(model.isLoaded)
        #expect(model.listing.books.map(\.title) == ["Walden"])
        #expect(model.availableBytes == 1_000)

        await source.set([DownloadsListingTests.item("Walden"), DownloadsListingTests.item("Emma")])
        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        model.reloaded = { report.yield() }
        await control.send(
            .completed(
                recordID: UUID(), itemID: UUID(), key: MediaKey(serverConnectionID: Self.connection, libraryItemId: "x")
            ))
        for await _ in reloads { break }

        #expect(await source.reads == 2)
        #expect(model.listing.books.map(\.title) == ["Emma", "Walden"])
    }

    @Test func cancelAllCancelsEachDownloadOfTheConnectionOldestFirst() async throws {
        let control = FakeControl()
        let first = DownloadRecordDTO(
            key: MediaKey(serverConnectionID: Self.connection, libraryItemId: "a"), mediaType: .book, title: "A",
            relativeDirectory: "a", createdAt: Date(timeIntervalSince1970: 1), media: .init(metadata: .init(title: "A"))
        )
        let second = DownloadRecordDTO(
            key: MediaKey(serverConnectionID: Self.connection, libraryItemId: "b"), mediaType: .book, title: "B",
            relativeDirectory: "b", createdAt: Date(timeIntervalSince1970: 2), media: .init(metadata: .init(title: "B"))
        )
        let elsewhere = DownloadRecordDTO(
            key: MediaKey(serverConnectionID: UUID(), libraryItemId: "c"), mediaType: .book, title: "C",
            relativeDirectory: "c", media: .init(metadata: .init(title: "C")))
        let (model, cleanUp) = try await makeModel(control: control, records: [second, elsewhere, first])
        defer { cleanUp() }

        await model.cancelAll()

        #expect(await control.cancels == [first.id, second.id])
        #expect(model.notice == nil)
        #expect(model.busy.isEmpty)
    }

    @Test func aFailedCancelShowsANotice() async throws {
        let control = FakeControl()
        await control.fail(with: .storeFailure)
        let (model, cleanUp) = try await makeModel(control: control)
        defer { cleanUp() }

        await model.cancel(recordID: UUID())

        #expect(model.notice == .cancelFailed)
        #expect(model.busy.isEmpty)
    }

    @Test func retryRunsWhenThePolicyAllowsIt() async throws {
        let control = FakeControl()
        let (model, cleanUp) = try await makeModel(path: .cellular, policy: .always, control: control)
        defer { cleanUp() }
        let id = UUID()

        await model.retry(recordID: id)

        #expect(await control.retries == [id])
        #expect(model.notice == nil)
    }

    @Test func retryOnCellularAsksFirstWhenThePolicySaysAsk() async throws {
        let control = FakeControl()
        let (model, cleanUp) = try await makeModel(path: .cellular, policy: .ask, control: control)
        defer { cleanUp() }
        let id = UUID()

        await model.retry(recordID: id)
        #expect(model.notice == .confirmMeteredRetry(id))
        #expect(await control.retries.isEmpty)

        await model.confirmMeteredRetry(recordID: id)
        #expect(await control.retries == [id])
    }

    @Test func retryOnCellularIsDeniedWhenThePolicySaysNever() async throws {
        let control = FakeControl()
        let (model, cleanUp) = try await makeModel(path: .cellular, policy: .never, control: control)
        defer { cleanUp() }

        await model.retry(recordID: UUID())

        #expect(model.notice == .retryDenied)
        #expect(await control.retries.isEmpty)
    }

    @Test func deletingReadsTheItemsAgain() async throws {
        let control = FakeControl()
        let source = ItemSource()
        let podcast = DownloadsListingTests.item("Radio", mediaType: .podcast)
        await source.set([podcast])
        let (model, cleanUp) = try await makeModel(control: control, source: source)
        defer { cleanUp() }

        await source.set([])
        await model.deleteEpisode(itemID: podcast.id, episodeId: "e1")
        #expect(await control.deletedEpisodes == ["e1"])
        #expect(model.listing.podcasts.isEmpty)

        await model.delete(itemID: podcast.id)
        #expect(await control.deletedItems == [podcast.id])
        #expect(await source.reads == 3)
    }

    @Test func aFailedDeleteShowsANotice() async throws {
        let control = FakeControl()
        await control.fail(with: .storeFailure)
        let (model, cleanUp) = try await makeModel(control: control)
        defer { cleanUp() }

        await model.delete(itemID: UUID())

        #expect(model.notice == .deleteFailed)
    }
}
