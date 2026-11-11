import ABSData
import Foundation
import Observation
import Synchronization
import Testing

@testable import ABSPlayback

@MainActor
private final class InMemoryQueueStore: PlaybackQueueStoring {
    var saved: [UUID: [QueueItem]] = [:]
    private(set) var saves = 0

    func load(serverConnectionID: UUID) -> [QueueItem] { saved[serverConnectionID] ?? [] }

    func save(_ items: [QueueItem], serverConnectionID: UUID) {
        saves += 1
        saved[serverConnectionID] = items
    }

    func removeQueue(serverConnectionID: UUID) {
        saved[serverConnectionID] = nil
    }
}

private func queueItem(_ itemID: String, episode: String? = nil) -> QueueItem {
    QueueItem(libraryItemID: itemID, episodeID: episode, title: "Title \(itemID)")
}

/// A `UserDefaults` suite of its own, removed when the test ends.
private final class ScratchDefaults {
    let name = "PlaybackQueueTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: name))
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

@MainActor
struct PlaybackQueueTests {
    let connection = UUID()
    private let store = InMemoryQueueStore()

    private func ids(_ queue: PlaybackQueue) -> [String] {
        queue.items.map { $0.episodeID.map { "\($0)" } ?? $0.libraryItemID }
    }

    // MARK: - Ordering

    @Test func playNextPutsFirstAndAddToEndPutsLast() {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        queue.addToEnd(queueItem("A"))
        queue.addToEnd(queueItem("B"))
        queue.playNext(queueItem("C"))
        queue.addToEnd(queueItem("P", episode: "e1"))
        #expect(ids(queue) == ["C", "A", "B", "e1"])
    }

    @Test func queueingAgainMovesTheItem() {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        for id in ["A", "B", "C"] { queue.addToEnd(queueItem(id)) }
        queue.playNext(queueItem("C"))
        #expect(ids(queue) == ["C", "A", "B"])
        queue.addToEnd(queueItem("C"))
        #expect(ids(queue) == ["A", "B", "C"])
        // An episode and its podcast are different media.
        queue.addToEnd(queueItem("A", episode: "e1"))
        #expect(queue.items.count == 4)
    }

    @Test func requeueingAnEpisodeMovesItAndUpdatesMetadata() {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        queue.addToEnd(queueItem("P", episode: "e1"))
        queue.addToEnd(queueItem("P", episode: "e2"))
        queue.addToEnd(queueItem("B"))
        let updated = QueueItem(
            libraryItemID: "P", episodeID: "e2", title: "Updated", subtitle: "Podcast",
            coverPath: "/new.jpg", duration: 300)
        queue.playNext(updated)
        #expect(queue.items == [updated, queueItem("P", episode: "e1"), queueItem("B")])
        queue.addToEnd(updated)
        #expect(queue.items == [queueItem("P", episode: "e1"), queueItem("B"), updated])
        #expect(store.saved[connection] == queue.items)
    }

    @Test func removeByIDKeyAndOffsets() {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        for id in ["A", "B", "C", "D"] { queue.addToEnd(queueItem(id)) }
        queue.addToEnd(queueItem("P", episode: "e1"))
        queue.remove(id: queueItem("B").id)
        queue.remove(MediaKey(serverConnectionID: connection, libraryItemId: "P", episodeId: "e1"))
        // Another connection's key is not this queue's.
        queue.remove(MediaKey(serverConnectionID: UUID(), libraryItemId: "A"))
        #expect(ids(queue) == ["A", "C", "D"])
        queue.remove(atOffsets: [0, 2])
        #expect(ids(queue) == ["C"])
    }

    @Test(arguments: [
        (IndexSet([0]), 3, ["B", "C", "A", "D"]),
        (IndexSet([3]), 0, ["D", "A", "B", "C"]),
        (IndexSet([0, 2]), 4, ["B", "D", "A", "C"]),
        (IndexSet([1, 3]), 1, ["A", "B", "D", "C"]),
        (IndexSet([1]), 1, ["A", "B", "C", "D"]),
        (IndexSet([2]), 99, ["A", "B", "D", "C"]),
        (IndexSet([2]), -5, ["C", "A", "B", "D"]),
        (IndexSet([1, 7]), 4, ["A", "C", "D", "B"]),
        (IndexSet(), 99, ["A", "B", "C", "D"]),
        (IndexSet([7]), 0, ["A", "B", "C", "D"]),
    ])
    func moveMatchesOnMove(source: IndexSet, destination: Int, expected: [String]) {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        for id in ["A", "B", "C", "D"] { queue.addToEnd(queueItem(id)) }
        queue.move(fromOffsets: source, toOffset: destination)
        #expect(ids(queue) == expected)
    }

