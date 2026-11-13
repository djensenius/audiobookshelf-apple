import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

/// A path source that reports one path as soon as it is monitored.
private struct WifiPathSource: NetworkPathSource {
    func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in continuation.yield(.wifi) }
    }
}

/// A store and ``DownloadControlling`` in one: deletes remove from the stored item, like the
/// manager's deletion does, and can be told to fail.
private actor FakeLocalStore: DownloadControlling {
    private(set) var item: LocalLibraryItemDTO?
    private(set) var reads = 0
    private var failure: DownloadManagerError?
    private var subscribers: [AsyncStream<DownloadManagerEvent>.Continuation] = []

    init(item: LocalLibraryItemDTO?) {
        self.item = item
    }

    func set(_ item: LocalLibraryItemDTO?) {
        self.item = item
    }

    func fail(with error: DownloadManagerError?) {
        failure = error
    }

    func read(_ id: UUID) -> LocalLibraryItemDTO? {
        reads += 1
        return item?.id == id ? item : nil
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

    func cancel(recordID: UUID) async throws(DownloadManagerError) -> Bool { false }

    func retry(recordID: UUID) async throws(DownloadManagerError) -> Bool { false }

    func deleteLocalItem(id: UUID) async throws(DownloadManagerError) -> Bool {
        if let failure { throw failure }
        guard item?.id == id else { return false }
        item = nil
        return true
    }

    func deleteEpisode(itemID: UUID, episodeId: String) async throws(DownloadManagerError) -> Bool {
        if let failure { throw failure }
        guard var current = item, current.id == itemID else { return false }
        current.files.removeAll { $0.episodeId == episodeId }
        current.media.episodes.removeAll { $0.id == episodeId }
        item = current.files.isEmpty ? nil : current
        return true
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalItemDetailModelTests {
    static func podcast(episodes: [String]) -> LocalLibraryItemDTO {
        LocalItemDetailTests.item(
            mediaType: .podcast,
            media: LocalMediaSnapshot(
                metadata: .init(title: "Radio"), episodes: episodes.map { .init(id: $0, title: $0.uppercased()) }),
            files: episodes.map { LocalItemDetailTests.file("\($0).mp3", size: 10, episodeId: $0) })
    }

    /// A model observing `store`'s item until `cleanUp`; returns after the first read.
    private func makeModel(
        store: FakeLocalStore, itemID: UUID
    ) async throws -> (LocalItemDetailModel, cleanUp: () -> Void) {
        let suiteName = "ABSAppModelTests.LocalItemDetail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let monitor = NetworkMonitor(source: WifiPathSource())
        let controller = DownloadsController(
            manager: store, monitor: monitor, settings: AppSettings(defaults: defaults),
            networkAccess: DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: false),
            storedRecords: { [] }, pathTimeout: .seconds(30))
        let services = DownloadsServices(
            controller: controller, control: store, localItems: { _ in [] }, localItem: { await store.read($0) },
            availableCapacity: { 0 })
        let model = LocalItemDetailModel(itemID: itemID, services: services, account: LocalItemDetailTests.account)
        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        model.reloaded = { report.yield() }
        let observing = Task { await model.observe() }
        for await _ in reloads { break }
        model.reloaded = nil
        return (
            model,
            {
                observing.cancel(); defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    @Test func readsTheItemForTheSignedInAccount() async throws {
        let item = LocalItemDetailTests.item(files: [LocalItemDetailTests.file("01.mp3", size: 10, trackIndex: 1)])
        let (model, cleanUp) = try await makeModel(store: FakeLocalStore(item: item), itemID: item.id)
        defer { cleanUp() }

        #expect(model.isLoaded)
        #expect(model.detail?.tracks.count == 1)
        #expect(model.detail?.link == .thisAccount)
        #expect(!model.isDeleted)
    }

    @Test func aMissingItemIsNotFoundRatherThanDeleted() async throws {
        let (model, cleanUp) = try await makeModel(store: FakeLocalStore(item: nil), itemID: UUID())
        defer { cleanUp() }

        #expect(model.isLoaded)
        #expect(model.detail == nil)
        #expect(!model.isDeleted)
    }

    @Test func deletingAnEpisodeUpdatesTheEpisodesAndSizes() async throws {
        let item = Self.podcast(episodes: ["e1", "e2"])
        let store = FakeLocalStore(item: item)
        let (model, cleanUp) = try await makeModel(store: store, itemID: item.id)
        defer { cleanUp() }
        #expect(model.detail?.totalBytes == 20)

        await model.deleteEpisode(id: "e1")

        #expect(model.detail?.episodes.map(\.id) == ["e2"])
        #expect(model.detail?.totalBytes == 10)
        #expect(!model.isDeleted)
        #expect(model.notice == nil)
    }

    @Test func deletingTheLastEpisodeLeavesTheScreen() async throws {
        let item = Self.podcast(episodes: ["e1"])
        let (model, cleanUp) = try await makeModel(store: FakeLocalStore(item: item), itemID: item.id)
        defer { cleanUp() }

        await model.deleteEpisode(id: "e1")

        #expect(model.isDeleted)
    }

    @Test func deletingTheItemLeavesTheScreen() async throws {
        let item = Self.podcast(episodes: ["e1", "e2"])
        let store = FakeLocalStore(item: item)
        let (model, cleanUp) = try await makeModel(store: store, itemID: item.id)
        defer { cleanUp() }

        await model.delete()

        #expect(model.isDeleted)
        #expect(await store.item == nil)
    }

    @Test func aFailedDeleteKeepsTheItemAndShowsANotice() async throws {
        let item = Self.podcast(episodes: ["e1", "e2"])
        let store = FakeLocalStore(item: item)
        await store.fail(with: .storeFailure)
        let (model, cleanUp) = try await makeModel(store: store, itemID: item.id)
        defer { cleanUp() }

        await model.delete()
        await model.deleteEpisode(id: "e1")

        #expect(!model.isDeleted)
        #expect(model.notice == .deleteFailed)
        #expect(model.detail?.episodes.count == 2)
        #expect(!model.isDeleting)
    }

    @Test func aCompletedEpisodeOfTheItemIsReadIn() async throws {
        let item = Self.podcast(episodes: ["e1"])
        let store = FakeLocalStore(item: item)
        let (model, cleanUp) = try await makeModel(store: store, itemID: item.id)
        defer { cleanUp() }

        await store.set(Self.podcast(episodes: ["e1", "e2"]).withID(item.id))
        let (reloads, report) = AsyncStream.makeStream(of: Void.self)
        model.reloaded = { report.yield() }
        await store.send(
            .completed(
                recordID: UUID(), itemID: item.id,
                key: MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)))
        for await _ in reloads { break }

        #expect(model.detail?.episodes.count == 2)
    }
}

extension LocalLibraryItemDTO {
    fileprivate func withID(_ id: UUID) -> LocalLibraryItemDTO {
        var copy = self
        copy.id = id
        return copy
    }
}
