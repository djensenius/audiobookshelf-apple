import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// What happens when an item ends (P2-13): which item follows, what is left to do, and what
/// cancels it.
@MainActor
struct AutoAdvanceTests {
    let a: AdvanceHarness
    var coordinator: PlaybackCoordinator { a.coordinator }

    init() throws {
        a = try AdvanceHarness()
    }

    // MARK: - What plays next

    /// #160: with the next item prepared, only `/play` and loading the stream are left after the end.
    @Test func advanceAfterEndOnlyStartsAndLoadsWhenPrepared() async {
        a.enqueue("B")
        await a.play("A")
        let before = a.fetches
        let resolutions = a.service.state.withLock { $0.resolutions }
        let logStart = a.service.log.count

        let atLoad = await a.finish()

        #expect(atLoad == before)
        #expect(a.service.state.withLock { $0.resolutions } == resolutions + 1)
        #expect(a.h.engine.loads.count == 2)
        #expect(
            Array(a.service.log[logStart...]) == [
                "begin activity", "close A-1", "close A-1 done", "start B", "end activity",
            ])
        #expect(coordinator.mediaKey == a.key("B"))
        #expect(coordinator.isPlaying)
        #expect(a.queue.items.isEmpty)
        #expect(a.activity.active == 0)
    }

    @Test func advancePlaysQueueInOrderEvenFinishedItems() async {
        a.h.setServerProgress("B", time: 3600, updated: a.h.clock.ago(60), finished: true)
        a.enqueue("B", "C")
        await a.play("A")

        await a.finish()
        #expect(coordinator.mediaKey == a.key("B"))
        #expect(a.queue.items.map(\.libraryItemID) == ["C"])
        await a.advancer.waitForPreparation()
        await a.finish()
        #expect(coordinator.mediaKey == a.key("C"))
        #expect(a.service.starts == ["A", "B", "C"])
    }

    /// M4: the resume rule applies as to any play: finished media from the start, otherwise the
    /// newest progress rewound by its age (2 min: 10 s).
    @Test func advancedItemsStartWhereTheResumeRuleSays() async {
        a.h.setServerProgress("B", time: 1200, updated: a.h.clock.ago(120))
        a.h.setServerProgress("C", time: 3600, updated: a.h.clock.ago(120), finished: true)
        a.enqueue("B", "C")
        await a.play("A")

        await a.finish()
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.h.engine.loads.map(\.time) == [0, 1190, 0])
    }

    /// M4: listening to B locally after it was prepared wins over the prepared server progress.
    @Test func localProgressAfterPreparationWins() async throws {
        a.h.setServerProgress("B", time: 300, updated: a.h.clock.ago(3600))
        a.enqueue("B")
        await a.play("A")
        try await a.h.setLocalProgress("B", time: 900, updated: a.h.clock.now)

        await a.finish()

        #expect(a.h.engine.loads.last?.time == 900)
    }

    @Test func advanceFallsBackToNextUnfinishedEpisodeSkippingFinished() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3", "e4"], finished: ["e1", "e3"])
        await a.play("P", episode: "e2")

        await a.finish()

        #expect(coordinator.mediaKey == a.key("P", episode: "e4"))
        #expect(a.activity.active == 0)
    }

    /// An ended episode isn't proposed again before its finish reaches the server.
    @Test func advanceSkipsEpisodesThatEndedHere() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()
        #expect(coordinator.mediaKey == a.key("P", episode: "e2"))
        await a.advancer.waitForPreparation()

        await a.finish()

        #expect(coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    /// L5: once an episode that ended here changes again (marked unfinished), it may be next.
    @Test func episodeChangedAfterEndingHereIsNoLongerSkipped() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()
        await a.advancer.waitForPreparation()

        a.advancer.progressDidChange(for: a.key("P", episode: "e1"))
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// Marked unfinished while nothing is loaded: still no longer skipped once playing again.
    @Test func episodeChangedWhileStoppedIsNoLongerSkipped() async {
        a.episodes.set("P", episodes: ["e1", "e2"], finished: ["e2"])
        await a.play("P", episode: "e1")
        await a.finish()
        coordinator.stop()

        a.advancer.progressDidChange(for: a.key("P", episode: "e1"))
        await a.play("P", episode: "e2")
        await a.finish()

        #expect(coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    @Test func advanceStaysAtEndWhenAllEpisodesFinished() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1", "e3"])
        await a.play("P", episode: "e2")

        await a.finish()

        #expect(coordinator.mediaKey == a.key("P", episode: "e2"))
        #expect(a.h.events.events.last == .ended)
        #expect(a.service.starts == ["P"])
        #expect(a.activity.active == 0)
    }

    @Test func queuedItemBeatsPodcastFallback() async {
        a.episodes.set("P", episodes: ["e1", "e2"])
        a.enqueue("B")
        await a.play("P", episode: "e1")

        await a.finish()

        #expect(coordinator.mediaKey == a.key("B"))
        #expect(a.episodes.fetches == 0)
    }

    @Test func booksWithoutQueueStayAtEnd() async throws {
        let plain = try AdvanceHarness(podcastFallback: false)
        await plain.play("A")

        await plain.finish()

        #expect(plain.coordinator.mediaKey == plain.key("A"))
        #expect(plain.service.starts == ["A"])
        #expect(plain.activity.active == 0)
    }

    // MARK: - What cancels it

    /// The sleep timer pauses from its `.ended` observer: no advance, so no activity either.
    @Test func pauseFromEndedObserverCancelsAdvance() async {
        a.enqueue("B")
        await a.play("A")
        _ = coordinator.addObserver { [coordinator] event in
            if event == .ended { coordinator.pause() }
        }

        await a.finish()

        #expect(coordinator.mediaKey == a.key("A"))
        #expect(a.service.starts == ["A"])
        #expect(a.queue.items.map(\.libraryItemID) == ["B"])
        #expect(a.activity.begun.isEmpty)
    }

    enum UserAction: CaseIterable { case pause, seek, play, blockedPlay, stop }

    /// The user acting while the next item is still being prepared cancels the advance.
    @Test(arguments: UserAction.allCases)
    func userActionDuringSlowAdvanceCancelsIt(_ action: UserAction) async {
        a.episodes.set("P", episodes: ["e1", "e2"])
        let gate = Gate()
        a.episodes.state.withLock { $0.gate = gate }
        await coordinator.play(itemID: "P", episodeID: "e1")
        a.h.engine.finish()
        #expect(a.activity.active == 1)

        switch action {
        case .pause: coordinator.pause()
        case .seek: _ = await coordinator.seek(to: 100)
        case .play: await coordinator.play(itemID: "Z")
        case .blockedPlay:
            a.h.policy.decision = .denied(.cellular)
            await coordinator.play(itemID: "Z")
            a.h.policy.decision = .allowed
        case .stop: coordinator.stop()
        }
        gate.open()
        await coordinator.waitForAutoAdvance()

        #expect(a.service.starts == (action == .play ? ["P", "Z"] : ["P"]))
        #expect(a.activity.begun.count == 1)
        #expect(a.activity.active == 0)
        if action == .blockedPlay { #expect(coordinator.error == .streamingNotAllowed(.cellular, key: a.key("Z"))) }
    }

    @Test func detachCancelsAdvanceInFlight() async {
        a.episodes.set("P", episodes: ["e1", "e2"])
        let gate = Gate()
        a.episodes.state.withLock { $0.gate = gate }
        await coordinator.play(itemID: "P", episodeID: "e1")
        a.h.engine.finish()

        a.advancer.detach(from: coordinator)
        gate.open()
        await coordinator.waitForAutoAdvance()

        #expect(a.service.starts == ["P"])
        #expect(coordinator.nextItemProvider == nil)
        #expect(a.activity.active == 0)
    }

    /// A detach once `/play` is under way leaves the start to finish as an ordinary play.
    @Test func detachDuringTheStartLetsItFinish() async {
        a.enqueue("B")
        await a.play("A")
        let gate = Gate()
        a.service.state.withLock { $0.startGates["B"] = gate }
        a.h.engine.finish()
        await yieldUntil { a.service.starts == ["A", "B"] }

        a.advancer.detach(from: coordinator)
        gate.open()
        await coordinator.waitForAutoAdvance()

        #expect(coordinator.mediaKey == a.key("B"))
        #expect(coordinator.phase == .loaded)
        #expect(a.activity.active == 0)
    }

    /// Nobody can agree to stream at the lock screen: the item stays queued, never auto-consented.
    @Test(arguments: [NetworkDecision.denied(.cellular), .askUser(.lowDataMode)])
    func blockedAdvanceKeepsItemQueued(_ decision: NetworkDecision) async {
        a.enqueue("B")
        await a.play("A")
        let checks = a.h.policy.checks
        a.h.policy.currentDecision = decision

        await a.finish()

        #expect(a.h.policy.checks == checks)
        #expect(a.service.starts == ["A"])
        #expect(a.queue.items.map(\.libraryItemID) == ["B"])
        #expect(coordinator.error?.isStreamingBlocked(for: a.key("B")) == true)
        #expect(a.activity.active == 0)
    }

    /// The prepared decision is stale: prepared on cellular ("ask"), allowed now (Wi-Fi joined).
    @Test func preparedAskUserAdvancesWhenNowAllowed() async {
        a.enqueue("B")
        await a.play("A")
        a.h.policy.decision = .askUser(.cellular)
        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()
        a.h.policy.currentDecision = .allowed

        await a.finish()

        #expect(coordinator.mediaKey == a.key("B"))
        #expect(coordinator.error == nil)
    }

    /// L3: B left the queue while the ended session's close was in flight: no `/play` for it.
    @Test func itemRemovedDuringTheCloseWaitIsNotStarted() async {
        a.enqueue("B")
        await a.play("A")
        let gate = Gate()
        a.service.state.withLock { $0.closeGates["A-1"] = gate }
        a.h.engine.finish()
        await yieldUntil { a.service.closes == ["A-1"] }

        a.queue.remove(a.key("B"))
        gate.open()
        await coordinator.waitForAutoAdvance()

        #expect(a.service.starts == ["A"])
        #expect(coordinator.phase == .unloaded)
        #expect(a.activity.active == 0)
    }

    // MARK: - Background activity

    enum Failure: CaseIterable { case start, stream }

    @Test(arguments: Failure.allCases)
    func activityEndsWhenAdvanceFails(_ failure: Failure) async throws {
        a.enqueue("B")
        await a.play("A")
        a.service.state.withLock {
            switch failure {
            case .start: $0.startError = .forbidden(message: nil)
            case .stream: $0.resolveError = StreamResolutionError.missingAccessToken
            }
        }

        await a.finish()

        #expect(a.service.starts == ["A", "B"])
        #expect(coordinator.error != nil)
        #expect(a.activity.begun.count == 1)
        #expect(a.activity.active == 0)
        let begin = try #require(a.service.log.firstIndex(of: "begin activity"))
        let start = try #require(a.service.log.firstIndex(of: "start B"))
        #expect(begin < start)
    }
}

extension PlaybackCoordinatorError {
    fileprivate func isStreamingBlocked(for key: MediaKey) -> Bool {
        switch self {
        case .streamingNotAllowed(_, let blocked), .streamingNeedsConfirmation(_, let blocked): blocked == key
        default: false
        }
    }
}