    @Test func clearEmptiesAndUnchangedQueuesAreNotSaved() {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        queue.addToEnd(queueItem("A"))
        queue.addToEnd(queueItem("A"))
        queue.playNext(queueItem("A"))
        queue.remove(id: queueItem("Z").id)
        queue.remove(MediaKey(serverConnectionID: UUID(), libraryItemId: "A"))
        queue.remove(atOffsets: [7])
        queue.remove(atOffsets: [])
        queue.move(fromOffsets: [7], toOffset: -1)
        queue.move(fromOffsets: [0], toOffset: 0)
        #expect(store.saves == 1)
        queue.clear()
        #expect(queue.items.isEmpty)
        #expect(store.saved[connection] == [])
        queue.clear()
        #expect(store.saves == 2)
    }

    // MARK: - Persistence

    @Test func userDefaultsQueueSurvivesAReload() throws {
        let scratch = try ScratchDefaults()
        let first = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        let episode = QueueItem(
            libraryItemID: "P", episodeID: "e1", title: "Episode", subtitle: "Podcast", coverPath: "/c.jpg",
            duration: 1200)
        first.addToEnd(queueItem("A"))
        first.addToEnd(episode)
        first.playNext(queueItem("B"))

        let reloaded = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        #expect(reloaded.items == [queueItem("B"), queueItem("A"), episode])

        reloaded.clear()
        #expect(scratch.defaults.data(forKey: "playback_queue_\(connection.uuidString)") == nil)
        let cleared = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        #expect(cleared.items.isEmpty)
    }

