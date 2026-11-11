import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSPlayback

/// When the next item is prepared (#160): on load, once near the end, and when the queue, the next
/// item's progress or the connection change.
@MainActor
struct AutoAdvancePreparationTests {
    let a: AdvanceHarness

    init() throws {
        a = try AdvanceHarness()
    }

    private var progressReads: [MediaKey] { a.service.state.withLock { $0.progressReads } }

    @Test func preparesOnLoadedThenOnceNearTheEnd() async {
        a.enqueue("B")
        await a.play("A")
        #expect(progressReads == [a.key("A"), a.key("B")])
        #expect(a.h.policy.checks == 2)

        a.h.engine.onEvent?(.tick(1000))
        await a.advancer.waitForPreparation()
        #expect(progressReads.count == 2)

        a.h.engine.onEvent?(.tick(3580))
        await a.advancer.waitForPreparation()
        a.h.engine.onEvent?(.tick(3590))
        await a.advancer.waitForPreparation()
        #expect(progressReads == [a.key("A"), a.key("B"), a.key("B")])
        #expect(a.h.policy.checks == 3)
    }

    @Test func queueChangesPrepareTheNewHeadOnly() async {
        a.enqueue("B")
        await a.play("A")

        a.queue.playNext(QueueItem(libraryItemID: "C", episodeID: nil, title: "C"))
        await a.advancer.waitForPreparation()
        #expect(progressReads.last == a.key("C"))

        // Behind the head: nothing to prepare.
        a.enqueue("D")
        await a.advancer.waitForPreparation()
        #expect(progressReads.count == 3)

        a.queue.remove(a.key("C"))
        await a.advancer.waitForPreparation()
        #expect(progressReads.last == a.key("B"))

        await a.finish()
        #expect(a.coordinator.mediaKey == a.key("B"))
    }

    /// Each change replaces the preparation in flight, which never reaches the network.
    @Test func rapidQueueChangesPrepareOnlyTheLatest() async {
        await a.play("A")
        #expect(progressReads == [a.key("A")])

        for id in ["B", "C", "D", "E"] {
            a.queue.playNext(QueueItem(libraryItemID: id, episodeID: nil, title: id))
        }
        await a.advancer.waitForPreparation()

        #expect(progressReads == [a.key("A"), a.key("E")])
        #expect(a.h.policy.checks == 2)
    }

    /// Finishing the episode that was next (on another device, or synced) moves on to the one after.
    @Test func finishingTheNextEpisodeRecomputes() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        #expect(progressReads.last == a.key("P", episode: "e2"))

        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e2"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e2"))
        await a.advancer.waitForPreparation()
        #expect(a.episodes.fetches == 2)
        #expect(progressReads.last == a.key("P", episode: "e3"))

        // Unrelated progress changes nothing.
        a.advancer.progressDidChange(for: a.key("Other"))
        await a.advancer.waitForPreparation()
        #expect(a.episodes.fetches == 2)

        let before = a.fetches
        #expect(await a.finish() == before)
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    @Test func connectionChangeChecksThePolicyAgain() async {
        a.enqueue("B")
        await a.play("A")

        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()

        #expect(a.h.policy.checks == 3)
        #expect(progressReads == [a.key("A"), a.key("B"), a.key("B")])
    }

    /// A failed listing fetch prepares nothing; the end tries once more, then stays.
    @Test func listingFailureStaysAtEnd() async {
        a.episodes.state.withLock { $0.error = .notFound }
        await a.play("P", episode: "e1")

        await a.finish()

        #expect(a.episodes.fetches == 2)
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
        #expect(a.activity.active == 0)
    }

    /// The coordinator holds the advancer weakly, and detaching unhooks the queue.
    @Test func advancerIsNotRetainedAndDetachUnhooksQueue() async throws {
        let h = try CoordinatorHarness()
        let queue = PlaybackQueue(serverConnectionID: h.connectionID, store: AdvanceQueueStore())
        weak var released: PlaybackQueueAdvancer?
        do {
            let advancer = PlaybackQueueAdvancer(queue: queue, episodes: nil)
            released = advancer
            advancer.attach(to: h.coordinator)
            await h.coordinator.play(itemID: "A")
            await advancer.waitForPreparation()
            advancer.detach(from: h.coordinator)
            #expect(queue.onItemsChange == nil)
        }
        #expect(released == nil)
        #expect(h.coordinator.nextItemProvider == nil)
    }
}
