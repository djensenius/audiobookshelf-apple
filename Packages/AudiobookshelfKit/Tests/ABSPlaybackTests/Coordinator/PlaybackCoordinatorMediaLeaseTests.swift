import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// The coordinator's side of ``MediaLeases`` (#368): a closing session holds its media until the
/// close settles, and a start waits for a progress action on its media.
@MainActor
struct PlaybackCoordinatorMediaLeaseTests {
    let leases = MediaLeases()
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }

    init() throws {
        h = try CoordinatorHarness(mediaLeases: leases)
    }

    @Test func aClosingSessionHoldsItsMediaUntilItsCloseSettles() async {
        await coordinator.play(itemID: "A")
        #expect(!leases.isHeld(h.key("A"), by: .closingSession))
        let gate = Gate()
        h.service.state.withLock { $0.closeGates["A-1"] = gate }

        coordinator.stop()
        // The player is closed, but the close is still in flight.
        #expect(coordinator.mediaKey == nil)
        #expect(leases.isHeld(h.key("A"), by: .closingSession))
        await yieldUntil { h.service.closes == ["A-1"] }
        #expect(leases.isHeld(h.key("A"), by: .closingSession))

        gate.open()
        await yieldUntil { !leases.isHeld(h.key("A"), by: .closingSession) }
    }

    /// The closing session's `/sync` in flight outlasts the close's wait (#337): `/close` goes out
    /// and returns and the position saves, but the media stays held until that `/sync` returns.
    @Test func aClosingSessionHoldsItsMediaUntilItsSyncInFlightReturns() async throws {
        let report = try #require(PlaybackSyncReport(currentTime: 30, timeListened: 0, duration: 3600))
        let position = PlaybackCloseResult<Void>()
        let sync = PlaybackCloseResult<Void>()
        coordinator.finalCloseReport = { _ in
            PlaybackCloseHandoff(report: report, position: position, sessionSync: sync)
        }
        await coordinator.play(itemID: "A")
        h.sleep.elapsesImmediately = true

        coordinator.stop()
        await yieldUntil { h.service.closes == ["A-1"] }
        position.resolve(.success(()))
        await coordinator.waitForPendingCloses()
        for _ in 0..<50 { await Task.yield() }
        #expect(leases.isHeld(h.key("A"), by: .closingSession))

        sync.resolve(.success(()))
        await yieldUntil { !leases.isHeld(h.key("A"), by: .closingSession) }
    }

    /// A position whose save failed ends the hold too, so a lease never outlives its receipts: the
    /// syncer's later retry of it is superseded by the action instead (#368).
    @Test func aFailedPositionSaveStillEndsTheHold() async throws {
        let report = try #require(PlaybackSyncReport(currentTime: 30, timeListened: 0, duration: 3600))
        let position = PlaybackCloseResult<Void>()
        coordinator.finalCloseReport = { _ in PlaybackCloseHandoff(report: report, position: position) }
        await coordinator.play(itemID: "A")

        coordinator.stop()
        await coordinator.waitForPendingCloses()
        for _ in 0..<50 { await Task.yield() }
        // Negative control: still held while the save is pending.
        #expect(leases.isHeld(h.key("A"), by: .closingSession))
        position.resolve(.failure(CocoaError(.fileWriteNoPermission)))
        await yieldUntil { !leases.isHeld(h.key("A"), by: .closingSession) }
    }

    /// The server reused the ID of a session whose close is pending: the replacement sends no
    /// second `/close`, but its own `/sync` in flight keeps its media held after the original close
    /// settles, so a discard waits for it.
    @Test func aReusedSessionIDStillHoldsItsMediaUntilItsOwnSyncReturns() async throws {
        await coordinator.play(itemID: "A")
        h.sleep.elapsesImmediately = true
        let gate = Gate()
        h.service.state.withLock { $0.closeGates["A-1"] = gate }
        coordinator.stop()
        await yieldUntil { h.service.closes == ["A-1"] }

        h.service.state.withLock { $0.count = 0 }
        await coordinator.play(itemID: "A")
        let report = try #require(PlaybackSyncReport(currentTime: 30, timeListened: 0, duration: 3600))
        let position = PlaybackCloseResult<Void>()
        let sync = PlaybackCloseResult<Void>()
        coordinator.finalCloseReport = { _ in
            PlaybackCloseHandoff(report: report, position: position, sessionSync: sync)
        }
        coordinator.stop()
        position.resolve(.success(()))
        gate.open()
        await coordinator.waitForPendingCloses()

        let discard = Task { await leases.acquire(h.key("A"), for: .progressAction, after: .closingSession) }
        for _ in 0..<50 { await Task.yield() }
        #expect(leases.isHeld(h.key("A"), by: .closingSession))
        #expect(!leases.isHeld(h.key("A"), by: .progressAction))

        sync.resolve(.success(()))
        let lease = await discard.value
        #expect(leases.isHeld(h.key("A"), by: .progressAction))
        lease.release()
        #expect(h.service.closes == ["A-1"])
    }

    /// The next item's progress was discarded or reset after its preparation: the auto-advance
    /// fetches it again and starts at the fresh position, not the prepared one. Without an action
    /// in between, the prepared progress is used as is.
    @Test(arguments: [ProgressAction.discard, .reset, nil])
    func anAutoAdvanceRefetchesProgressAnActionChangedSinceItsPreparation(action: ProgressAction?) async {
        let advancer = await playAWithBPrepared()
        let reads = h.service.state.withLock { $0.progressReads.count }

        if let action { apply(action, to: "B") }
        h.engine.finish()
        await coordinator.waitForAutoAdvance()

        #expect(coordinator.mediaKey == h.key("B"))
        #expect(h.engine.loads.last?.time == (action == nil ? 2400 : 0))
        #expect(h.service.state.withLock { $0.progressReads.count } == reads + (action == nil ? 0 : 1))
        withExtendedLifetime(advancer) {}
    }

    /// A near-end refresh of B's preparation, after the action, is still running when A ends: the
    /// advance's item change cancels it, and it completes while the advance waits for A's close.
    /// The advance starts from the older preparation the advancer kept, which predates the action,
    /// so it fetches B's progress again even though the refresh's own preparation is newer.
    @Test(arguments: [ProgressAction.discard, .reset, nil])
    func aRefreshCompletingDuringTheCloseWaitDoesntValidateAnOlderPreparation(action: ProgressAction?) async {
        let advancer = await playAWithBPrepared()
        if let action { apply(action, to: "B") }

        let refresh = Gate()
        h.policy.gate = refresh
        let checks = h.policy.checks
        h.engine.onEvent?(.tick(1500))
        await yieldUntil { h.policy.checks == checks + 1 }
        let close = Gate()
        h.service.state.withLock { $0.closeGates["A-1"] = close }

        h.engine.finish()
        let advance = Task { await coordinator.waitForAutoAdvance() }
        await yieldUntil { h.service.closes == ["A-1"] }
        refresh.open()
        await yieldUntil { h.policy.returns == checks + 1 }
        for _ in 0..<20 { await Task.yield() }
        close.open()
        await advance.value

        #expect(coordinator.mediaKey == h.key("B"))
        #expect(h.engine.loads.last?.time == (action == nil ? 2400 : 0))
        withExtendedLifetime(advancer) {}
    }

    enum ProgressAction: Sendable {
        case discard, reset
    }

    /// Plays A with B queued after it at 2400 on the server, and waits for B's preparation.
    private func playAWithBPrepared() async -> PlaybackQueueAdvancer {
        let queue = PlaybackQueue(serverConnectionID: h.connectionID, store: AdvanceQueueStore())
        let clock = h.clock
        let advancer = PlaybackQueueAdvancer(queue: queue, episodes: nil, uptime: { clock.now.timeIntervalSince1970 })
        advancer.attach(to: coordinator)
        queue.addToEnd(QueueItem(libraryItemID: "B", episodeID: nil, title: "B"))
        setFetchedProgress("B", time: 2400)
        await coordinator.play(itemID: "A")
        await advancer.waitForPreparation()
        return advancer
    }

    /// The server side of a discard or reset of `itemID`, under its action's lease.
    private func apply(_ action: ProgressAction, to itemID: String) {
        let lease = leases.acquire(h.key(itemID), for: .progressAction)
        h.service.state.withLock { $0.progress[itemID] = nil }
        if action == .reset { setFetchedProgress(itemID, time: 0) }
        lease.release()
    }

    /// Server progress from `GET /api/me/progress` only (not in `/play`'s session), updated now.
    private func setFetchedProgress(_ itemID: String, time: Double) {
        let updated = Int(h.clock.now.timeIntervalSince1970 * 1000)
        h.service.state.withLock {
            $0.progress[itemID] = MediaProgress(
                id: "p-\(itemID)", libraryItemId: itemID, duration: 3600, currentTime: time, lastUpdate: updated)
        }
    }

    @Test func switchingItemsHoldsTheOutgoingItemUntilItsCloseSettles() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        h.service.state.withLock { $0.closeGates["A-1"] = gate }

        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { h.service.closes == ["A-1"] }
        #expect(leases.isHeld(h.key("A"), by: .closingSession))
        #expect(!leases.isHeld(h.key("B"), by: .closingSession))
        gate.open()
        await playB.value
        await yieldUntil { !leases.isHeld(h.key("A"), by: .closingSession) }
    }

    @Test func aStartWaitsForAProgressActionOnItsMedia() async {
        let action = leases.acquire(h.key("A"), for: .progressAction)
        // Negative control: an action on another item doesn't hold this one's start.
        let other = leases.acquire(h.key("B"), for: .progressAction)
        defer { other.release() }

        let play = Task { await coordinator.play(itemID: "A") }
        for _ in 0..<50 { await Task.yield() }
        #expect(h.service.starts.isEmpty)

        action.release()
        await play.value
        #expect(h.service.starts == ["A"])
        #expect(coordinator.isPlaying)
    }

    @Test func aClosingSessionDoesntHoldAStartOfItsMedia() async {
        // Only progress actions hold a start: playing an item again right after closing it starts.
        let closing = leases.acquire(h.key("A"), for: .closingSession)
        defer { closing.release() }
        await coordinator.play(itemID: "A")
        #expect(h.service.starts == ["A"])
    }
}

