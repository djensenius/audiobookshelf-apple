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
    private var subscribers: [AsyncStream<[LocalLibraryItemDTO]>.Continuation] = []

    /// Sets the items, as a write to the store would, and sends them to ``updates(_:)``.
    func set(_ items: [LocalLibraryItemDTO]) {
        self.items = items
        for subscriber in subscribers { subscriber.yield(items) }
    }

    func read(_ connectionID: UUID) -> [LocalLibraryItemDTO] {
        reads += 1
        return items.filter { $0.serverConnectionID == connectionID }
    }

    /// Like `LocalItemStore.updates(serverConnectionID:)`: the items now, then after each ``set(_:)``.
    func updates(_ connectionID: UUID) -> AsyncStream<[LocalLibraryItemDTO]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [LocalLibraryItemDTO].self, bufferingPolicy: .bufferingNewest(1))
        subscribers.append(continuation)
        continuation.yield(items)
        return stream
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DownloadsTabModelTests {
    static let connection = DownloadsListingTests.connection

    /// A started model over `control`, observing ``connection`` until `cleanUp`; returns after
    /// the first read. With `followsUpdates`, it reads `source` again after each of its writes.
    private func makeModel(
        path: NetworkPath = .wifi, policy: CellularPolicy = .always, control: FakeControl = FakeControl(),
        source: ItemSource = ItemSource(), followsUpdates: Bool = false, records: [DownloadRecordDTO] = [],
        storedRecords: (@Sendable () async throws -> [DownloadRecordDTO])? = nil
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
            storedRecords: storedRecords ?? { records }, pathTimeout: .seconds(30))
        await controller.start()
        let updates: (@Sendable (UUID) async throws -> AsyncStream<[LocalLibraryItemDTO]>)? =
            followsUpdates ? { @Sendable connectionID in await source.updates(connectionID) } : nil
        let model = DownloadsTabModel(
            services: DownloadsServices(
                controller: controller, control: control, localItemUpdates: updates,
                localItems: { await source.read($0) }, availableCapacity: { 1_000 }))
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

    /// When the stored downloads under way can't be read, the model says so instead of listing
    /// no downloads, and ``DownloadsTabModel/reload()`` reads them again until a read succeeds.
    /// The negative control: before that read, the queued download is missing.
    @Test func aFailedQueueReadIsShownAndReloadReadsItAgain() async throws {
        let queued = DownloadsListingTests.record("Queued", state: .queued)
        let reads = Locked(0)
        let failing = Locked(true)
        let (model, cleanUp) = try await makeModel(storedRecords: {
            reads.value += 1
            if failing.value { throw CocoaError(.fileReadUnknown) }
            return [queued]
        })
        defer { cleanUp() }

        // Two reads at start, and two more at the first reload.
        #expect(reads.value == 4)
        #expect((model.queueLoadError as? CocoaError)?.code == .fileReadUnknown)
        #expect(model.listing.downloads.isEmpty)

        failing.value = false
        await model.reload()
        #expect(reads.value == 5)
        #expect(model.queueLoadError == nil)
        #expect(model.listing.downloads.map(\.id) == [queued.id])

        await model.reload()
        #expect(reads.value == 5)
    }

    /// Each window has its own model; one following the store's updates reads the items again
    /// after a deletion in another window, which writes to the store. The negative control: a
    /// model without them keeps listing the deleted item.
    @Test func aDeletionInAnotherWindowIsReadByEveryModelFollowingTheStore() async throws {
        let source = ItemSource()
        let walden = DownloadsListingTests.item("Walden", files: [DownloadsListingTests.file(size: 100)])
        await source.set([walden])
        let (following, cleanUpFollowing) = try await makeModel(source: source, followsUpdates: true)
        defer { cleanUpFollowing() }
        let (unfollowing, cleanUpUnfollowing) = try await makeModel(source: source)
        defer { cleanUpUnfollowing() }
        #expect(following.listing.downloadedBytes == 100)

        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        following.reloaded = { report.yield() }
        // Another window's model deletes the item through the manager, which writes the store.
        await source.set([])
        for await _ in reloads { break }

        #expect(following.listing.books.isEmpty)
        #expect(following.listing.downloadedBytes == 0)
        #expect(unfollowing.listing.books.map(\.title) == ["Walden"])
    }
}
