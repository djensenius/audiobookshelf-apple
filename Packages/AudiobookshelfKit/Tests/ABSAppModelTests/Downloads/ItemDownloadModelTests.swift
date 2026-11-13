import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ItemDownloadModelTests {
    static let connection = DownloadsListingTests.connection
    static let bookID = "li-Walden"
    private static let ticket = DownloadRequestTicket(connectionID: connection, sessionID: 3, generation: 5)

    /// A path source that reports one path as soon as it is monitored.
    private struct OnePathSource: NetworkPathSource {
        func paths() -> AsyncStream<NetworkPath> {
            AsyncStream { continuation in continuation.yield(.wifi) }
        }
    }

    /// Records each request and answers with ``outcome``; ``canDownload`` answers `canRequest`.
    private final class Requester: DownloadRequesting {
        var requested: [(id: String, episodeID: String?, connectionID: UUID)] = []
        var tickets: [DownloadRequestTicket] = []
        var canDownload = true
        var outcome: DownloadRequestOutcome = .started(.started(UUID()))
        var meteredOutcome: DownloadRequestOutcome = .started(.started(UUID()))

        func request(item: LibraryItem, episodeID: String?, connectionID: UUID) async -> DownloadRequestOutcome {
            requested.append((item.id, episodeID, connectionID))
            return outcome
        }
        func confirmMeteredDownload(
            item: LibraryItem, episodeID: String?, ticket: DownloadRequestTicket
        ) async -> DownloadRequestOutcome {
            tickets.append(ticket)
            return meteredOutcome
        }
        func canRequest(connectionID: UUID) -> Bool { canDownload }
    }

    private struct Status: DownloadStatusReading {
        func downloadedOrQueuedItemIDs(connectionID: UUID) async throws -> Set<String> { [] }
    }

    /// A ``DownloadControlling`` that records its calls and can be told to fail.
    private actor FakeControl: DownloadControlling {
        private(set) var cancels: [UUID] = []
        private(set) var deletedItems: [UUID] = []
        private(set) var deletedEpisodes: [String] = []
        private var failure: DownloadManagerError?
        private var subscribers: [AsyncStream<DownloadManagerEvent>.Continuation] = []

        func fail(with error: DownloadManagerError?) { failure = error }

        func events() -> AsyncStream<DownloadManagerEvent> {
            let (stream, continuation) = AsyncStream.makeStream(of: DownloadManagerEvent.self)
            subscribers.append(continuation)
            return stream
        }

        func send(_ event: DownloadManagerEvent) {
            for subscriber in subscribers { subscriber.yield(event) }
        }

        func enqueue(
            item: LibraryItem, episodeID: String?, connectionID: UUID, replacingExisting: Bool,
            unlessQuiescedSince generation: Int?
        ) async throws(DownloadManagerError) -> DownloadManager.EnqueueResult { .started(UUID()) }
        func quiesceGeneration() async -> Int { 0 }
        func restartActiveTransfers() async throws(DownloadManagerError) {}
        func cancel(recordID: UUID) async throws(DownloadManagerError) -> Bool {
            if let failure { throw failure }
            cancels.append(recordID)
            return true
        }
        func retry(recordID: UUID) async throws(DownloadManagerError) -> Bool { true }
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

    /// The stored local items, and their update stream.
    private actor ItemSource {
        private(set) var reads = 0
        private var items: [LocalLibraryItemDTO] = []
        private var subscribers: [AsyncStream<[LocalLibraryItemDTO]>.Continuation] = []

        init(_ items: [LocalLibraryItemDTO] = []) { self.items = items }

        func set(_ items: [LocalLibraryItemDTO]) {
            self.items = items
            for subscriber in subscribers { subscriber.yield(items) }
        }

        func read(_ connectionID: UUID) -> [LocalLibraryItemDTO] {
            reads += 1
            return items.filter { $0.serverConnectionID == connectionID }
        }

        func updates(_ connectionID: UUID) -> AsyncStream<[LocalLibraryItemDTO]> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: [LocalLibraryItemDTO].self, bufferingPolicy: .bufferingNewest(1))
            subscribers.append(continuation)
            continuation.yield(items)
            return stream
        }
    }

    private struct Harness {
        let model: ItemDownloadModel
        let controller: DownloadsController
        let requester: Requester
        let control: FakeControl
        let source: ItemSource
        let cleanUp: () -> Void
    }

    /// A model observing `source` (with store updates when `followsUpdates`), returned after its
    /// first read, over a started controller holding `records`.
    private func makeHarness(
        episodeID: String? = nil, records: [DownloadRecordDTO] = [], items: [LocalLibraryItemDTO] = [],
        followsUpdates: Bool = true, requester: Requester = Requester(), control: FakeControl = FakeControl()
    ) async throws -> Harness {
        let suiteName = "ABSAppModelTests.ItemDownload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let monitor = NetworkMonitor(source: OnePathSource())
        monitor.start()
        let controller = DownloadsController(
            manager: control, monitor: monitor, settings: AppSettings(defaults: defaults),
            networkAccess: DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: false),
            storedRecords: { records }, sessions: { _ in nil })
        await controller.start()
        let source = ItemSource(items)
        let updates: (@Sendable (UUID) async throws -> AsyncStream<[LocalLibraryItemDTO]>)? =
            followsUpdates ? { @Sendable connectionID in await source.updates(connectionID) } : nil
        let services = DownloadsServices(
            controller: controller, control: control, localItemUpdates: updates,
            localItems: { await source.read($0) }, availableCapacity: { 0 })
        let model = ItemDownloadModel(
            libraryItemID: Self.bookID, episodeID: episodeID, connectionID: Self.connection,
            access: DownloadAccess(requester: requester, status: Status()), services: services)
        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        model.reloaded = { report.yield() }
        let observing = Task { await model.observe() }
        for await _ in reloads { break }
        model.reloaded = nil
        return Harness(
            model: model, controller: controller, requester: requester, control: control, source: source,
            cleanUp: {
                observing.cancel()
                defaults.removePersistentDomain(forName: suiteName)
            })
    }

    private static let item = LibraryItem(id: bookID, libraryId: "lib", mediaType: .book)

    private static func downloaded(id: UUID = UUID(), episodeId: String? = nil) -> LocalLibraryItemDTO {
        DownloadsListingTests.item(
            "Walden", mediaType: episodeId == nil ? .book : .podcast, id: id,
            files: [DownloadsListingTests.file(size: 10, episodeId: episodeId)])
    }

    // MARK: - Requests

    @Test func downloadRequestsTheItemOnItsConnection() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        #expect(harness.model.state == .none)

        await harness.model.download(item: Self.item)

        #expect(harness.requester.requested.map(\.id) == [Self.bookID])
        #expect(harness.requester.requested.first?.episodeID == nil)
        #expect(harness.requester.requested.first?.connectionID == Self.connection)
        #expect(harness.model.prompt == nil)
        #expect(!harness.model.isWorking)
    }

    @Test func nothingIsRequestedWithoutPermissionOrForAnotherItem() async throws {
        let requester = Requester()
        requester.canDownload = false
        let harness = try await makeHarness(requester: requester)
        defer { harness.cleanUp() }
        #expect(!harness.model.canRequest)

        await harness.model.download(item: Self.item)
        requester.canDownload = true
        await harness.model.download(item: LibraryItem(id: "li-Emma", libraryId: "lib", mediaType: .book))

        #expect(requester.requested.isEmpty)
    }

    @Test func aMeteredPathAsksThenQueuesWithTheRequestsTicket() async throws {
        let requester = Requester()
        requester.outcome = .needsConfirmation(.cellular, Self.ticket)
        let harness = try await makeHarness(requester: requester)
        defer { harness.cleanUp() }

        await harness.model.download(item: Self.item)
        #expect(harness.model.prompt == .meteredConfirmation)
        #expect(requester.tickets.isEmpty)

        harness.model.prompt = nil
        await harness.model.confirmMetered()
        #expect(requester.tickets == [Self.ticket])
        // The confirmation is used once.
        await harness.model.confirmMetered()
        #expect(requester.tickets.count == 1)
    }

    @Test func aDismissedMeteredPromptQueuesNothing() async throws {
        let requester = Requester()
        requester.outcome = .needsConfirmation(.cellular, Self.ticket)
        let harness = try await makeHarness(requester: requester)
        defer { harness.cleanUp() }

        await harness.model.download(item: Self.item)
        harness.model.dismissMetered()
        await harness.model.confirmMetered()

        #expect(requester.tickets.isEmpty)
    }

    @Test(
        arguments: [
            (DownloadRequestOutcome.denied(.cellular), ItemDownloadModel.Prompt?.some(.meteredDenied)),
            (.failed(.insufficientStorage(required: 10, available: 1)), .notEnoughSpace),
            (.failed(.storeFailure), .startFailed),
            (.rejected(.sessionEnded), nil),
            (.rejected(.notPermitted), nil),
        ])
    func outcomesSetTheirPrompt(outcome: DownloadRequestOutcome, prompt: ItemDownloadModel.Prompt?) async throws {
        let requester = Requester()
        requester.outcome = outcome
        let harness = try await makeHarness(requester: requester)
        defer { harness.cleanUp() }

        await harness.model.download(item: Self.item)

        #expect(harness.model.prompt == prompt)
    }

    @Test func aDownloadUnderWayIsntRequestedAgainButAFailedOneIsRetried() async throws {
        let queued = DownloadsListingTests.record("Walden", state: .queued)
        let busy = try await makeHarness(records: [queued])
        defer { busy.cleanUp() }
        #expect(busy.model.state == .queued(recordID: queued.id))
        await busy.model.download(item: Self.item)
        #expect(busy.requester.requested.isEmpty)

        let failed = DownloadsListingTests.record("Walden", state: .failed)
        let retry = try await makeHarness(records: [failed])
        defer { retry.cleanUp() }
        #expect(retry.model.state == .failed(recordID: failed.id))
        await retry.model.download(item: Self.item)
        #expect(retry.requester.requested.map(\.id) == [Self.bookID])
    }

    // MARK: - State

    @Test func theStateFollowsProgressAndCompletion() async throws {
        let record = DownloadsListingTests.record("Walden", state: .downloading)
        let harness = try await makeHarness(records: [record])
        defer { harness.cleanUp() }

        let (handled, report) = AsyncStream.makeStream(of: Void.self)
        var events = handled.makeAsyncIterator()
        harness.controller.eventHandled = { _ in report.yield() }
        await harness.control.send(.progress(recordID: record.id, fraction: 0.4, bytes: 40))
        await events.next()
        #expect(harness.model.state == .downloading(recordID: record.id, fraction: 0.4))

        let local = Self.downloaded()
        let (reloads, reloaded) = AsyncStream.makeStream(of: Void.self)
        harness.model.reloaded = { reloaded.yield() }
        await harness.control.send(
            .completed(
                recordID: record.id, itemID: local.id,
                key: MediaKey(serverConnectionID: Self.connection, libraryItemId: Self.bookID)))
        await events.next()
        #expect(harness.model.state == .none)
        await harness.source.set([local])
        for await _ in reloads { break }
        #expect(harness.model.state == .downloaded(localItemID: local.id))
    }

    @Test func withoutStoreUpdatesACompletionReadsTheItemsAgain() async throws {
        let harness = try await makeHarness(followsUpdates: false)
        defer { harness.cleanUp() }
        let local = Self.downloaded()
        await harness.source.set([local])

        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        harness.model.reloaded = { report.yield() }
        await harness.control.send(
            .completed(
                recordID: UUID(), itemID: local.id,
                key: MediaKey(serverConnectionID: Self.connection, libraryItemId: Self.bookID)))
        for await _ in reloads { break }

        #expect(await harness.source.reads == 2)
        #expect(harness.model.state == .downloaded(localItemID: local.id))
    }

    // MARK: - Cancel and delete

    @Test func cancelRemovesTheDownloadUnderWay() async throws {
        let record = DownloadsListingTests.record("Walden", state: .downloading)
        let harness = try await makeHarness(records: [record])
        defer { harness.cleanUp() }

        await harness.model.cancel()
        #expect(await harness.control.cancels == [record.id])
        #expect(harness.model.prompt == nil)

        await harness.control.fail(with: .storeFailure)
        await harness.model.cancel()
        #expect(harness.model.prompt == .cancelFailed)
    }

    @Test func cancelDoesNothingWithoutADownload() async throws {
        let harness = try await makeHarness(items: [Self.downloaded()])
        defer { harness.cleanUp() }

        await harness.model.cancel()

        #expect(await harness.control.cancels.isEmpty)
    }

    @Test func deleteRemovesTheDownloadedBook() async throws {
        let id = UUID()
        let harness = try await makeHarness(items: [Self.downloaded(id: id)])
        defer { harness.cleanUp() }
        #expect(harness.model.state == .downloaded(localItemID: id))

        await harness.model.delete()

        #expect(await harness.control.deletedItems == [id])
        #expect(await harness.control.deletedEpisodes.isEmpty)
        #expect(harness.model.prompt == nil)
    }

    @Test func aFailedDeleteShowsAPrompt() async throws {
        let control = FakeControl()
        await control.fail(with: .storeFailure)
        let harness = try await makeHarness(items: [Self.downloaded()], control: control)
        defer { harness.cleanUp() }

        await harness.model.delete()

        #expect(harness.model.prompt == .deleteFailed)
    }

    @Test func deleteRemovesOnlyTheEpisode() async throws {
        let id = UUID()
        let harness = try await makeHarness(episodeID: "ep-1", items: [Self.downloaded(id: id, episodeId: "ep-1")])
        defer { harness.cleanUp() }
        #expect(harness.model.state == .downloaded(localItemID: id))

        await harness.model.delete()

        #expect(await harness.control.deletedEpisodes == ["ep-1"])
        #expect(await harness.control.deletedItems.isEmpty)
    }
}
