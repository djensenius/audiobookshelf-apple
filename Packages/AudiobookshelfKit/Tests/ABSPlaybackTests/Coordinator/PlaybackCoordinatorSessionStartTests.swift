import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Session starts take turns: the server keeps one open session per device, so a `/play` that
/// reaches it late would close the session of a newer play.
@MainActor
struct PlaybackCoordinatorSessionStartTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
    }

    @Test func laterPlayKeepsItsSessionWhenAnEarlierRequestArrivesLate() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let playA = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }

        let playB = Task { await coordinator.play(itemID: "B") }
        // Ungated, B's request reaches the server now and A's follows it; gated, B is queued.
        await yieldUntil { service.starts.count == 2 || coordinator.queuedSessionStarts == 1 }
        gate.open()
        await playA.value
        await playB.value
        await coordinator.waitForPendingCloses()

        #expect(service.openSessions == ["B-2"])
        #expect(service.takenOver.isEmpty)
        #expect(service.closes == ["A-1"])
        // B's request went out only after A's stale session was closed.
        #expect(service.log == ["start A", "close A-1", "close A-1 done", "start B"])
        #expect(coordinator.session?.id == "B-2")
        #expect(coordinator.isPlaying)
        #expect(engine.loads.count == 1)
    }

    @Test func playSupersededByStopWhileQueuedSendsNoRequest() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let playA = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }
        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { coordinator.queuedSessionStarts == 1 }

        coordinator.stop()
        gate.open()
        await playA.value
        await playB.value
        await coordinator.waitForPendingCloses()

        #expect(service.starts == ["A"])
        #expect(service.closes == ["A-1"])
        #expect(service.openSessions.isEmpty)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.mediaKey == nil)
        #expect(engine.loads.isEmpty)
        #expect(coordinator.queuedSessionStarts == 0)
    }

    @Test func queuedPlaySupersededByAThirdSendsNoRequest() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let playA = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }
        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { coordinator.queuedSessionStarts == 1 }
        let playC = Task { await coordinator.play(itemID: "C") }
        await yieldUntil { coordinator.queuedSessionStarts == 2 }

        gate.open()
        await playA.value
        await playB.value
        await playC.value
        await coordinator.waitForPendingCloses()

        #expect(service.starts == ["A", "C"])
        #expect(service.log == ["start A", "close A-1", "close A-1 done", "start C"])
        #expect(service.openSessions == ["C-2"])
        #expect(coordinator.mediaKey == h.key("C"))
        #expect(coordinator.session?.id == "C-2")
        #expect(coordinator.isPlaying)
        #expect(coordinator.queuedSessionStarts == 0)
    }

    @Test func onlyTheNewestQueuedPlaySendsARequest() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let playA = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }
        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { coordinator.queuedSessionStarts == 1 }
        let playC = Task { await coordinator.play(itemID: "C") }
        await yieldUntil { coordinator.queuedSessionStarts == 2 }
        // The same media as the first waiter, but a newer play: the older one stays superseded.
        let playBAgain = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { coordinator.queuedSessionStarts == 3 }

        gate.open()
        await playA.value
        await playB.value
        await playC.value
        await playBAgain.value
        await coordinator.waitForPendingCloses()

        #expect(service.starts == ["A", "B"])
        #expect(service.openSessions == ["B-2"])
        #expect(coordinator.session?.id == "B-2")
        #expect(coordinator.queuedSessionStarts == 0)
    }

    @Test func failedStartPassesItsTurnOn() async {
        let gate = Gate()
        service.state.withLock {
            $0.startGates["A"] = gate
            $0.startError = .forbidden(message: nil)
        }
        let playA = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }
        // A's request is already on its way to fail; B's must not.
        service.state.withLock { $0.startError = nil }
        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { coordinator.queuedSessionStarts == 1 }

        gate.open()
        await playA.value
        await playB.value

        // A's failure is stale news: B is current and plays.
        #expect(service.starts == ["A", "B"])
        #expect(coordinator.error == nil)
        #expect(coordinator.session?.id == "B-2")
        #expect(coordinator.isPlaying)
        #expect(coordinator.queuedSessionStarts == 0)
    }

    @Test func playAfterAFailedStartIsNotBlocked() async {
        service.state.withLock { $0.startError = .forbidden(message: nil) }
        await coordinator.play(itemID: "A")
        #expect(coordinator.error == .sessionStartFailed(.forbidden(message: nil)))
        service.state.withLock { $0.startError = nil }

        await coordinator.play(itemID: "B")

        #expect(service.starts == ["A", "B"])
        #expect(coordinator.error == nil)
        #expect(coordinator.isPlaying)
        #expect(coordinator.queuedSessionStarts == 0)
    }
}