// MARK: - MediaLeases

@MainActor
private final class Flag {
    var value = false
}

@MainActor
struct MediaLeasesTests {
    let leases = MediaLeases()
    let a = MediaKey(serverConnectionID: UUID(), libraryItemId: "a")

    @Test func aLeaseHoldsItsKeyForItsHolderUntilReleased() {
        let lease = leases.acquire(a, for: .closingSession)
        #expect(leases.isHeld(a, by: .closingSession))
        #expect(!leases.isHeld(a, by: .progressAction))
        #expect(!leases.isHeld(MediaKey(serverConnectionID: UUID(), libraryItemId: "a"), by: .closingSession))

        lease.release()
        lease.release()
        #expect(!leases.isHeld(a, by: .closingSession))
    }

    @Test func theActionGenerationChangesAsAProgressActionTakesAndReleasesItsKey() {
        let closing = leases.acquire(a, for: .closingSession)
        closing.release()
        #expect(leases.actionGeneration(of: a) == 0)

        let action = leases.acquire(a, for: .progressAction)
        let held = leases.actionGeneration(of: a)
        #expect(held != 0)
        action.release()
        action.release()
        #expect(leases.actionGeneration(of: a) == held + 1)
        #expect(leases.actionGeneration(of: MediaKey(serverConnectionID: UUID(), libraryItemId: "a")) == 0)
    }

