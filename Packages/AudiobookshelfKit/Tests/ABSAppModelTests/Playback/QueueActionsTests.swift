import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSPlayback

@MainActor
private final class MemoryQueueStore: PlaybackQueueStoring {
    var saved: [UUID: [QueueItem]] = [:]

    func load(serverConnectionID: UUID) -> [QueueItem] { saved[serverConnectionID] ?? [] }
    func save(_ items: [QueueItem], serverConnectionID: UUID) { saved[serverConnectionID] = items }
    func removeQueue(serverConnectionID: UUID) { saved[serverConnectionID] = nil }
}

/// Owns a real ``PlaybackQueue`` and edits it until retired, as ``PlaybackScope`` does.
@MainActor
private final class QueueScope: PlaybackScopeHandle {
    let queueStore = MemoryQueueStore()
    let playbackQueue: PlaybackQueue
    var isRetired = false
    var onSessionRejected: (@MainActor () -> Void)?

    init(items: [QueueItem] = []) {
        let id = UUID()
        queueStore.saved[id] = items
        playbackQueue = PlaybackQueue(serverConnectionID: id, store: queueStore)
    }

    var playback: any PlayerPlaybackControlling { FakePlaybackControl() }
    var queue: (any PlaybackQueueReading)? { playbackQueue }
    var sleepTimer: SleepTimer? { nil }
    func editQueue(_ edit: (PlaybackQueue) -> Void) {
        guard !isRetired else { return }
        edit(playbackQueue)
    }
    func start() -> Bool { false }
    func play(itemID: String, episodeID: String?, startTime: Double?) async {}
    func reconnect(client: APIClient?, features: ServerFeatures?) {}
    func saveLocally() {}
    func retire(reason: PlaybackStopReason) { isRetired = true }
    func finishRetirement(timeout: Duration) async -> Result<PlaybackCloseOutcome, any Error> {
        .success(PlaybackCloseOutcome(sessions: []))
    }
}

private func item(_ id: String) -> QueueItem {
    QueueItem(libraryItemID: id, title: id)
}

@MainActor
struct QueueActionsTests {
    // MARK: Building the queue item

    @Test func aBookIsQueuedWithItsCardsDetails() throws {
        let book = SampleLibrary.frankenstein
        let queued = try #require(QueueItem(item: book))

        #expect(queued.libraryItemID == book.id)
        #expect(queued.episodeID == nil)
        #expect(queued.title == "Frankenstein; or, The Modern Prometheus")
        #expect(queued.subtitle == "Mary Shelley")
        #expect(queued.duration == ItemSummary(item: book).duration)
        #expect(queued.duration != nil)
        #expect(queued.coverPath == book.media?.coverPath)
    }

    @Test func anEpisodeIsQueuedWithItsPodcastsTitleAndCover() throws {
        let episode = SampleLibrary.episodes[0]
        let queued = try #require(QueueItem(item: SampleLibrary.podcast, episode: episode))

        #expect(queued.libraryItemID == "li_podcast")
        #expect(queued.episodeID == "ep_2")
        #expect(queued.id == "li_podcast|ep_2")
        #expect(queued.title == "Episode 2: A Scandal in Bohemia")
        #expect(queued.subtitle == "Classic Tales")
        #expect(queued.duration == 1_800)
        #expect(queued.coverPath == "/metadata/items/li_podcast/cover.jpg")
    }

    @Test func whatCantBePlayedIsntQueued() {
        // A podcast without an episode, a missing book, an unknown media type.
        #expect(QueueItem(item: SampleLibrary.podcast) == nil)
        #expect(QueueItem(item: SampleLibrary.missing) == nil)
        #expect(
            QueueItem(item: LibraryItem(id: "unknown", libraryId: SampleLibrary.libraryID, mediaType: .book)) == nil)
    }

    // MARK: Placement

    @Test func playNextPutsTheItemFirstAndAddToQueuePutsItLast() throws {
        let scope = QueueScope(items: [item("a")])
        let queue = try #require(PlaybackQueueControl(scope: scope))

        queue.add(item("b"), at: .next)
        #expect(queue.items.map(\.id) == ["b|", "a|"])
        queue.add(item("c"), at: .end)
        #expect(queue.items.map(\.id) == ["b|", "a|", "c|"])
    }

    @Test func queueingAnItemAgainMovesIt() throws {
        let scope = QueueScope(items: [item("a"), item("b"), item("c")])
        let queue = try #require(PlaybackQueueControl(scope: scope))

        queue.add(item("c"), at: .next)
        #expect(queue.items.map(\.id) == ["c|", "a|", "b|"])
        queue.add(item("c"), at: .end)
        #expect(queue.items.map(\.id) == ["a|", "b|", "c|"])
    }

    /// An episode and its podcast's other episodes are different entries.
    @Test func episodesOfOnePodcastAreQueuedSeparately() throws {
        let scope = QueueScope()
        let queue = try #require(PlaybackQueueControl(scope: scope))
        let first = try #require(QueueItem(item: SampleLibrary.podcast, episode: SampleLibrary.episodes[0]))
        let second = try #require(QueueItem(item: SampleLibrary.podcast, episode: SampleLibrary.episodes[1]))

        queue.add(first, at: .end)
        queue.add(second, at: .next)
        #expect(queue.items.map(\.id) == ["li_podcast|ep_1", "li_podcast|ep_2"])
    }

    @Test func aRetiredSessionsQueueIsntChanged() throws {
        let scope = QueueScope(items: [item("a")])
        let queue = try #require(PlaybackQueueControl(scope: scope))
        scope.retire(reason: .signOut)

        queue.add(item("b"), at: .next)
        queue.add(item("c"), at: .end)
        #expect(queue.items.map(\.id) == ["a|"])
    }
}
