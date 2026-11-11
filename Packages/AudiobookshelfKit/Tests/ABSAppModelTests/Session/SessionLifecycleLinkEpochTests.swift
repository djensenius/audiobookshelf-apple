import ABSAPI
import Foundation
import Testing

@testable import ABSAppModel

/// A waiting link is delivered only to a shell of the epoch it arrived in. These tests never read
/// `gate` between steps (a view can miss a gate that came and went), only the epoch.
@MainActor
private struct Harness {
    let log = CallLog()
    let source: FakeAccountSource
    let library: FakeLibrary
    let lifecycle: SessionLifecycle
    let link = DeepLink(.item(id: "li_1", episodeID: nil))

    init(restoredPhase: AccountSessionPhase = .active(identityA, isOffline: false)) {
        source = FakeAccountSource(log: log)
        source.restoredPhase = restoredPhase
        library = FakeLibrary(log: log)
        lifecycle = SessionLifecycle(source: source, clock: ManualClock())
        lifecycle.register(seeder: library)
    }

    func started() async throws {
        await lifecycle.start()
        try #require(await eventually { log.entries.contains("library.seed(a)") })
        try #require(await eventually { lifecycle.reconciledObservations > 0 })
    }

    /// Queues a link at the current gate and epoch, as `RootView` does.
    func queued() throws -> PendingLink {
        try #require(PendingLink(link, arrivingAt: lifecycle.gate, epoch: lifecycle.linkEpoch))
    }

    func isCurrent(_ pending: PendingLink) -> Bool { pending.link(atEpoch: lifecycle.linkEpoch) == link }
}

@MainActor
@Suite struct SessionLifecycleLinkEpochTests {
    @Test func linkQueuedBeforeASignOutAndSignInIsStaleAtTheNextAccount() async throws {
        let harness = Harness()
        try await harness.started()
        let pending = try harness.queued()
        #expect(harness.isCurrent(pending))

        await harness.lifecycle.signOut()
        harness.source.phase = .active(identityB, isOffline: false)
        try #require(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
        #expect(!harness.isCurrent(pending))
    }

    @Test func linkQueuedBeforeASwitchIsStaleAtTheIncomingAccount() async throws {
        let harness = Harness()
        try await harness.started()
        let pending = try harness.queued()

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        try #require(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(!harness.isCurrent(pending))
    }

    @Test func linkQueuedBeforeAnAccountChangeBySourceIsStale() async throws {
        let harness = Harness()
        try await harness.started()
        let pending = try harness.queued()

        harness.source.phase = .active(identityB, isOffline: false)
        try #require(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(!harness.isCurrent(pending))
    }

    @Test func linkQueuedBeforeRemovingTheAccountIsStale() async throws {
        let harness = Harness()
        try await harness.started()
        let pending = try harness.queued()

        try await harness.lifecycle.removeAccount(identityA.connectionID)

        #expect(!harness.isCurrent(pending))
    }

    @Test func linkQueuedBeforeAnExpiryIsStale() async throws {
        let harness = Harness()
        try await harness.started()
        let pending = try harness.queued()

        harness.source.expire()
        try #require(await eventually { harness.lifecycle.gate == .connect })

        #expect(!harness.isCurrent(pending))
    }

    @Test func linkArrivingDuringASwitchOpensForTheIncomingAccount() async throws {
        let harness = Harness()
        try await harness.started()
        var pending: PendingLink?
        harness.source.onSwitch = {
            pending = PendingLink(harness.link, arrivingAt: harness.lifecycle.gate, epoch: harness.lifecycle.linkEpoch)
        }

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        try #require(await eventually { harness.log.entries.contains("library.seed(b)") })

        let queued = try #require(pending)
        #expect(harness.isCurrent(queued))
    }

    @Test func linkArrivingDuringAFailedSwitchOpensWhenTheOldAccountRestarts() async throws {
        let harness = Harness()
        try await harness.started()
        var pending: PendingLink?
        harness.source.onSwitch = {
            pending = PendingLink(harness.link, arrivingAt: harness.lifecycle.gate, epoch: harness.lifecycle.linkEpoch)
        }
        harness.source.switchError = CancellationError()

        await #expect(throws: CancellationError.self) {
            try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        }
        try #require(await eventually { harness.log.count(of: "library.seed(a)") == 2 })

        let queued = try #require(pending)
        #expect(harness.isCurrent(queued))
    }

    @Test func linkArrivingDuringASwitchThatSignsOutIsStale() async throws {
        let harness = Harness()
        try await harness.started()
        var pending: PendingLink?
        harness.source.onSwitch = {
            pending = PendingLink(harness.link, arrivingAt: harness.lifecycle.gate, epoch: harness.lifecycle.linkEpoch)
        }
        harness.source.switchSignsOut = true

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)

        let queued = try #require(pending)
        #expect(harness.lifecycle.gate == .connect)
        #expect(!harness.isCurrent(queued))
    }

    @Test func linkTaggedWhileLaunchingOpensAtTheRestoredAccount() async throws {
        let harness = Harness()
        let pending = try harness.queued()
        #expect(harness.lifecycle.gate == .launching)

        try await harness.started()

        #expect(harness.isCurrent(pending))
    }

    @Test func linkTaggedWhileLaunchingIsStaleWhenNoAccountRestores() async throws {
        let harness = Harness(restoredPhase: .signedOut)
        let pending = try harness.queued()

        await harness.lifecycle.start()

        #expect(harness.lifecycle.gate == .connect)
        #expect(!harness.isCurrent(pending))
    }

    @Test func linkTaggedWhileLaunchingIsStaleWhenTheStoreIsUnavailable() async throws {
        let harness = Harness()
        harness.source.restoreError = CocoaError(.fileWriteOutOfSpace)
        let pending = try harness.queued()

        await harness.lifecycle.start()

        #expect(!harness.isCurrent(pending))
    }

    @Test func goingOfflineAndOnlineIsNotABoundary() async throws {
        let harness = Harness()
        try await harness.started()
        let pending = try harness.queued()

        harness.source.phase = .active(identityA, isOffline: true)
        try #require(await eventually { harness.lifecycle.gate == .ready(identityA, isOffline: true) })
        harness.source.phase = .active(identityA, isOffline: false)
        try #require(await eventually { harness.lifecycle.gate == .ready(identityA, isOffline: false) })

        #expect(harness.isCurrent(pending))
    }
}
