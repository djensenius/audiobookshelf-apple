import ABSAPI
import ABSCore
import ABSData
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
    /// Its player; set `mediaKey` to load media.
    let control = FakePlaybackControl()
    var isRetired = false
    var onSessionRejected: (@MainActor () -> Void)?
    var onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)?

    init(items: [QueueItem] = []) {
        let id = UUID()
        queueStore.saved[id] = items
        playbackQueue = PlaybackQueue(serverConnectionID: id, store: queueStore)
    }

    var playback: any PlayerPlaybackControlling { control }
    var queue: (any PlaybackQueueReading)? { playbackQueue }
    var sleepTimer: SleepTimer? { nil }
    func editQueue(_ edit: (PlaybackQueue) -> Void) {
        guard !isRetired else { return }
        edit(playbackQueue)
    }
    func start() -> Bool { false }
    func play(itemID: String, episodeID: String?, startTime: Double?) async {}
    func reconnect(client: APIClient?, features: ServerFeatures?) {}
    func progressDidChange(for key: MediaKey, kind: ProgressChangeKind) {}
    func saveLocally() {}
    func syncWithServer(isFirstSync: Bool) {}
    func flush() async {}
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

    // MARK: The current media

    /// The queue advances past the loaded media, so it isn't queued; another episode of the same
    /// podcast is.
    @Test func theCurrentMediaIsRefusedButAnotherEpisodeOfItsPodcastIsQueued() throws {
        let scope = QueueScope()
        let queue = try #require(PlaybackQueueControl(scope: scope))
        let playing = try #require(QueueItem(item: SampleLibrary.podcast, episode: SampleLibrary.episodes[0]))
        let other = try #require(QueueItem(item: SampleLibrary.podcast, episode: SampleLibrary.episodes[1]))
        scope.control.mediaKey = playing.key(serverConnectionID: queue.serverConnectionID)

        #expect(queue.isCurrent(playing))
        #expect(!queue.isCurrent(other))
        #expect(!queue.add(playing, at: .next))
        #expect(!queue.add(playing, at: .end))
        #expect(queue.add(other, at: .next))
        #expect(queue.items.map(\.id) == ["li_podcast|ep_1"])
    }

    /// Whether the actions are offered follows the loaded media: hidden while it's the item, offered
    /// again once something else (or nothing) is loaded, or for the same media on another connection.
    @Test func theCurrentMediaFollowsThePlayer() throws {
        let scope = QueueScope()
        let queue = try #require(PlaybackQueueControl(scope: scope))
        let book = try #require(QueueItem(item: SampleLibrary.frankenstein))
        #expect(!queue.isCurrent(book))

        scope.control.mediaKey = book.key(serverConnectionID: queue.serverConnectionID)
        #expect(queue.isCurrent(book))

        scope.control.mediaKey = book.key(serverConnectionID: UUID())
        #expect(!queue.isCurrent(book))

        scope.control.mediaKey = nil
        #expect(!queue.isCurrent(book))
        #expect(queue.add(book, at: .end))
        #expect(queue.items.map(\.id) == ["li_frankenstein|"])
    }

    @Test func aRetiredSessionsQueueIsntChanged() throws {
        let scope = QueueScope(items: [item("a")])
        let queue = try #require(PlaybackQueueControl(scope: scope))
        scope.retire(reason: .signOut)

        #expect(!queue.add(item("b"), at: .next))
        #expect(!queue.add(item("c"), at: .end))
        #expect(queue.items.map(\.id) == ["a|"])
    }

    /// A menu still showing after its session's scope was released reports nothing queued.
    @Test func aReleasedSessionsQueueIsntChanged() throws {
        var scope: QueueScope? = QueueScope(items: [item("a")])
        let queue = try #require(scope.flatMap { PlaybackQueueControl(scope: $0) })
        scope = nil
        #expect(scope == nil)

        #expect(!queue.add(item("b"), at: .next))
        #expect(!queue.add(item("c"), at: .end))
        #expect(queue.items.map(\.id) == ["a|"])
    }
}
