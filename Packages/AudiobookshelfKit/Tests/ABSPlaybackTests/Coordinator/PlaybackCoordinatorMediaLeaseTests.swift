import ABSData
import Foundation
import Testing

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
