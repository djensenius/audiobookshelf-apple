import ABSData
import Foundation
import Testing

@testable import ABSPlayback

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
