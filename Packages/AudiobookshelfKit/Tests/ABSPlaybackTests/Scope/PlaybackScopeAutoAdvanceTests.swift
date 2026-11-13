import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSPlayback

/// What keeps the scope's auto-advance preparation fresh (#160): network path changes, a
/// reconnect and progress changes prepare the next item again, until the scope retires.
@MainActor
struct PlaybackScopeAutoAdvanceTests {
    let s: SyncHarness
    let paths = StubNetworkPathSource()
    let scope: PlaybackScope

    init() throws {
        let connectionID = UUID()
        s = try SyncHarness(connectionID: connectionID)
        let queue = PlaybackQueue(serverConnectionID: connectionID, store: AdvanceQueueStore())
        queue.addToEnd(QueueItem(libraryItemID: "B", title: "B"))
        scope = PlaybackScope(
            coordinator: s.coordinator, syncer: s.syncer, services: nil, nowPlaying: RecordingNowPlaying(),
            queue: queue, paths: paths)
    }

    private var policyChecks: Int { s.h.policy.checks }

    /// Plays A, with B queued, and waits for B to be prepared: A's start and B's preparation
    /// each check the streaming policy.
    private func playA() async {
        await scope.play(itemID: "A", episodeID: nil, startTime: nil)
        await scope.advancer?.waitForPreparation()
        #expect(policyChecks == 2)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        await scope.advancer?.waitForPreparation()
    }

    @Test func aChangedPathPreparesAgainButTheFirstOrASamePathDoesNot() async {
        paths.send(.wifi)
        await playA()

        paths.send(.wifi)
        await settle()
        #expect(policyChecks == 2)

        paths.send(.cellular)
        await yieldUntil { policyChecks == 3 }
        await settle()
        #expect(policyChecks == 3)
        scope.retire(reason: .signOut)
    }

    @Test func retiringStopsFollowingThePath() async {
        paths.send(.wifi)
        await playA()

        scope.retire(reason: .signOut)

        await yieldUntil { paths.isTerminated }
        paths.send(.cellular)
        await settle()
        #expect(policyChecks == 2)
    }

    @Test func aReconnectPreparesAgain() async {
        await playA()

        scope.reconnect(client: nil, features: nil)
        await settle()

        #expect(policyChecks == 3)
        scope.retire(reason: .signOut)
        scope.reconnect(client: nil, features: nil)
        await settle()
        #expect(policyChecks == 3)
    }

    @Test func progressForTheNextItemPreparesAgain() async {
        await playA()
        let connectionID = s.h.connectionID

        scope.progressDidChange(for: MediaKey(serverConnectionID: connectionID, libraryItemId: "Other"), kind: .updated)
        await settle()
        #expect(policyChecks == 2)

        scope.progressDidChange(for: MediaKey(serverConnectionID: connectionID, libraryItemId: "B"), kind: .updated)
        await settle()
        #expect(policyChecks == 3)

        scope.retire(reason: .signOut)
        scope.progressDidChange(for: MediaKey(serverConnectionID: connectionID, libraryItemId: "B"), kind: .updated)
        await settle()
        #expect(policyChecks == 3)
    }
}
