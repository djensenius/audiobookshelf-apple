import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// A deferred edit is drained against the server's current progress (#195, ADR 0007 decision 8):
/// the drain fetches first and merges by ADR 0003, so in a real conflict it PATCHes only an edit
/// newer than what another device wrote meanwhile. Both devices share one session model; the
/// phone is the syncer under test and the tablet writes to the model directly.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressStaleDrainTests {
    private struct Fixture {
        let s: SyncHarness
        let model: ReconciliationSessionModel
        let phone: SessionModelClient
        let tablet: SessionModelClient
        let serverClock: TestClock

        /// Real time passes on both clocks.
        func advance(by seconds: TimeInterval) {
            s.h.clock.advance(by: seconds)
            if serverClock !== s.h.clock { serverClock.advance(by: seconds) }
        }
    }

    /// `serverAhead` puts the server's clock that many seconds ahead of the phone's.
    private static func fixture(serverAhead: TimeInterval = 0) throws -> Fixture {
        let s = try SyncHarness()
        let serverClock: TestClock
        if serverAhead == 0 {
            serverClock = s.h.clock
        } else {
            serverClock = TestClock()
            serverClock.advance(by: serverAhead)
        }
        let model = ReconciliationSessionModel(clock: serverClock)
        let phone = SessionModelClient(model: model)
        s.h.service.state.withLock { $0.sessionClient = phone }
        s.service.state.withLock { $0.sessionClient = phone }
        return Fixture(
            s: s, model: model, phone: phone, tablet: SessionModelClient(model: model, deviceID: "tablet"),
            serverClock: serverClock)
    }

    private static func edit(_ f: Fixture, _ time: Double) async throws {
        try await f.s.store.recordEdit(ActiveRefreshFixture.edit(time), for: f.s.h.key("a"), now: f.s.h.clock.now)
    }

    private static func tabletWrites(_ f: Fixture, _ time: Double) async throws {
        try await f.model.update(f.tablet, itemID: "a", episodeID: nil, SyncHarness.audio(time))
    }

    private static func serverTime(_ f: Fixture) async throws -> Double? {
        try await f.model.fetchProgress(f.phone, itemID: "a", episodeID: nil)?.currentTime
    }

    /// The phone's offline edit is older than the tablet's later write: the drain looks it up and
    /// keeps the tablet's position, on the server and locally (#195 acceptance item 3).
    @Test func aStaleDrainKeepsAnotherDevicesNewerPosition() async throws {
        let f = try Self.fixture()
        try await Self.edit(f, 200)
        f.advance(by: 10)
        try await Self.tabletWrites(f, 900)

        await f.s.syncer.drainPendingProgress()

        #expect(f.s.service.log == ["get a"])
        #expect(f.s.service.patches.isEmpty)
        #expect(try await Self.serverTime(f) == 900)
        let local = try #require(try await f.s.store.progress(for: f.s.h.key("a")))
        #expect(local.currentTime == 900 && !local.needsServerSync)
        #expect(f.s.syncer.drainWake == nil)
    }

    /// Control for the above: an edit newer than the tablet's write is PATCHed over it.
    @Test func aNewerLocalEditIsPatched() async throws {
        let f = try Self.fixture()
        try await Self.tabletWrites(f, 900)
        f.advance(by: 10)
        try await Self.edit(f, 200)

        await f.s.syncer.drainPendingProgress()

        #expect(f.s.service.log.prefix(2) == ["get a", "patch a"])
        #expect(f.s.service.patches.map(\.update) == [SyncHarness.audio(200)])
        #expect(try await Self.serverTime(f) == 200)
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.needsServerSync == false)
    }

    /// Offline at drain time: without the server's progress there's no PATCH, the edit stays
    /// queued and a wake retries; the retry merges as usual.
    @Test func aFailedLookupDefersThePatchToTheWake() async throws {
        let f = try Self.fixture()
        f.s.service.state.withLock { $0.fetchErrors = [.timedOut] }
        try await Self.tabletWrites(f, 900)
        f.advance(by: 10)
        try await Self.edit(f, 200)

        await f.s.syncer.drainPendingProgress()

        #expect(f.s.service.log == ["get a"])
        #expect(try await Self.serverTime(f) == 900)
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.needsServerSync == true)
        let wake = try #require(f.s.syncer.drainWake)

        f.s.sleeper.fire()
        await wake.value
        await f.s.settle()

        #expect(f.s.service.log.prefix(3) == ["get a", "get a", "patch a"])
        #expect(try await Self.serverTime(f) == 200)
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.needsServerSync == false)
        #expect(f.s.syncer.drainWake == nil)
    }

    /// The server has no progress for the item yet: the PATCH creates it.
    @Test func aDrainCreatesProgressTheServerLacks() async throws {
        let f = try Self.fixture()
        try await Self.edit(f, 200)

        await f.s.syncer.drainPendingProgress()

        #expect(f.s.service.log.prefix(2) == ["get a", "patch a"])
        let server = try #require(try await f.model.fetchProgress(f.tablet, itemID: "a", episodeID: nil))
        #expect(server.currentTime == 200)
        #expect(server.lastUpdate == Int(f.s.h.clock.now.timeIntervalSince1970 * 1000))
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.needsServerSync == false)
    }

    /// Characterization, not a guarantee: the merge compares the phone's edit time with the
    /// server's `lastUpdate`, so a server clock ahead of the phone's by more than the gap makes a
    /// later phone edit look older and it loses (#146 accepts this; ADR 0007 decision 8). With
    /// the clocks agreeing, the same sequence PATCHes.
    @Test(arguments: [0, 60] as [TimeInterval])
    func clockSkewCanLoseANewerEdit(serverAhead: TimeInterval) async throws {
        let f = try Self.fixture(serverAhead: serverAhead)
        try await Self.tabletWrites(f, 900)
        // The phone edits 30 s after the tablet's write, in real time.
        f.advance(by: 30)
        try await Self.edit(f, 200)

        await f.s.syncer.drainPendingProgress()

        let lost = serverAhead > 30
        #expect(f.s.service.patches.isEmpty == lost)
        #expect(try await Self.serverTime(f) == (lost ? 900 : 200))
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.currentTime == (lost ? 900 : 200))
    }
}
