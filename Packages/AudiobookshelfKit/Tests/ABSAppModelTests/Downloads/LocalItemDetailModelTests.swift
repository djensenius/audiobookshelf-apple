import ABSCore
import ABSData
import ABSDownloads
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ABSAppModel

/// A path source that reports one path as soon as it is monitored.
private struct WifiPathSource: NetworkPathSource {
    func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in continuation.yield(.wifi) }
    }
}

/// A store and ``DownloadControlling`` in one: deletes remove from the stored item, like the
/// manager's deletion does, and can be told to fail. ``updates(_:)`` streams the item like
/// `LocalItemStore.updates(serverConnectionID:)`: as it is, then after each ``publish()``.
private actor FakeLocalStore: DownloadControlling {
    private(set) var item: LocalLibraryItemDTO?
    private(set) var reads = 0
    private var failure: DownloadManagerError?
    private var subscribers: [AsyncStream<DownloadManagerEvent>.Continuation] = []
    private var updateSubscribers: [AsyncStream<[LocalLibraryItemDTO]>.Continuation] = []

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

    func updates(_ connectionID: UUID) -> AsyncStream<[LocalLibraryItemDTO]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [LocalLibraryItemDTO].self, bufferingPolicy: .bufferingNewest(1))
        updateSubscribers.append(continuation)
        continuation.yield(item.map { [$0] } ?? [])
        return stream
    }

    /// Reports a write to the store, as another window's deletion would.
    func publish() {
        for subscriber in updateSubscribers { subscriber.yield(item.map { [$0] } ?? []) }
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

    /// Waits up to five seconds for `condition`.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A model observing `store`'s item until `cleanUp`; returns after the first read.
    private func makeModel(
        store: FakeLocalStore, itemID: UUID, storeUpdates: Bool = false,
        localFileURL: @escaping @Sendable (String) -> URL? = { _ in nil }
    ) async throws -> (LocalItemDetailModel, cleanUp: () -> Void) {
        let suiteName = "ABSAppModelTests.LocalItemDetail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let monitor = NetworkMonitor(source: WifiPathSource())
        let controller = DownloadsController(
            manager: store, monitor: monitor, settings: AppSettings(defaults: defaults),
            networkAccess: DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: false),
            storedRecords: { [] }, pathTimeout: .seconds(30))
        let updates: (@Sendable (UUID) async throws -> AsyncStream<[LocalLibraryItemDTO]>)? =
            storeUpdates ? { @Sendable connectionID in await store.updates(connectionID) } : nil
        let services = DownloadsServices(
            controller: controller, control: store, localItemUpdates: updates,
            localItems: { _ in [] }, localItem: { await store.read($0) }, localFileURL: localFileURL,
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

    @Test func anEpisodeDeletedElsewhereUpdatesTheRowsAndTotals() async throws {
        let item = Self.podcast(episodes: ["e1", "e2"])
        let store = FakeLocalStore(item: item)
        let (model, cleanUp) = try await makeModel(store: store, itemID: item.id, storeUpdates: true)
        defer { cleanUp() }

        // Another window deletes e1: the store changes and reports it, with no download event.
        await store.set(Self.podcast(episodes: ["e2"]).withID(item.id))
        await store.publish()
        try await eventually { model.detail?.episodes.count == 1 }

        #expect(model.detail?.episodes.map(\.id) == ["e2"])
        #expect(model.detail?.totalBytes == 10)
        #expect(!model.isDeleted)
    }

    @Test func theCoverIsTheDownloadedFile() async throws {
        let root = URL(filePath: "/downloads", directoryHint: .isDirectory)
        var item = Self.podcast(episodes: ["e1"])
        item.coverRelativePath = "items/radio/cover.jpg"
        let (model, cleanUp) = try await makeModel(
            store: FakeLocalStore(item: item), itemID: item.id, localFileURL: { root.appending(path: $0) })
        defer { cleanUp() }

        #expect(model.coverFileURL == root.appending(path: "items/radio/cover.jpg"))
    }

    @Test func withoutADownloadedCoverThereIsNoFile() async throws {
        let item = Self.podcast(episodes: ["e1"])
        let (model, cleanUp) = try await makeModel(
            store: FakeLocalStore(item: item), itemID: item.id, localFileURL: { URL(filePath: "/x/\($0)") })
        defer { cleanUp() }

        #expect(model.coverFileURL == nil)
    }

    @Test func readsTheCoverImageDownsampled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cover.png")
        let context = try #require(
            CGContext(
                data: nil, width: 40, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 64))
        let source = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))

        let image = try #require(await LocalItemDetailModel.coverImage(at: url, maxPixelSize: 32))
        #expect(max(image.width, image.height) == 32)
        #expect(
            await LocalItemDetailModel.coverImage(at: directory.appending(path: "gone.png"), maxPixelSize: 32) == nil)
    }

    @Test func anItemDeletedElsewhereLeavesTheScreen() async throws {
        let item = Self.podcast(episodes: ["e1"])
        let store = FakeLocalStore(item: item)
        let (model, cleanUp) = try await makeModel(store: store, itemID: item.id, storeUpdates: true)
        defer { cleanUp() }

        await store.set(nil)
        await store.publish()
        try await eventually { model.isDeleted }

        #expect(model.isDeleted)
        #expect(model.detail == nil)
    }
}

extension LocalLibraryItemDTO {
    fileprivate func withID(_ id: UUID) -> LocalLibraryItemDTO {
        var copy = self
        copy.id = id
        return copy
    }
}
