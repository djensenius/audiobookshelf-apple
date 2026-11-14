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

        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .finished)
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// Any other change to an episode that ended here (hidden from Continue Listening, a new
    /// position) keeps it skipped: its finish may not have reached the server yet (#554).
    @Test func episodeUpdatedAfterEndingHereStaysSkipped() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()
        await a.advancer.waitForPreparation()

        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .updated)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    /// Marked unfinished while nothing is loaded: still no longer skipped once playing again.
    @Test func episodeChangedWhileStoppedIsNoLongerSkipped() async {
        a.episodes.set("P", episodes: ["e1", "e2"], finished: ["e2"])
        await a.play("P", episode: "e1")
        await a.finish()
        coordinator.stop()

        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .finished)
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.play("P", episode: "e2")
        await a.finish()

        #expect(coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// A reset before the server has shown the finish of an episode that ended here keeps it
    /// skipped: a seed dropping progress never synced, a stale socket update or a rolled-back
    /// action resets it while the listing still lacks the finish (#554).
    @Test func resetBeforeTheFinishIsConfirmedKeepsTheEpisodeSkipped() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()
        await a.advancer.waitForPreparation()

        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    /// A refreshed listing, requested after the end, that has the episode finished on the server
    /// confirms the finish without a cache change: a discard after it makes the episode eligible
    /// again (#554).
    @Test func listingConfirmedFinishLetsALaterResetCount() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e2"))

        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": Date()])
        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// A listing finished only by a local unsynced flag, or by the server without a date, is no
    /// confirmation: the episode stays skipped after a reset.
    @Test func listingFinishedOnlyLocallyConfirmsNothing() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()

        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"])
        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    /// Server finish times far behind this device's clock (2000), around it, and far ahead of it
    /// (2100): only server times are compared, so the outcome doesn't depend on the device clock.
    nonisolated static let serverTimes = [
        Date(timeIntervalSince1970: 946_684_800), Date(timeIntervalSinceNow: -3600),
        Date(timeIntervalSince1970: 4_102_444_800),
    ]

    /// Played again after the server finished it: a listing after the new end with the old finish
    /// (the baseline seen while it played) confirms nothing, so a late reset (the replay's
    /// unfinished sync) keeps it skipped (#554).
    @Test(arguments: serverTimes)
    func oldServerFinishDoesntConfirmAReplaysEnd(finishedAt: Date) async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": finishedAt])
        await a.play("P", episode: "e1")
        await a.finish()
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e2"))

        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    /// Played again after the server finished it: a listing after the new end with a later
    /// server finish than the baseline confirms it, so a discard after it counts (#554).
    @Test(arguments: serverTimes)
    func laterServerFinishConfirmsAReplaysEnd(finishedAt: Date) async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": finishedAt])
        await a.play("P", episode: "e1")
        await a.finish()
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e2"))

        a.episodes.set(
            "P", episodes: ["e1", "e2", "e3"], finished: ["e1"],
            serverFinishedAt: ["e1": finishedAt.addingTimeInterval(60)])
        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// Plays e1 again, finished on the server at `finishedAt` as the progress store also holds it,
    /// either with e2 queued, so no listing is fetched while e1 plays, or attaching to it mid-play;
    /// e2's listing has e1 finished at `listedFinishedAt`. Then resets e1 and returns what follows
    /// e2 (#587).
    private func replayWithoutListingBaseline(
        finishedAt: Date, listedFinishedAt: Date, attach: Bool
    ) async -> MediaKey? {
        let e1 = a.key("P", episode: "e1")
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": finishedAt])
        a.cachedFinishes.set(e1, finishedAt)
        if !attach { a.queue.addToEnd(QueueItem(libraryItemID: "P", episodeID: "e2", title: "e2")) }
        await a.play("P", episode: "e1")
        if attach {
            a.advancer.detach(from: coordinator)
            a.advancer.attach(to: coordinator)
            await a.advancer.waitForPreparation()
        } else {
            #expect(a.episodes.fetches == 0)
        }
        a.episodes.set(
            "P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": listedFinishedAt])

        await a.finish()
        #expect(coordinator.mediaKey == a.key("P", episode: "e2"))
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: e1, kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()
        return coordinator.mediaKey
    }

    /// Replayed with no listing baseline (played from the queue, or attached to mid-play): its
    /// baseline is the server finish the progress store held, so a listing after the end with
    /// that finish confirms nothing and a late reset keeps it skipped (#587).
    @Test(arguments: serverTimes, [false, true])
    func cachedServerFinishIsTheBaselineWithoutAListing(finishedAt: Date, attach: Bool) async {
        let next = await replayWithoutListingBaseline(
            finishedAt: finishedAt, listedFinishedAt: finishedAt, attach: attach)

        #expect(next == a.key("P", episode: "e3"))
    }

    /// With the cached baseline, a later server finish after the end still confirms it, so a
    /// reset after it counts (#587).
    @Test(arguments: serverTimes, [false, true])
    func laterServerFinishConfirmsAnEndWithACachedBaseline(finishedAt: Date, attach: Bool) async {
        let next = await replayWithoutListingBaseline(
            finishedAt: finishedAt, listedFinishedAt: finishedAt.addingTimeInterval(60), attach: attach)

        #expect(next == a.key("P", episode: "e1"))
    }

    /// Resets e1, which ended here, and returns what follows the next episode's end (#587).
    private func resetAndFinishNext() async -> MediaKey? {
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()
        return coordinator.mediaKey
    }

    /// A cached-finish read still in flight at the end, by when this play's own finish has synced,
    /// is no baseline: a listing after the end with that finish confirms it, so a reset counts
    /// (#587).
    @Test func cachedFinishReadReturningAfterTheEndIsNoBaseline() async {
        let e1 = a.key("P", episode: "e1")
        let finishedAt = Date()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": finishedAt])
        a.queue.addToEnd(QueueItem(libraryItemID: "P", episodeID: "e2", title: "e2"))
        let gate = Gate()
        a.cachedFinishes.state.withLock { $0.gate = gate }
        await coordinator.play(itemID: "P", episodeID: "e1")
        while a.cachedFinishes.reads < 1 { await Task.yield() }

        a.cachedFinishes.set(e1, finishedAt)
        a.h.engine.finish()
        gate.open()
        await coordinator.waitForAutoAdvance()
        #expect(coordinator.mediaKey == a.key("P", episode: "e2"))

        #expect(await resetAndFinishNext() == e1)
    }

    /// Attached inside the last seconds of a replay, whose own finish has synced: that finish is
    /// no baseline, so a listing after the end with it confirms the end and a reset counts (#587).
    @Test func attachingNearTheEndTakesNoCachedBaseline() async {
        let e1 = a.key("P", episode: "e1")
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        a.advancer.detach(from: coordinator)
        _ = await coordinator.seek(to: 3590)
        let finishedAt = Date()
        a.cachedFinishes.set(e1, finishedAt)
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": finishedAt])

        a.advancer.attach(to: coordinator)
        await a.advancer.waitForPreparation()
        #expect(a.cachedFinishes.reads == 1)
        await a.finish()
        #expect(coordinator.mediaKey == a.key("P", episode: "e2"))

        #expect(await resetAndFinishNext() == e1)
    }

    /// Loaded inside the last seconds, with a cached-finish read that would return this play's
    /// own synced finish before the end: no cached baseline is taken, so a listing after the end
    /// with that finish confirms the end and a reset counts (#587).
    @Test func loadingNearTheEndTakesNoCachedBaseline() async {
        let e1 = a.key("P", episode: "e1")
        let finishedAt = Date()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": finishedAt])
        a.queue.addToEnd(QueueItem(libraryItemID: "P", episodeID: "e2", title: "e2"))
        let gate = Gate()
        a.cachedFinishes.state.withLock { $0.gate = gate }
        await coordinator.play(itemID: "P", episodeID: "e1", startTime: 3590)

        a.cachedFinishes.set(e1, finishedAt)
        gate.open()
        await a.advancer.waitForPreparation()
        #expect(a.cachedFinishes.reads == 0)
        await a.finish()
        #expect(coordinator.mediaKey == a.key("P", episode: "e2"))

        #expect(await resetAndFinishNext() == e1)
    }

    /// The server's finish of an episode first seen in a near-end refresh is this play's own
    /// (synced near the end), not a baseline: a listing after the end with it confirms the end, so
    /// a discard or mark-not-finished after it makes the episode eligible again (#554).
    @Test func nearEndRefreshesFinishIsNoBaselineForTheEnd() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": Date()])
        a.h.engine.onEvent?(.tick(3590))
        await a.advancer.waitForPreparation()
        #expect(a.episodes.fetches == 2)

        await a.finish()
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e2"))
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// Opens `gate` and waits until the superseded fetch it held has returned to the advancer.
    private func release(_ gate: Gate, returns: Int) async {
        gate.open()
        while a.episodes.state.withLock({ $0.returns }) < returns { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }

    /// Waits until the fetch the advancer started has reached its gate.
    private func waitForFetch(_ count: Int) async {
        while a.episodes.fetches < count { await Task.yield() }
    }

    /// A superseded listing returning late with the episode finished confirms nothing: the
    /// episode stays skipped after a reset (#554).
    @Test func staleListingDoesntConfirmAnEnd() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        await a.play("P", episode: "e1")
        await a.finish()
        await a.advancer.waitForPreparation()
        let gate = Gate()
        a.episodes.state.withLock { $0.gate = gate }
        a.advancer.connectionDidChange()
        await waitForFetch(3)
        a.advancer.connectionDidChange()
        await a.advancer.waitForPreparation()

        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": Date()])
        await release(gate, returns: 4)
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e3"))
    }

    /// A superseded load-time listing returning late, with a finish newer than the playing
    /// episode's, sets no baseline: the same finish after the end confirms it, so a reset makes
    /// the episode eligible again (#554).
    @Test func staleListingSetsNoBaseline() async {
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        let gate = Gate()
        a.episodes.state.withLock { $0.gate = gate }
        await a.coordinator.play(itemID: "P", episodeID: "e1")
        await waitForFetch(1)
        a.advancer.progressDidChange(for: a.key("P", episode: "e2"), kind: .updated)
        await a.advancer.waitForPreparation()

        a.episodes.set("P", episodes: ["e1", "e2", "e3"], finished: ["e1"], serverFinishedAt: ["e1": Date()])
        await release(gate, returns: 2)
        await a.finish()
        #expect(a.coordinator.mediaKey == a.key("P", episode: "e2"))
        await a.advancer.waitForPreparation()
        a.episodes.set("P", episodes: ["e1", "e2", "e3"])
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.advancer.waitForPreparation()
        await a.finish()

        #expect(a.coordinator.mediaKey == a.key("P", episode: "e1"))
    }

    /// The server can show the finish while the episode is still loaded; a later reset counts.
    /// Ending it here again makes the finish unconfirmed again.
    @Test func finishConfirmedWhileLoadedCountsUntilItEndsAgain() async {
        a.episodes.set("P", episodes: ["e1", "e2"], finished: ["e2"])
        await a.play("P", episode: "e1")
        await a.finish()
        #expect(coordinator.mediaKey == a.key("P", episode: "e1"))
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .finished)
        coordinator.stop()
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.play("P", episode: "e2")
        await a.finish()
        #expect(coordinator.mediaKey == a.key("P", episode: "e1"))

        await a.finish()
        coordinator.stop()
        a.advancer.progressDidChange(for: a.key("P", episode: "e1"), kind: .reset)
        await a.play("P", episode: "e2")
        await a.finish()

        #expect(coordinator.mediaKey != a.key("P", episode: "e1"))
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

    /// #376: "Stream anyway" after a blocked advance starts the queue's next item.
    @Test func confirmingABlockedAdvanceStartsTheNextItem() async {
        a.enqueue("B")
        await a.play("A")
        a.h.policy.decision = .askUser(.cellular)
        a.h.policy.currentDecision = .askUser(.cellular)
        await a.finish()
        #expect(coordinator.error == .streamingNeedsConfirmation(.cellular, key: a.key("B")))

        await coordinator.confirmMeteredStreaming()

        #expect(a.service.starts == ["A", "B"])
        #expect(coordinator.mediaKey == a.key("B"))
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
        #expect(a.queue.items.isEmpty)
    }

    /// #543: consent to stream A on a metered network is A's own play's. Auto-advancing A → B → A
    /// on an allowed network drops it, so A's recovery rebuild on a metered network asks again.
    @Test func anAutoAdvanceBackToAnItemDoesNotReuseItsMeteredConsent() async {
        a.h.recoverySleep.elapsesImmediately = true
        a.enqueue("B")
        a.h.policy.decision = .askUser(.cellular)
        await coordinator.play(itemID: "A")
        await coordinator.confirmMeteredStreaming()
        #expect(coordinator.isPlaying)
        a.h.policy.decision = .allowed
        await a.advancer.waitForPreparation()

        await a.finish()
        #expect(coordinator.mediaKey == a.key("B"))
        a.enqueue("A")
        await a.advancer.waitForPreparation()
        await a.finish()
        #expect(coordinator.mediaKey == a.key("A"))
        #expect(a.service.starts == ["A", "B", "A"])

        a.h.policy.decision = .askUser(.cellular)
        a.h.engine.fail(.itemFailed(trackIndex: 0, Self.networkFailure))
        for _ in 0..<20_000 where coordinator.error == nil && a.service.starts.count == 3 { await Task.yield() }

        #expect(coordinator.error == .streamingNeedsConfirmation(.cellular, key: a.key("A")))
        #expect(a.service.starts == ["A", "B", "A"])
    }

    private static let networkFailure = PlaybackFailure(
        kind: .network, domain: "CoreMediaErrorDomain", code: -12938, description: "fixture")

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

    /// #338: B left the queue while the ended session's close was in flight: no `/play` for it,
    /// and A is selected again, unloaded at its end, rather than the removed B.
    @Test func itemRemovedDuringTheCloseWaitIsNotStarted() async {
        a.enqueue("B")
        await a.play("A")
        let before = a.fetches

        await removeBDuringTheCloseWait {}

        #expect(a.service.starts == ["A"])
        #expect(a.fetches == before)
        #expect(coordinator.mediaKey == a.key("A"))
        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.currentTime == 3600)
        #expect(coordinator.error == nil)
        #expect(a.h.events.events.last == .itemChanged(a.key("A")))
        #expect(a.activity.active == 0)
    }

    /// #338: a play for C still in its policy check when B's start gives up wins over the return to A.
    @Test func playRequestedDuringTheCloseWaitStillStarts() async {
        a.enqueue("B")
        await a.play("A")
        let policyGate = Gate()
        a.h.policy.gate = policyGate
        var playing: Task<Void, Never>?

        await removeBDuringTheCloseWait {
            playing = Task { await coordinator.play(itemID: "C") }
            await yieldUntil { coordinator.pendingPlayKey == a.key("C") }
        }
        policyGate.open()
        await playing?.value

        #expect(a.service.starts == ["A", "C"])
        #expect(coordinator.mediaKey == a.key("C"))
    }

    enum PositionCommand: CaseIterable { case seek, jumpBack }

    /// #338: a seek or jump made while B was starting was for B; A stays at its end.
    @Test(arguments: PositionCommand.allCases)
    func positionCommandsForTheRemovedItemDontMoveA(_ command: PositionCommand) async {
        a.enqueue("B")
        await a.play("A")

        await removeBDuringTheCloseWait {
            switch command {
            case .seek: _ = await coordinator.seek(to: 100)
            case .jumpBack: await coordinator.jump(by: -30)
            }
        }

        #expect(coordinator.mediaKey == a.key("A"))
        #expect(coordinator.currentTime == 3600)
        await coordinator.play(itemID: "A")
        #expect(a.h.engine.loads.last?.time == 0)
    }

    /// Ends A with B next, does `action` while A's close holds B's start, then removes B.
    private func removeBDuringTheCloseWait(_ action: () async -> Void) async {
        let gate = Gate()
        a.service.state.withLock { $0.closeGates["A-1"] = gate }
        a.h.engine.finish()
        await yieldUntil { a.service.closes == ["A-1"] }
        await action()
        a.queue.remove(a.key("B"))
        gate.open()
        await coordinator.waitForAutoAdvance()
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

    /// The next item's initial seek was interrupted, so its start returns with the engine still
    /// buffering while the engine retries the seek: the activity lasts until the audio plays,
    /// or the app could be suspended first (#554).
    @Test func activityLastsUntilTheNextItemPlays() async {
        a.enqueue("B")
        await a.play("A")
        a.h.engine.interruptedLoads = 1

        a.h.engine.finish()
        await yieldUntil { coordinator.mediaKey == a.key("B") && a.h.engine.state == .buffering }
        for _ in 0..<100 { await Task.yield() }
        #expect(a.activity.active == 1)

        _ = await a.h.engine.seek(to: a.h.engine.pendingSeekTarget ?? 0)
        await coordinator.waitForAutoAdvance()

        #expect(a.h.engine.state == .playing)
        #expect(a.activity.active == 0)
    }

    /// A pause while the initial seek is pending ends the activity: nothing will play.
    @Test func activityEndsWhenPausedBeforeTheNextItemPlays() async {
        a.enqueue("B")
        await a.play("A")
        a.h.engine.interruptedLoads = 1
        a.h.engine.finish()
        await yieldUntil { coordinator.mediaKey == a.key("B") && a.h.engine.state == .buffering }

        coordinator.pause()
        await coordinator.waitForAutoAdvance()

        #expect(a.activity.begun.count == 1)
        #expect(a.activity.active == 0)
    }

    /// Another play takes over while the next item's load is suspended and loads before that
    /// start returns: the superseded advance ends its activity rather than wait on the
    /// replacement, which buffers on an interrupted seek here (#554).
    @Test func supersededAdvanceEndsActivityOnTakeover() async {
        a.enqueue("B")
        await a.play("A")
        let gate = Gate()
        a.h.engine.loadGates = [gate]
        a.h.engine.finish()
        await yieldUntil { a.h.engine.loads.count == 2 && coordinator.mediaKey == a.key("B") }

        a.h.engine.interruptedLoads = 1
        await coordinator.play(itemID: "C")
        #expect(coordinator.mediaKey == a.key("C"))
        #expect(a.h.engine.state == .buffering)
        gate.open()

        await yieldUntil { a.activity.active == 0 }
        #expect(a.activity.begun.count == 1)
        #expect(a.h.engine.state == .buffering)
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
