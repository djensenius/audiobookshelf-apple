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

    // MARK: Replacing the queue (play-all)

    /// A scope whose player has loaded `started`, and its queue, checking a pending start every millisecond.
    private func startedScope(_ started: String, items: [QueueItem]) throws -> (
        QueueScope, PlaybackQueueControl, MediaKey
    ) {
        let scope = QueueScope(items: items)
        let queue = try #require(PlaybackQueueControl(scope: scope))
        queue.startPollInterval = .milliseconds(1)
        let key = item(started).key(serverConnectionID: queue.serverConnectionID)
        scope.control.mediaKey = key
        scope.control.phase = .loaded
        return (scope, queue, key)
    }

    /// Lets a waiting replace check the pending start a few times.
    private func letItWait() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test func aSucceededStartReplacesTheQueueInOrderWithoutTheCurrentMediaOrDuplicates() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x"), item("y")])

        let replaced = await queue.replace(
            with: [item("b"), item("a"), item("c"), item("b")], afterStarting: started, request: queue.beginPlayAll())
        #expect(replaced)
        #expect(queue.items.map(\.id) == ["b|", "c|"])
        #expect(scope.queueStore.saved[queue.serverConnectionID]?.map(\.id) == ["b|", "c|"])
    }

    /// A start that failed, was cancelled (unloaded), was superseded by other media, or is another
    /// connection's leaves the previous queue.
    @Test func anUnsucceededStartKeepsThePreviousQueue() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        let replacement = [item("b"), item("c")]

        scope.control.error = .recoveryExhausted
        #expect(!(await queue.replace(with: replacement, afterStarting: started, request: queue.beginPlayAll())))
        scope.control.error = nil

        scope.control.phase = .unloaded
        #expect(!(await queue.replace(with: replacement, afterStarting: started, request: queue.beginPlayAll())))
        scope.control.phase = .idle
        #expect(!(await queue.replace(with: replacement, afterStarting: started, request: queue.beginPlayAll())))
        scope.control.phase = .loaded

        scope.control.mediaKey = item("other").key(serverConnectionID: queue.serverConnectionID)
        #expect(!(await queue.replace(with: replacement, afterStarting: started, request: queue.beginPlayAll())))
        scope.control.mediaKey = started

        let elsewhere = item("a").key(serverConnectionID: UUID())
        #expect(!(await queue.replace(with: replacement, afterStarting: elsewhere, request: queue.beginPlayAll())))

        #expect(queue.items.map(\.id) == ["x|"])
    }

    /// Another screen's start of the media is pending: the queue is replaced only once it loads.
    @Test func aPendingStartThatSucceedsThenReplacesTheQueue() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        scope.control.phase = .starting

        let request = queue.beginPlayAll()
        let replacing = Task { await queue.replace(with: [item("b")], afterStarting: started, request: request) }
        try await letItWait()
        #expect(queue.items.map(\.id) == ["x|"])

        scope.control.phase = .loaded
        #expect(await replacing.value)
        #expect(queue.items.map(\.id) == ["b|"])
    }

    @Test func aPendingStartThatFailsKeepsThePreviousQueue() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        scope.control.phase = .starting

        let request = queue.beginPlayAll()
        let replacing = Task { await queue.replace(with: [item("b")], afterStarting: started, request: request) }
        try await letItWait()
        scope.control.error = .recoveryExhausted
        scope.control.phase = .unloaded

        #expect(!(await replacing.value))
        #expect(queue.items.map(\.id) == ["x|"])
    }

    /// The pending start is stopped and the same media started again between two checks: the play-all joined the
    /// stopped start, so the new one's load doesn't replace the queue; a play-all of the new start does.
    @Test func aPendingStartStoppedAndRestartedBetweenChecksKeepsThePreviousQueue() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        scope.control.phase = .starting

        let request = queue.beginPlayAll()
        let replacing = Task { await queue.replace(with: [item("b")], afterStarting: started, request: request) }
        try await letItWait()
        scope.control.phase = .idle
        scope.control.mediaKey = nil
        scope.control.startGeneration += 1
        scope.control.mediaKey = started
        scope.control.phase = .starting
        scope.control.startGeneration += 1
        try await letItWait()
        scope.control.phase = .loaded

        #expect(!(await replacing.value))
        #expect(queue.items.map(\.id) == ["x|"])
        #expect(await queue.replace(with: [item("c")], afterStarting: started, request: queue.beginPlayAll()))
        #expect(queue.items.map(\.id) == ["c|"])
    }

    @Test func aPendingStartThatNeverLoadsTimesOut() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        scope.control.phase = .starting
        queue.startTimeout = .milliseconds(10)

        #expect(!(await queue.replace(with: [item("b")], afterStarting: started, request: queue.beginPlayAll())))
        #expect(queue.items.map(\.id) == ["x|"])
    }

    /// Two windows play groups starting with the same media while it loads: the newer one's queue wins, whichever
    /// finishes waiting first.
    @Test func theNewerOfOverlappingPlayAllsWins() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        scope.control.phase = .starting

        let older = queue.beginPlayAll()
        let olderReplace = Task { await queue.replace(with: [item("b")], afterStarting: started, request: older) }
        let newer = queue.beginPlayAll()
        let newerReplace = Task { await queue.replace(with: [item("c")], afterStarting: started, request: newer) }
        try await letItWait()
        scope.control.phase = .loaded

        #expect(await newerReplace.value)
        #expect(!(await olderReplace.value))
        #expect(queue.items.map(\.id) == ["c|"])

        // A late older replace, after the newer one's, changes nothing either.
        #expect(!(await queue.replace(with: [item("b")], afterStarting: started, request: older)))
        #expect(queue.items.map(\.id) == ["c|"])
    }

    /// A cancelled caller replaces nothing, even with the media already loaded.
    @Test func aCancelledReplaceKeepsThePreviousQueue() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        let request = queue.beginPlayAll()

        let replacing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.replace(with: [item("b")], afterStarting: started, request: request)
        }

        #expect(!(await replacing.value))
        #expect(queue.items.map(\.id) == ["x|"])
        // The scope is kept, so only the cancellation refused it: the same request then replaces.
        #expect(await queue.replace(with: [item("b")], afterStarting: started, request: request))
        #expect(scope.queueStore.saved[queue.serverConnectionID]?.map(\.id) == ["b|"])
    }

    @Test func aRetiredSessionsQueueIsntReplaced() async throws {
        let (scope, queue, started) = try startedScope("a", items: [item("x")])
        scope.retire(reason: .signOut)

        #expect(!(await queue.replace(with: [item("b")], afterStarting: started, request: queue.beginPlayAll())))
        #expect(queue.items.map(\.id) == ["x|"])
    }
}