    @Test func waitingEndsOnceEveryLeaseOfTheHolderIsReleased() async {
        let first = leases.acquire(a, for: .closingSession)
        let second = leases.acquire(a, for: .closingSession)
        let done = Flag()
        let wait = Task {
            await leases.waitUntilFree(a, of: .closingSession)
            done.value = true
        }
        for _ in 0..<20 { await Task.yield() }
        first.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(!done.value)

        second.release()
        await wait.value
        #expect(done.value)
    }

    @Test func acquiringAfterAnotherHolderWaitsForIt() async {
        let closing = leases.acquire(a, for: .closingSession)
        let action = Task { await leases.acquire(a, for: .progressAction, after: .closingSession) }
        for _ in 0..<20 { await Task.yield() }
        #expect(!leases.isHeld(a, by: .progressAction))

        closing.release()
        let lease = await action.value
        #expect(leases.isHeld(a, by: .progressAction))
        lease.release()
    }

    @Test func cancellingEndsTheWait() async {
        let lease = leases.acquire(a, for: .progressAction)
        defer { lease.release() }
        let wait = Task { await leases.waitUntilFree(a, of: .progressAction) }
        for _ in 0..<20 { await Task.yield() }
        wait.cancel()
        await wait.value
        #expect(leases.isHeld(a, by: .progressAction))
    }
}
