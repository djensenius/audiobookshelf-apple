import ABSCore
import ABSData
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
    private let gate = WaitGate()
    private var updates = 0

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeRefresher() -> ShortcutParametersRefresher {
        let gate = gate
        return ShortcutParametersRefresher(wait: { await gate.wait() }) { [weak self] in self?.updates += 1 }
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

    /// Releases the waiting request and waits for its update.
    private func releaseUpdate(_ expected: Int) async -> Bool {
        gate.release()
        return await eventually { updates == expected }
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

    @Test func anotherItemStartingUpdatesButProgressDoesnt() async {
        let playback = FakePlaybackControl()
        let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        let refresher = makeRefresher()
        refresher.follow(player)

        // Restored without playing: Continue Listening hasn't changed.
        playback.load(FakePlaybackControl.bookSession(), at: 50)
        await settle()
        #expect(gate.waits == 0)

        playback.load(FakePlaybackControl.bookSession(), at: 50, playing: true)
        #expect(await eventually { gate.waits == 1 })
        #expect(await releaseUpdate(1))

        // Progress ticks, a pause and a resume of the same item.
        for time in stride(from: 51.0, through: 60, by: 1) {
            playback.currentTime = time
            await Task.yield()
        }
        playback.isPlaying = false
        await settle()
        playback.isPlaying = true
        await settle()
        #expect(gate.waits == 1)

        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 0, playing: true)
        #expect(await eventually { gate.waits == 2 })
        #expect(await releaseUpdate(2))
    }
}
