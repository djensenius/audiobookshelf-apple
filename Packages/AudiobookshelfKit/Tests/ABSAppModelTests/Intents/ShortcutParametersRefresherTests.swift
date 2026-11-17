import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// What ``ShortcutParametersRefresher/followEndedSessions(of:)`` reads, as `SessionLifecycle`
/// counts it.
@MainActor @Observable
private final class FakeEndings {
    var count = 0
}

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
    private let endings = FakeEndings()
    private var updates = 0

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeRefresher() -> ShortcutParametersRefresher {
        let (gate, itemGate, endings) = (gate, itemGate, endings)
        let refresher = ShortcutParametersRefresher(
            sessionWait: { await gate.wait() }, itemWait: { await itemGate.wait() }
        ) { [weak self] in self?.updates += 1 }
        refresher.followEndedSessions { endings.count }
        return refresher
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

    @Test func aSessionsStartAndTheEndOfItsTeardownEachUpdate() async {
        let refresher = makeRefresher()

        await refresher.sessionDidStart(context())
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))

        endings.count += 1
        #expect(await eventually { gate.waits == 2 })
        #expect(await releaseUpdate(2))
    }

    @Test func anEndingSessionDoesntUpdateBeforeItsTeardownIsOver() async {
        let refresher = makeRefresher()

        await refresher.sessionWillEnd(.signOut)
        await settle()

        #expect(gate.waits == 0)
        #expect(updates == 0)
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

    @Test func anItemStartingWhileAnotherWaitsStartsTheWaitOver() async {
        let (playback, player) = makePlayer()
        let refresher = makeRefresher()
        refresher.follow(player)
        playback.load(FakePlaybackControl.bookSession(), at: 0, playing: true)
        #expect(await eventually { itemGate.waits == 1 })

        // The next item starts before the first one's wait is over.
        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 0, playing: true)
        #expect(await eventually { itemGate.waits == 2 })
        // Both waits end together: the first one's was cancelled, so only the second updates.
        #expect(await releaseUpdate(1, of: itemGate))
        await settle()

        #expect(itemGate.waits == 2)
        #expect(updates == 1)
    }

    @Test func aSignOutWhileAnItemWaitsUpdatesOnce() async {
        let (playback, player) = makePlayer()
        let refresher = makeRefresher()
        refresher.follow(player)
        playback.load(FakePlaybackControl.bookSession(), at: 0, playing: true)
        #expect(await eventually { itemGate.waits == 1 })

        await refresher.sessionWillEnd(.signOut)
        endings.count += 1
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
        endings.count += 1
        await settle()
        #expect(await releaseUpdate(1))
        await settle()

        #expect(gate.waits == 1)
        #expect(updates == 1)
    }

    @Test func aSwitchUpdatesOnce() async {
        let refresher = makeRefresher()

        await refresher.sessionWillEnd(.switch)
        endings.count += 1
        await refresher.sessionDidStart(context())
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))
        await settle()

        #expect(gate.waits == 1)
        #expect(updates == 1)
    }

    // MARK: Lifecycle

    /// Registered like the app's, last of the `.connect` participants, so the lifecycle ends it
    /// first: the sign-out's update still waits until the library is cleared, after a slow
    /// participant ended in between.
    @Test func aSignOutUpdatesOnlyOnceTheLibraryIsCleared() async throws {
        let log = CallLog()
        let source = FakeAccountSource(log: log)
        source.restoredPhase = .active(identityA, isOffline: false)
        let images = FakeParticipant("images", log: log)
        let lifecycle = SessionLifecycle(source: source, clock: ManualClock())
        lifecycle.register(seeder: FakeLibrary(log: log))
        lifecycle.register(images, stage: .connect)
        let refresher = makeRefresher()
        refresher.followEndedSessions { [weak lifecycle] in lifecycle?.endedSessions ?? 0 }
        lifecycle.register(refresher, stage: .connect)
        await lifecycle.start()
        try #require(await eventually { log.entries.contains("library.seed(a)") })
        try #require(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))

        let endGate = Gate()
        images.endGate = endGate
        defer { endGate.open() }
        let signOut = Task { await lifecycle.signOut() }
        #expect(await eventually { log.entries.contains("images.end(signOut)") })
        await settle()
        #expect(gate.waits == 1)
        #expect(!log.entries.contains("library.clear(signOut)"))

        endGate.open()
        _ = await signOut.value
        #expect(log.entries.contains("library.clear(signOut)"))
        #expect(lifecycle.endedSessions == 1)
        #expect(await eventually { gate.waits == 2 })
        #expect(await releaseUpdate(2))
    }
}
