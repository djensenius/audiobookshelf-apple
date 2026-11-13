import ABSCore
import Foundation
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``LocalProgressStoreLinker`` against a real `LocalProgressStore`: a downloaded item's rows are
/// linked, so pruning keeps them, and unlinked when the download goes.
@Suite(.timeLimit(.minutes(1))) struct LocalProgressStoreLinkerTests {
    private let connectionID = UUID()

    @Test func linkingKeepsASyncedRowFromPruning() async throws {
        let store = try Self.store()
        let key = key("li_1")
        try await synced(key, in: store)
        let itemID = UUID()

        try await LocalProgressStoreLinker(store: store).link(key: key, itemID: itemID)

        #expect(try await store.progress(for: key)?.localLibraryItemID == itemID)
        #expect(try await store.pruneSynced() == 0)
    }

    /// Media never played here has no row: linking it creates none, and doesn't throw.
    @Test func linkingMediaWithoutProgressDoesNothing() async throws {
        let store = try Self.store()
        let key = key("li_1")

        try await LocalProgressStoreLinker(store: store).link(key: key, itemID: UUID())

        #expect(try await store.progress(for: key) == nil)
    }

    /// Every row of the item is unlinked, episodes included; another item's rows stay linked.
    @Test func detachingAnItemUnlinksAllItsRows() async throws {
        let store = try Self.store()
        let linker = LocalProgressStoreLinker(store: store)
        let episodes = [key("li_1", episode: "ep_1"), key("li_1", episode: "ep_2")]
        let other = key("li_2")
        let itemID = UUID()
        let otherID = UUID()
        for key in episodes {
            try await synced(key, in: store)
            try await linker.link(key: key, itemID: itemID)
        }
        try await synced(other, in: store)
        try await linker.link(key: other, itemID: otherID)

        try await linker.detach(itemID: itemID)

        #expect(try await store.progress(localLibraryItemID: itemID).isEmpty)
        #expect(try await store.progress(localLibraryItemID: otherID).map(\.key) == [other])
        #expect(try await store.pruneSynced() == 2)
        #expect(try await store.progress(for: other) != nil)
    }

    @Test func detachingAnEpisodeKeepsTheOthersLinked() async throws {
        let store = try Self.store()
        let linker = LocalProgressStoreLinker(store: store)
        let deleted = key("li_1", episode: "ep_1")
        let kept = key("li_1", episode: "ep_2")
        let itemID = UUID()
        for key in [deleted, kept] {
            try await synced(key, in: store)
            try await linker.link(key: key, itemID: itemID)
        }

        try await linker.detach(key: deleted)

        #expect(try await store.progress(for: deleted)?.localLibraryItemID == nil)
        #expect(try await store.progress(localLibraryItemID: itemID).map(\.key) == [kept])
    }

    /// Unlinking keeps a row with changes the server hasn't acknowledged.
    @Test func detachingKeepsUnsyncedChanges() async throws {
        let store = try Self.store()
        let linker = LocalProgressStoreLinker(store: store)
        let key = key("li_1")
        let itemID = UUID()
        try await store.recordEdit(Self.seek, for: key, now: Self.t0)
        try await linker.link(key: key, itemID: itemID)

        try await linker.detach(itemID: itemID)

        #expect(try await store.pruneSynced() == 0)
        #expect(try await store.pendingSync(for: connectionID).map(\.key) == [key])
    }

    /// Through ``DownloadManager``: a completed download links its row, and deleting the
    /// download unlinks it, so the synced row is pruned only then.
    @Test func theManagerLinksAndDetachesThroughTheStore() async throws {
        let fixture = try await ManagerFixture()
        let store = LocalProgressStore(modelContainer: fixture.container)
        let manager = fixture.makeManager(progressLinking: LocalProgressStoreLinker(store: store))
        try await manager.start()
        let events = await manager.events()
        let item = LibraryItemFixtures.book()
        let key = fixture.key(item)
        try await store.recordEdit(Self.seek, for: key, now: Self.t0)
        try await Self.acknowledge(key, in: store)
        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: fixture.connectionID)
        guard case .started(let recordID) = result else { throw UnexpectedResult(result: result) }
        let itemID = try await fixture.storeDownloaded(item).id

        fixture.engine.updateContinuation.yield(.recordComplete(recordID: recordID, itemID: itemID))
        _ = await events.next {
            if case .completed = $0 { true } else { false }
        }

        #expect(try await store.progress(for: key)?.localLibraryItemID == itemID)
        #expect(try await store.pruneSynced() == 0)

        #expect(try await manager.deleteLocalItem(id: itemID))

        #expect(try await store.progress(for: key)?.localLibraryItemID == nil)
        #expect(try await store.pruneSynced() == 1)
    }

    // MARK: - Helpers

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let seek = ProgressEdit(audio: .init(currentTime: 30, duration: 600, progress: 0.05))

    private static func store() throws -> LocalProgressStore {
        LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    private func key(_ item: String, episode: String? = nil) -> MediaKey {
        MediaKey(serverConnectionID: connectionID, libraryItemId: item, episodeId: episode)
    }

    /// A row the server has acknowledged, which pruning deletes unless it is linked.
    private func synced(_ key: MediaKey, in store: LocalProgressStore) async throws {
        try await store.recordEdit(Self.seek, for: key, now: Self.t0)
        try await Self.acknowledge(key, in: store)
    }

    private static func acknowledge(_ key: MediaKey, in store: LocalProgressStore) async throws {
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: t0.addingTimeInterval(1))
    }
}