    @Test func unencodableDurationsAreDroppedSoTheQueueStillSaves() throws {
        let scratch = try ScratchDefaults()
        let queue = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        queue.addToEnd(QueueItem(libraryItemID: "A", title: "A", duration: 60))
        for (itemID, duration) in [("inf", Double.infinity), ("-inf", -.infinity), ("nan", .nan), ("neg", -1)] {
            let item = QueueItem(libraryItemID: itemID, title: itemID, duration: duration)
            #expect(item.duration == nil)
            queue.addToEnd(item)
        }
        queue.addToEnd(QueueItem(libraryItemID: "zero", title: "zero", duration: 0))

        // Every change saved: the earlier queue does not come back on relaunch.
        let reloaded = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        #expect(reloaded.items == queue.items)
        #expect(reloaded.items.map(\.libraryItemID) == ["A", "inf", "-inf", "nan", "neg", "zero"])
        #expect(reloaded.items.map(\.duration) == [60, nil, nil, nil, nil, 0])

        // Decoding goes through the same normalization.
        let decoded = try JSONDecoder().decode(
            QueueItem.self, from: Data(#"{"libraryItemID":"N","title":"T","duration":-5}"#.utf8))
        #expect(decoded.duration == nil)
    }

    @Test func eachConnectionHasItsOwnQueue() throws {
        let scratch = try ScratchDefaults()
        let store = UserDefaultsPlaybackQueueStore(defaults: scratch.defaults)
        let other = UUID()
        let mine = PlaybackQueue(serverConnectionID: connection, store: store)
        let theirs = PlaybackQueue(serverConnectionID: other, store: store)
        mine.addToEnd(queueItem("A"))
        theirs.addToEnd(queueItem("B"))
        theirs.addToEnd(queueItem("A"))
        mine.clear()

        #expect(PlaybackQueue(serverConnectionID: connection, store: store).items.isEmpty)
        #expect(PlaybackQueue(serverConnectionID: other, store: store).items == [queueItem("B"), queueItem("A")])
    }

    @Test func removeQueueDeletesOnlyThatConnectionsQueue() throws {
        let scratch = try ScratchDefaults()
        let store = UserDefaultsPlaybackQueueStore(defaults: scratch.defaults)
        let other = UUID()
        PlaybackQueue(serverConnectionID: connection, store: store).addToEnd(queueItem("A"))
        PlaybackQueue(serverConnectionID: other, store: store).addToEnd(queueItem("B"))

        store.removeQueue(serverConnectionID: connection)

        #expect(scratch.defaults.data(forKey: "playback_queue_\(connection.uuidString)") == nil)
        #expect(PlaybackQueue(serverConnectionID: connection, store: store).items.isEmpty)
        #expect(PlaybackQueue(serverConnectionID: other, store: store).items == [queueItem("B")])
    }

    @Test func decodingNormalizesAnEmptyEpisodeID() throws {
        let json =
            #"[{"libraryItemID": "A", "episodeID": "", "title": "T"}, {"libraryItemID": "P", "episodeID": "e1", "title": "E"}]"#
        let items = try JSONDecoder().decode([QueueItem].self, from: Data(json.utf8))
        #expect(
            items == [
                QueueItem(libraryItemID: "A", title: "T"), QueueItem(libraryItemID: "P", episodeID: "e1", title: "E"),
            ])
        #expect(items[0].episodeID == nil)
        #expect(items[0].id == queueItem("A").id)
    }

    @Test func emptyEpisodeIDsDeduplicateAndRemoveAsBooks() throws {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        queue.addToEnd(queueItem("A"))
        queue.addToEnd(queueItem("B"))
        let emptyEpisode = queueItem("A", episode: "")
        #expect(emptyEpisode.episodeID == nil)
        queue.playNext(emptyEpisode)
        #expect(queue.items == [queueItem("A"), queueItem("B")])
        let decoded = try JSONDecoder().decode(
            QueueItem.self, from: Data(#"{"libraryItemID":"A","episodeID":"","title":"Title A"}"#.utf8))
        queue.addToEnd(decoded)
        #expect(queue.items == [queueItem("B"), queueItem("A")])
        queue.remove(MediaKey(serverConnectionID: connection, libraryItemId: "A", episodeId: ""))
        #expect(queue.items == [queueItem("B")])
    }

    @Test func unreadableSavedQueueLoadsEmpty() throws {
        let scratch = try ScratchDefaults()
        scratch.defaults.set(Data("not json".utf8), forKey: "playback_queue_\(connection.uuidString)")
        let queue = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        #expect(queue.items.isEmpty)
    }

    @Test func corruptQueueDoesNotAffectAnotherConnection() throws {
        let scratch = try ScratchDefaults()
        let store = UserDefaultsPlaybackQueueStore(defaults: scratch.defaults)
        let other = UUID()
        store.save([queueItem("B")], serverConnectionID: other)
        let corrupt = Data(#"[{"libraryItemID":"A"}]"#.utf8)
        let key = "playback_queue_\(connection.uuidString)"
        scratch.defaults.set(corrupt, forKey: key)
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        #expect(queue.items.isEmpty)
        // Loading is a safe fallback, not a destructive repair.
        #expect(scratch.defaults.data(forKey: key) == corrupt)
        queue.addToEnd(queueItem("A"))
        #expect(store.load(serverConnectionID: connection) == [queueItem("A")])
        #expect(store.load(serverConnectionID: other) == [queueItem("B")])
    }

    @Test func readersObserveChangesButNotNoOps() {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        let reader: any PlaybackQueueReading = queue
        let changes = Mutex(0)
        withObservationTracking {
            _ = reader.items
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        queue.clear()
        queue.remove(id: queueItem("A").id)
        #expect(changes.withLock { $0 } == 0)
        queue.addToEnd(queueItem("A"))
        #expect(changes.withLock { $0 } == 1)
        #expect(reader.items == [queueItem("A")])
        withObservationTracking {
            _ = reader.items
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        queue.addToEnd(queueItem("A"))
        queue.move(fromOffsets: [0], toOffset: 1)
        #expect(changes.withLock { $0 } == 1)
        queue.clear()
        #expect(changes.withLock { $0 } == 2)
        #expect(reader.items.isEmpty)
    }
}
