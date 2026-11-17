import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

/// Holds each wait until ``release()``, counting them.
@MainActor
private final class WaitGate {
    private(set) var waits = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waits += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
@Suite final class ShortcutParametersRefresherTests {
    private nonisolated let suite = "ShortcutParametersRefresherTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    /// Holds session requests.
    private let gate = WaitGate()
    /// Holds item requests.
    private let itemGate = WaitGate()
    private var updates = 0

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeRefresher() -> ShortcutParametersRefresher {
        let (gate, itemGate) = (gate, itemGate)
        return ShortcutParametersRefresher(
            sessionWait: { await gate.wait() }, itemWait: { await itemGate.wait() }
        ) { [weak self] in self?.updates += 1 }
    }

    private func context() -> SessionContext {
        SessionContext(
            identity: SessionIdentity(connectionID: FakePlaybackControl.serverID, userID: "u1"), client: nil,
            isOffline: false, sessionID: 1)
    }

    /// Lets the refresher's tasks run, so a request that would come has come.
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// Releases `gate`'s waiting requests and waits for `expected` updates in all.
    private func releaseUpdate(_ expected: Int, of gate: WaitGate? = nil) async -> Bool {
        (gate ?? self.gate).release()
        return await eventually { updates == expected }
    }

    private func makePlayer() -> (FakePlaybackControl, PlayerViewModel) {
        let playback = FakePlaybackControl()
        return (playback, PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults)))
    }

    @Test func anItemWaitsLongerThanItsFirstProgressSync() {
        #expect(ShortcutParametersRefresher.itemDelay > .seconds(ProgressSyncer.syncInterval))
    }

    @Test func aSessionsStartAndEndEachUpdate() async {
        let refresher = makeRefresher()

        await refresher.sessionDidStart(context())
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))

        await refresher.sessionWillEnd(.signOut)
        #expect(await eventually { gate.waits == 2 })
        #expect(await releaseUpdate(2))
    }

    @Test func requestsWhileOneWaitsJoinIt() async {
        let refresher = makeRefresher()

        await refresher.sessionDidStart(context())
        await refresher.sessionDidReconnect(context())
        refresher.requestUpdate()
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))
        await settle()

        #expect(gate.waits == 1)
        #expect(updates == 1)
    }

    @Test func anotherItemStartingUpdatesOnlyAfterItsWaitButProgressDoesnt() async {
        let (playback, player) = makePlayer()
        let refresher = makeRefresher()
        refresher.follow(player)

        // Restored without playing: Continue Listening hasn't changed.
        playback.load(FakePlaybackControl.bookSession(), at: 50)
        await settle()
        #expect(itemGate.waits == 0)

        playback.load(FakePlaybackControl.bookSession(), at: 50, playing: true)
        #expect(await eventually { itemGate.waits == 1 })
        // Not before the item's wait (its first sync) is over, nor through the session's.
        gate.release()
        await settle()
        #expect(updates == 0)
        #expect(gate.waits == 0)
        #expect(await releaseUpdate(1, of: itemGate))

        // Progress ticks, a pause and a resume of the same item.
        for time in stride(from: 51.0, through: 60, by: 1) {
            playback.currentTime = time
            await Task.yield()
        }
        playback.isPlaying = false
        await settle()
        playback.isPlaying = true
        await settle()
        #expect(itemGate.waits == 1)

        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 0, playing: true)
        #expect(await eventually { itemGate.waits == 2 })
        #expect(await releaseUpdate(2, of: itemGate))
    }

    @Test func aSignOutWhileAnItemWaitsUpdatesOnce() async {
        let (playback, player) = makePlayer()
        let refresher = makeRefresher()
        refresher.follow(player)
        playback.load(FakePlaybackControl.bookSession(), at: 0, playing: true)
        #expect(await eventually { itemGate.waits == 1 })

        await refresher.sessionWillEnd(.signOut)
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))
        itemGate.release()
        await settle()

        #expect(updates == 1)
    }

    @Test func aSignOutWhileASessionUpdateWaitsJoinsIt() async {
        let refresher = makeRefresher()
        await refresher.sessionDidReconnect(context())
        #expect(await eventually { gate.waits == 1 })

        await refresher.sessionWillEnd(.signOut)
        #expect(await releaseUpdate(1))
        await settle()

        #expect(gate.waits == 1)
        #expect(updates == 1)
    }

    @Test func aSwitchUpdatesOnce() async {
        let refresher = makeRefresher()

        await refresher.sessionWillEnd(.switch)
        await refresher.sessionDidStart(context())
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))
        await settle()

        #expect(gate.waits == 1)
        #expect(updates == 1)
    }
}
