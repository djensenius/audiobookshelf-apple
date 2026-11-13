import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSPlayback

/// When the next item is prepared (#160): on load, once on entering the last chapter and once in the
/// last seconds (re-armed by a resume or a seek away), and when the queue, the next item's progress
/// or the connection change.
@MainActor
struct AutoAdvancePreparationTests {
    let a: AdvanceHarness

    init() throws {
        a = try AdvanceHarness()
    }

    private var progressReads: [MediaKey] { a.service.state.withLock { $0.progressReads } }

    private func tick(_ time: Double) async {
        a.h.engine.onEvent?(.tick(time))
        await a.advancer.waitForPreparation()
    }

    /// The stub's last chapter starts at 1000 of 3600.
    @Test func preparesOnLoadedThenOnceInTheLastChapterAndOnceInTheLastSeconds() async {
        a.enqueue("B")
        await a.play("A")
        #expect(progressReads == [a.key("A"), a.key("B")])
        #expect(a.h.policy.checks == 2)

        await tick(500)
        #expect(progressReads.count == 2)
        await tick(1500)
        await tick(2000)
        #expect(progressReads.count == 3)
        await tick(3580)
        await tick(3590)
        #expect(progressReads == [a.key("A"), a.key("B"), a.key("B"), a.key("B")])
        #expect(a.h.policy.checks == 4)
    }

    /// A seek out of the last chapter re-arms its refresh; one inside the window doesn't.
    @Test func seekAwayRearmsTheNearEndRefresh() async {
        a.enqueue("B")
        await a.play("A")
        _ = await a.coordinator.seek(to: 3580)
        await tick(3580)
        #expect(progressReads.count == 3)

        _ = await a.coordinator.seek(to: 3585)
        await tick(3590)
        #expect(progressReads.count == 3)

        _ = await a.coordinator.seek(to: 100)
        await tick(1500)
        #expect(progressReads.count == 4)
    }

    /// H1: refreshed near the end, then paused while B moved on elsewhere: resuming refreshes at
    /// once, so B starts from its new progress.
    @Test func resumeInsideTheWindowRefreshesAtOnce() async {
        a.enqueue("B")
        await a.play("A")
        _ = await a.coordinator.seek(to: 3580)
        await tick(3580)
        a.coordinator.pause()
        a.h.clock.advance(by: 300)
        a.setFetchedProgress("B", time: 2400)

        await a.coordinator.resume()
        await a.advancer.waitForPreparation()
        #expect(progressReads.count == 4)

        let before = a.fetches
        #expect(await a.finish() == before)
        #expect(a.h.engine.loads.last?.time == 2400)
    }

    /// A preparation older than ``PlaybackQueueAdvancer/maximumPreparationAge`` is redone at the
    /// end, listing included: e2 was finished elsewhere meanwhile.
    @Test(arguments: [599.0, 601.0])
    func oldPreparationIsRedoneAtTheEnd(age: TimeInterval) async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        a.h.clock.advance(by: age)
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e2"])
        a.setFetchedProgress("P", time: 2400)
        let before = a.fetches

        let atLoad = await a.finish()

        let isStale = age > PlaybackQueueAdvancer.maximumPreparationAge
        #expect(atLoad?.progress == before.progress + (isStale ? 1 : 0))
        #expect(atLoad?.listings == before.listings + (isStale ? 1 : 0))
        #expect(a.coordinator.mediaKey == a.key("P", episode: isStale ? "e3" : "e2"))
        #expect(a.h.engine.loads.last?.time == (isStale ? 2400 : 0))
        #expect(a.activity.active == 0)
    }

    /// Finding no next episode ages like a preparation: an old finding is redone with a new
    /// listing (e2 was marked unfinished elsewhere meanwhile).
    @Test(arguments: [599.0, 601.0])
    func oldFindingOfNoneIsRedoneAtTheEnd(age: TimeInterval) async {
        a.episodes.set("P", episodes: ["e1", "e2"], finished: ["e2"])
        await a.play("P", episode: "e1")
        a.h.clock.advance(by: age)
        a.episodes.set("P", episodes: ["e1", "e2"])

        await a.finish()

        let isStale = age > PlaybackQueueAdvancer.maximumPreparationAge
        #expect(a.coordinator.mediaKey == a.key("P", episode: isStale ? "e2" : "e1"))
        #expect(a.activity.active == 0)
    }

    /// M4: a preparation that a newer one overtook is dropped when it finally returns.
    @Test func overtakenPreparationIsDropped() async {
        a.enqueue("B")
        await a.play("A")
        let gate = Gate()
        a.h.policy.gate = gate
        a.setFetchedProgress("B", time: 1000)
        a.advancer.connectionDidChange()
        await yieldUntil { a.h.policy.checks == 3 }
        a.setFetchedProgress("B", time: 2000)
        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()

        gate.open()
        await yieldUntil { a.h.policy.returns == 4 }
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("B"))
        #expect(a.h.engine.loads.last?.time == 2000)
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
        a.advancer.progressDidChange(for: a.key("P", episode: "e2"), kind: .updated)
        await a.advancer.waitForPreparation()
        #expect(a.episodes.fetches == 2)
        #expect(progressReads.last == a.key("P", episode: "e3"))

        // Unrelated progress, or the current episode's own, changes nothing.
        a.advancer.progressDidChange(for: a.key("Other"), kind: .updated)
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .updated)
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

    /// #554: e2 was finished elsewhere while this device was offline. The connection change
    /// fetches the podcast's episodes again, so the end advances to e3 on that preparation.
    @Test func connectionChangeFetchesTheListingAgain() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e2"])
        let listings = a.episodes.fetches

        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()

        #expect(a.episodes.fetches == listings + 1)
        let before = a.fetches
        #expect(await a.finish() == before)
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
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
