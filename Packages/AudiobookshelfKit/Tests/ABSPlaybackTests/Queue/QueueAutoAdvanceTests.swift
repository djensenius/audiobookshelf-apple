import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSPlayback

/// Episodes for one podcast, optionally held until a gate opens; counts requests.
final class StubEpisodeSource: PodcastEpisodeSource {
    private let state: Mutex<(listing: PodcastEpisodeListing?, gate: Gate?, requests: Int)>

    init(_ listing: PodcastEpisodeListing?, gate: Gate? = nil) {
        state = Mutex((listing, gate, 0))
    }

    var requests: Int { state.withLock { $0.requests } }

    func listing(podcastItemID: String) async throws -> PodcastEpisodeListing {
        let (listing, gate) = state.withLock { state in
            state.requests += 1
            return (state.listing, state.gate)
        }
        await gate?.wait()
        guard let listing else { throw CancellationError() }
        return listing
    }
}

@MainActor
struct QueueAutoAdvanceTests {
    let h: CoordinatorHarness
    let queue: PlaybackQueue
    var coordinator: PlaybackCoordinator { h.coordinator }

    init() throws {
        h = try CoordinatorHarness()
        queue = PlaybackQueue(serverConnectionID: h.connectionID, store: InMemoryQueueStore())
    }

    private func attach(episodes: (any PodcastEpisodeSource)? = nil) {
        PlaybackQueueAdvancer(queue: queue, episodes: episodes).attach(to: coordinator)
    }

    private func episodeKey(_ id: String) -> MediaKey {
        MediaKey(serverConnectionID: h.connectionID, libraryItemId: "P", episodeId: id)
    }

    private func listing(isSerial: Bool, finished: Set<String>) -> PodcastEpisodeListing {
        PodcastEpisodeListing(
            isSerial: isSerial,
            episodes: (1...4).map { PodcastEpisode(id: "e\($0)", publishedAt: $0 * 1000) },
            finishedEpisodeIDs: finished)
    }

    private func waitUntilPlaying(_ key: MediaKey) async {
        await yieldUntil { coordinator.mediaKey == key && coordinator.isPlaying }
    }

    @Test func endPlaysQueuedItemsInOrderAndDequeuesThem() async throws {
        attach()
        queue.addToEnd(queueItem("B"))
        queue.addToEnd(queueItem("C"))
        await coordinator.play(itemID: "A")

        h.engine.finish()
        await waitUntilPlaying(h.key("B"))
        #expect(queue.items == [queueItem("C")])

        h.engine.finish()
        await waitUntilPlaying(h.key("C"))
        #expect(queue.items.isEmpty)
        #expect(h.service.starts == ["A", "B", "C"])
        #expect(h.service.closes == ["A-1", "B-2"])
    }

    @Test func queueComesBeforeTheNextEpisode() async throws {
        let source = StubEpisodeSource(listing(isSerial: true, finished: []))
        attach(episodes: source)
        queue.addToEnd(queueItem("B"))
        await coordinator.play(itemID: "P", episodeID: "e1")

        h.engine.finish()
        await waitUntilPlaying(h.key("B"))
        #expect(source.requests == 0)
    }

    @Test func playingAQueuedItemDirectlyDequeuesIt() async throws {
        attach()
        queue.addToEnd(queueItem("A"))
        queue.addToEnd(queueItem("B"))
        await coordinator.play(itemID: "A")
        #expect(queue.items == [queueItem("B")])
    }

    @Test(arguments: [
        // Serial: oldest first, skipping finished e3.
        (true, "e2", Set(["e1", "e3"]), "e4"),
        // Episodic: newest first; e4 ended, e3 finished.
        (false, "e4", Set(["e3"]), "e2"),
        // The ended episode's finish isn't synced yet; it is still skipped.
        (true, "e1", Set<String>(), "e2"),
    ])
    func emptyQueueAfterAnEpisodePlaysTheNextUnfinishedEpisode(
        isSerial: Bool, ended: String, finished: Set<String>, next: String
    ) async throws {
        attach(episodes: StubEpisodeSource(listing(isSerial: isSerial, finished: finished)))
        await coordinator.play(itemID: "P", episodeID: ended)

        h.engine.finish()
        await waitUntilPlaying(episodeKey(next))
        #expect(coordinator.phase == .loaded)
        #expect(h.service.starts == ["P", "P"])
    }

    @Test func lastItemWithNothingNextStopsCleanly() async throws {
        let source = StubEpisodeSource(listing(isSerial: true, finished: ["e1", "e2", "e3"]))
        attach(episodes: source)
        await coordinator.play(itemID: "P", episodeID: "e4")
        let start = h.events.count

        h.engine.finish()
        await yieldUntil { source.requests == 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(h.events.since(start) == [.ended])
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.mediaKey == episodeKey("e4"))
        #expect(!coordinator.isPlaying)
        #expect(h.service.starts == ["P"])
        #expect(h.service.closes.isEmpty)
        #expect(h.policy.checks == 1)
        #expect(h.lastPlayed.record?.isFinished == true)
    }

    @Test func bookWithEmptyQueueStaysAtTheEnd() async throws {
        let source = StubEpisodeSource(listing(isSerial: true, finished: []))
        attach(episodes: source)
        await coordinator.play(itemID: "A")

        h.engine.finish()
        for _ in 0..<20 { await Task.yield() }

        #expect(source.requests == 0)
        #expect(h.service.starts == ["A"])
        #expect(!coordinator.isPlaying)
        // Playing again restarts it.
        await coordinator.resume()
        #expect(h.engine.seeks.last == 0)
        #expect(coordinator.isPlaying)
    }

    @Test func episodeSourceFailureStaysAtTheEnd() async throws {
        let source = StubEpisodeSource(nil)
        attach(episodes: source)
        await coordinator.play(itemID: "P", episodeID: "e1")

        h.engine.finish()
        await yieldUntil { source.requests == 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(h.service.starts == ["P"])
        #expect(coordinator.mediaKey == episodeKey("e1"))
    }

    @Test func userActionWhileDecidingWins() async throws {
        let gate = Gate()
        let source = StubEpisodeSource(listing(isSerial: true, finished: []), gate: gate)
        attach(episodes: source)
        await coordinator.play(itemID: "P", episodeID: "e1")

        h.engine.finish()
        await yieldUntil { source.requests == 1 }
        await coordinator.play(itemID: "B")
        gate.open()
        for _ in 0..<20 { await Task.yield() }

        #expect(coordinator.mediaKey == h.key("B"))
        #expect(h.service.starts == ["P", "B"])
    }

    @Test func seekAfterTheEndCancelsTheAdvance() async throws {
        let gate = Gate()
        let source = StubEpisodeSource(listing(isSerial: true, finished: []), gate: gate)
        attach(episodes: source)
        await coordinator.play(itemID: "P", episodeID: "e1")

        h.engine.finish()
        await yieldUntil { source.requests == 1 }
        await coordinator.seek(to: 100)
        gate.open()
        for _ in 0..<20 { await Task.yield() }

        #expect(coordinator.mediaKey == episodeKey("e1"))
        #expect(h.service.starts == ["P"])
    }

    @Test func withoutAProviderTheEndIsUnchanged() async throws {
        queue.addToEnd(queueItem("B"))
        await coordinator.play(itemID: "A")

        h.engine.finish()
        for _ in 0..<20 { await Task.yield() }

        #expect(h.service.starts == ["A"])
        #expect(queue.items == [queueItem("B")])
    }
}
