import ABSCore
import ABSData
import Foundation
import Observation
import Testing

@testable import ABSPlayback

@MainActor
final class InMemoryQueueStore: PlaybackQueueStoring {
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

func queueItem(_ itemID: String, episode: String? = nil) -> QueueItem {
    QueueItem(libraryItemID: itemID, episodeID: episode, title: "Title \(itemID)")
}

/// A `UserDefaults` suite of its own, removed when the test ends.
final class ScratchDefaults {
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
    let store = InMemoryQueueStore()

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
        queue.remove(id: queueItem("Z").id)
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

    @Test func unreadableSavedQueueLoadsEmpty() throws {
        let scratch = try ScratchDefaults()
        scratch.defaults.set(Data("not json".utf8), forKey: "playback_queue_\(connection.uuidString)")
        let queue = PlaybackQueue(
            serverConnectionID: connection, store: UserDefaultsPlaybackQueueStore(defaults: scratch.defaults))
        #expect(queue.items.isEmpty)
    }

    @Test func readersObserveChanges() async {
        let queue = PlaybackQueue(serverConnectionID: connection, store: store)
        let reader: any PlaybackQueueReading = queue
        let changed = Gate()
        withObservationTracking {
            _ = reader.items
        } onChange: {
            changed.open()
        }
        queue.addToEnd(queueItem("A"))
        await changed.wait()
        #expect(reader.items == [queueItem("A")])
    }
}

struct PodcastEpisodeListingTests {
    private func episode(_ id: String, published: Int?) -> PodcastEpisode {
        PodcastEpisode(id: id, publishedAt: published)
    }

    private var episodes: [PodcastEpisode] {
        [
            episode("e2", published: 2000), episode("undated", published: nil), episode("e1", published: 1000),
            episode("e3", published: 3000), episode("e2b", published: 2000),
        ]
    }

    @Test func serialPlaysOldestFirstAndEpisodicNewestFirst() {
        let serial = PodcastEpisodeListing(isSerial: true, episodes: episodes, finishedEpisodeIDs: [])
        #expect(serial.playOrder.map(\.id) == ["e1", "e2", "e2b", "e3", "undated"])
        let episodic = PodcastEpisodeListing(isSerial: false, episodes: episodes, finishedEpisodeIDs: [])
        #expect(episodic.playOrder.map(\.id) == ["undated", "e3", "e2", "e2b", "e1"])
    }

    @Test func nextUnfinishedSkipsFinishedAndTheEndedEpisode() {
        let listing = PodcastEpisodeListing(isSerial: true, episodes: episodes, finishedEpisodeIDs: ["e1", "e2b"])
        #expect(listing.nextUnfinished(after: "e2")?.id == "e3")
        #expect(listing.nextUnfinished(after: "e3")?.id == "e2")
        let allDone = PodcastEpisodeListing(
            isSerial: true, episodes: episodes, finishedEpisodeIDs: ["e1", "e2", "e2b", "undated"])
        #expect(allDone.nextUnfinished(after: "e3") == nil)
    }

    @Test func listingFromItemAndUserProgress() throws {
        let json = """
            {"id": "li-1", "libraryId": "lib", "mediaType": "podcast", "isMissing": false, "isInvalid": false,
             "media": {"id": "pod", "metadata": {"title": "Pod", "type": "serial"},
                       "episodes": [{"id": "e1", "publishedAt": 1}, {"id": "e2", "publishedAt": 2}]}}
            """
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        let progress = [
            MediaProgress(id: "1", libraryItemId: "li-1", episodeId: "e1", isFinished: true),
            MediaProgress(id: "2", libraryItemId: "li-1", episodeId: "e2", isFinished: false),
            MediaProgress(id: "3", libraryItemId: "other", episodeId: "e2", isFinished: true),
        ]
        let listing = PodcastEpisodeListing(item: item, progress: progress)
        #expect(listing.isSerial)
        #expect(listing.episodes.map(\.id) == ["e1", "e2"])
        #expect(listing.finishedEpisodeIDs == ["e1"])
    }
}
