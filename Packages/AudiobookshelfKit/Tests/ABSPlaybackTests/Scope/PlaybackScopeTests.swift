import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// Records the Now Playing calls a scope makes, in order, into a shared log.
@MainActor
final class RecordingNowPlaying: NowPlayingHandle {
    var log: [String] = []
    weak var coordinator: PlaybackCoordinator?

    func invalidate() { log.append("invalidate") }
    func claimSystemPrimary() async { log.append("primary") }
}

/// A scope over a ``SyncHarness``: the coordinator's fakes and an attached syncer.
@MainActor
private struct ScopeHarness {
    let s: SyncHarness
    let nowPlaying = RecordingNowPlaying()
    let scope: PlaybackScope

    init(progressStore: LocalProgressStore? = nil, connectionID: UUID = UUID()) throws {
        s = try SyncHarness(progressStore: progressStore, connectionID: connectionID)
        scope = PlaybackScope(coordinator: s.coordinator, syncer: s.syncer, services: nil, nowPlaying: nowPlaying)
    }

    var coordinator: PlaybackCoordinator { s.coordinator }
    var store: LocalProgressStore { s.store }

    /// Plays `item` from 50, lets its explicit start commit, then moves the engine to 100 and holds
    /// the next local position write until `persistence` opens; `saving` opens when it's held.
    func loadAt100(holding persistence: Gate, saving: Gate) async {
        await scope.play(itemID: "a", episodeID: nil, startTime: 50)
        await s.syncer.waitForPendingWrites()
        s.h.engine.currentTime = 100
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
    }
}

private struct FixedDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

private struct StaticTokens: TokenProvider {
    func tokens() async -> ABSAPI.AuthTokens? { ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r") }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

/// A scope built by ``PlaybackScope/make(_:makeNowPlaying:)``, with fakes for the engine, settings
/// and policy, over `writer`.
@MainActor
private func madeScope(
    connectionID: UUID = UUID(), client: APIClient? = nil, features: ServerFeatures? = nil,
    writer: LocalProgressStore? = nil, nowPlaying: RecordingNowPlaying = RecordingNowPlaying(),
    lastPlayed: @escaping @MainActor (UUID) -> any LastPlayedStoring = { _ in InMemoryLastPlayedStore() }
) throws -> PlaybackScope {
    let writer = try writer ?? LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    let configuration = PlaybackScope.Configuration(
        connectionID: connectionID, client: client, features: features, deviceIdentifiers: FixedDevice(),
        writer: writer, settings: StubPlaybackSettings(), policy: StubStreamingPolicy(),
        engine: CoordinatorTestEngine(), tickInterval: 0.5, lastPlayed: lastPlayed)
    return PlaybackScope.make(configuration) { coordinator in
        nowPlaying.coordinator = coordinator
        return nowPlaying
    }
}

private func record(_ connectionID: UUID, item: String, position: Double = 42) -> LastPlayedRecord {
    LastPlayedRecord(
        serverConnectionID: connectionID, libraryItemID: item, episodeID: nil, position: position, duration: 3600,
        timestamp: Date(timeIntervalSince1970: 1_800_000_000), title: "Title \(item)")
}

@MainActor
struct PlaybackScopeTests {
    // MARK: Make

    @Test func makeAttachesTheSyncerBeforeAnyPlay() throws {
        let nowPlaying = RecordingNowPlaying()
        let id = UUID()
        let scope = try madeScope(connectionID: id, nowPlaying: nowPlaying)

        #expect(scope.coordinator.finalCloseReport != nil)
        #expect(scope.coordinator.quiesceProgressTransport != nil)
        #expect(nowPlaying.coordinator === scope.coordinator)
        #expect(scope.services?.serverConnectionID == id)
        #expect(scope.services?.canStartSessions == false)
    }

    /// No features means no session, not a guessed server version.
    @Test func offlineScopeCannotStartASession() async throws {
        let nowPlaying = RecordingNowPlaying()
        let scope = try madeScope(client: nil, features: nil, nowPlaying: nowPlaying)

        await scope.play(itemID: "a", episodeID: nil, startTime: nil)

        #expect(scope.coordinator.error == .sessionStartFailed(.notAuthenticated))
        #expect(!nowPlaying.log.contains("primary"))
    }

    // MARK: LastPlayed

    @Test func eachConnectionKeepsItsOwnLastPlayedRecord() throws {
        let suiteName = "ABSPlaybackTests.Scope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let a = UUID()
        let b = UUID()
        let perConnection: @MainActor (UUID) -> any LastPlayedStoring = {
            PlaybackScope.lastPlayedStore(for: $0, defaults: defaults)
        }
        perConnection(a).save(record(a, item: "a"))
        perConnection(b).save(record(b, item: "b"))

        let scopeA = try madeScope(connectionID: a, lastPlayed: perConnection)
        let scopeB = try madeScope(connectionID: b, lastPlayed: perConnection)

        #expect(scopeA.start())
        #expect(scopeA.coordinator.restoredRecord == record(a, item: "a"))
        #expect(scopeB.start())
        #expect(scopeB.coordinator.restoredRecord == record(b, item: "b"))
        #expect(defaults.data(forKey: UserDefaultsLastPlayedStore.defaultKey) == nil)

        // Signing out of B clears only B's record.
        scopeB.retire(reason: .signOut)
        #expect(perConnection(b).load() == nil)
        #expect(perConnection(a).load() == record(a, item: "a"))
    }

    /// The control for the test above: with one shared key, B's record replaces A's.
    @Test func aSharedLastPlayedKeyLosesTheOtherAccountsRecord() throws {
        let suiteName = "ABSPlaybackTests.Scope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let a = UUID()
        let b = UUID()
        let shared: @MainActor (UUID) -> any LastPlayedStoring = { _ in UserDefaultsLastPlayedStore(defaults: defaults)
        }
        shared(a).save(record(a, item: "a"))
        shared(b).save(record(b, item: "b"))

        let scopeA = try madeScope(connectionID: a, lastPlayed: shared)

        #expect(!scopeA.start())
        #expect(scopeA.coordinator.phase == .idle)
    }

    @Test func startRestoresOnlyAMatchingRecord() throws {
        let matching = try ScopeHarness()
        matching.s.h.lastPlayed.record = record(matching.s.h.connectionID, item: "a")
        #expect(matching.scope.start())
        #expect(matching.coordinator.phase == .unloaded)

        let other = try ScopeHarness()
        other.s.h.lastPlayed.record = record(UUID(), item: "a")
        #expect(!other.scope.start())
        #expect(other.coordinator.phase == .idle)
    }

    // MARK: Resume

    /// A user resume of a restored item asks for the system's primary session once it plays.
    @Test func aUserResumeAsksToBecomePrimaryWhenPlaybackStarts() async throws {
        let h = try ScopeHarness()
        h.s.h.lastPlayed.record = record(h.s.h.connectionID, item: "a")
        #expect(h.scope.start())

        await h.scope.resume(rewindingBy: nil)

        #expect(h.coordinator.isPlaybackRequested)
        #expect(h.nowPlaying.log == ["primary"])
        // So does resuming after a pause.
        h.coordinator.pause()
        await h.scope.resume(rewindingBy: nil)
        #expect(h.nowPlaying.log == ["primary", "primary"])
    }

    @Test func aRefusedResumeDoesNotAskToBecomePrimary() async throws {
        let h = try ScopeHarness()
        h.s.h.lastPlayed.record = record(h.s.h.connectionID, item: "a")
        #expect(h.scope.start())
        h.s.h.policy.decision = .denied(.cellular)

        await h.scope.resume(rewindingBy: nil)

        #expect(h.coordinator.error != nil)
        #expect(!h.coordinator.isPlaybackRequested)
        #expect(h.nowPlaying.log.isEmpty)
    }

    @Test func aRetiredScopeDoesNotAskToBecomePrimary() async throws {
        let h = try ScopeHarness()
        h.s.h.lastPlayed.record = record(h.s.h.connectionID, item: "a")
        #expect(h.scope.start())

        h.scope.retire(reason: .accountSwitch)
        await h.scope.resume(rewindingBy: nil)

        #expect(!h.nowPlaying.log.contains("primary"))
    }

    /// Resumes the restored item with its initial seek left pending: playback is requested, but
    /// the audio session hasn't activated, so there is no Now Playing activation to claim yet.
    private func resumeWithSeekPending() async throws -> ScopeHarness {
        let h = try ScopeHarness()
        h.s.h.lastPlayed.record = record(h.s.h.connectionID, item: "a")
        try #require(h.scope.start())
        h.s.h.engine.interruptedLoads = 1
        await h.scope.resume(rewindingBy: nil)
        try #require(h.coordinator.isPlaybackRequested)
        try #require(!h.coordinator.isPlaying)
        try #require(h.s.h.engine.pendingSeekTarget != nil)
        #expect(h.nowPlaying.log.isEmpty)
        return h
    }

    /// The claim waits for activation, then is made exactly once.
    @Test func aResumeClaimsPrimaryOnceTheSeekLandsAndPlaybackActivates() async throws {
        let h = try await resumeWithSeekPending()

        h.s.h.engine.landPendingSeek()
        #expect(await eventually { h.nowPlaying.log == ["primary"] })
        await h.scope.waitForPrimaryClaim()
        h.coordinator.pause()
        await h.scope.waitForPrimaryClaim()
        #expect(h.nowPlaying.log == ["primary"])
    }

    @Test func aPauseBeforeActivationDropsTheClaim() async throws {
        let h = try await resumeWithSeekPending()

        h.coordinator.pause()
        await h.scope.waitForPrimaryClaim()
        h.s.h.engine.landPendingSeek()

        #expect(h.nowPlaying.log.isEmpty)
    }

    @Test func retiringBeforeActivationDropsTheClaim() async throws {
        let h = try await resumeWithSeekPending()

        h.scope.retire(reason: .accountSwitch)
        await h.scope.waitForPrimaryClaim()
        h.s.h.engine.landPendingSeek()

        #expect(!h.nowPlaying.log.contains("primary"))
    }

    /// A pause during a loaded item's play seek leaves nothing playing to claim.
    @Test func aPauseDuringThePlaySeekClaimsNothing() async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: 50)
        h.coordinator.pause()
        h.nowPlaying.log = []
        let gate = Gate()
        h.s.h.engine.seekGates = [gate]
        let seeks = h.s.h.engine.seeks.count

        let play = Task { await h.scope.play(itemID: "a", episodeID: nil, startTime: 30) }
        try #require(await eventually { h.s.h.engine.seeks.count > seeks })
        h.coordinator.pause()
        gate.open()
        await play.value
        await h.scope.waitForPrimaryClaim()

        #expect(h.coordinator.phase == .loaded)
        #expect(h.coordinator.error == nil)
        #expect(!h.coordinator.isPlaybackRequested)
        #expect(h.nowPlaying.log.isEmpty)
    }

    // MARK: Retire

    @Test func retireStopsSynchronously() async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        #expect(h.coordinator.phase == .loaded)
        #expect(h.nowPlaying.log == ["primary"])

        h.scope.retire(reason: .accountSwitch)

        #expect(h.coordinator.isRetired)
        #expect(h.coordinator.phase == .idle)
        _ = await h.scope.finishRetirement()
    }

    @Test(arguments: [PlaybackStopReason.accountSwitch, .expired, .signOut, .accountRemoved])
    func aRetiredCoordinatorCannotReactivate(reason: PlaybackStopReason) async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        h.scope.retire(reason: reason)
        _ = await h.scope.finishRetirement()
        h.s.h.lastPlayed.record = record(h.s.h.connectionID, item: "a")

        await h.scope.play(itemID: "b", episodeID: nil, startTime: nil)
        #expect(!h.scope.start())
        await h.coordinator.resume(rewindingBy: nil)

        #expect(h.s.h.service.starts == ["a"])
        #expect(h.coordinator.phase == .idle)
    }

    /// The control for the test above: an ordinary stop keeps the coordinator usable.
    @Test func anOrdinaryStopCanPlayAgain() async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        h.coordinator.stop(reason: .user)

        await h.scope.play(itemID: "b", episodeID: nil, startTime: nil)

        #expect(h.s.h.service.starts == ["a", "b"])
        #expect(h.coordinator.phase == .loaded)
        h.scope.retire(reason: .expired)
        _ = await h.scope.finishRetirement()
    }

    @Test func finishReleasesAfterTheWaitResolves() async throws {
        let h = try ScopeHarness()
        h.scope.onRelease { h.nowPlaying.log.append("hook") }
        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)

        h.scope.retire(reason: .accountSwitch)
        #expect(!h.nowPlaying.log.contains("invalidate"))
        let outcome = try await h.scope.finishRetirement().get()

        #expect(outcome.sessions.map(\.transport) == [.acknowledged])
        #expect(outcome.sessions.map(\.audioPositionCommitted) == [true])
        #expect(h.nowPlaying.log == ["primary", "invalidate", "hook"])
        #expect(h.coordinator.finalCloseReport == nil)
        #expect(h.coordinator.quiesceProgressTransport == nil)
        // A hook added after the release runs at once.
        h.scope.onRelease { h.nowPlaying.log.append("late") }
        #expect(h.nowPlaying.log.last == "late")
    }

    /// Nothing keeps a released scope or its coordinator alive.
    @Test func aReleasedScopeIsFreed() async throws {
        weak var weakScope: PlaybackScope?
        weak var weakCoordinator: PlaybackCoordinator?
        do {
            let scope = try madeScope(lastPlayed: { id in
                let store = InMemoryLastPlayedStore()
                store.save(record(id, item: "a"))
                return store
            })
            weakScope = scope
            weakCoordinator = scope.coordinator
            #expect(scope.start())
            scope.retire(reason: .accountSwitch)
            _ = await scope.finishRetirement()
            #expect(scope.isReleased)
        }
        await yieldUntil { weakScope == nil && weakCoordinator == nil }
        #expect(weakScope == nil)
        #expect(weakCoordinator == nil)
    }

    @Test func timeoutDoesNotEraseTheCapturedPosition() async throws {
        let h = try ScopeHarness()
        let persistence = Gate()
        let saving = Gate()
        defer { persistence.open() }
        await h.loadAt100(holding: persistence, saving: saving)

        h.scope.retire(reason: .accountSwitch)
        await saving.wait()
        h.s.h.sleep.elapsesImmediately = true
        let result = await h.scope.finishRetirement(timeout: .seconds(2))

        #expect(throws: PlaybackCloseError.timedOut) { try result.get() }
        #expect(h.nowPlaying.log.last == "invalidate")
        #expect(try await h.store.progress(for: h.s.h.key("a"))?.currentTime == 50)

        persistence.open()
        await h.s.syncer.waitForPendingWrites()
        #expect(try await h.store.progress(for: h.s.h.key("a"))?.currentTime == 100)
    }

    @Test func cancellationDoesNotEraseTheCapturedPosition() async throws {
        let h = try ScopeHarness()
        let persistence = Gate()
        let saving = Gate()
        defer { persistence.open() }
        await h.loadAt100(holding: persistence, saving: saving)

        h.scope.retire(reason: .expired)
        await saving.wait()
        let finishing = Task { await h.scope.finishRetirement() }
        finishing.cancel()
        let result = await finishing.value

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(h.nowPlaying.log.last == "invalidate")

        persistence.open()
        await h.s.syncer.waitForPendingWrites()
        #expect(try await h.store.progress(for: h.s.h.key("a"))?.currentTime == 100)
    }

    @Test func aMissingReporterIsSurfaced() async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        h.s.syncer.detach()

        h.scope.retire(reason: .accountSwitch)
        let result = await h.scope.finishRetirement()

        #expect(throws: PlaybackCloseError.missingReporter(sessionID: "a-1")) { try result.get() }
        #expect(h.nowPlaying.log.last == "invalidate")
    }

    @Test func aFailedCommitIsSurfaced() async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: 50)
        await h.s.syncer.waitForPendingWrites()
        h.s.h.engine.currentTime = 51
        await h.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))

        h.scope.retire(reason: .expired)
        let result = await h.scope.finishRetirement()

        switch result {
        case .failure(PlaybackCloseError.positionCommitFailed(let id, _)): #expect(id == "a-1")
        default: Issue.record("Expected a failed commit, got \(result)")
        }
        #expect(h.nowPlaying.log.last == "invalidate")
    }

    @Test(arguments: [PlaybackStopReason.accountSwitch, .expired, .signOut, .accountRemoved])
    func onlyAnOfflineEndDropsTheClient(reason: PlaybackStopReason) async throws {
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://abs.example"))),
            tokenProvider: StaticTokens())
        let scope = try madeScope(client: client, features: ServerFeatures(version: ServerVersion(2, 37, 2)))
        #expect(scope.services?.canStartSessions == true)

        scope.retire(reason: reason)

        #expect(scope.services?.canStartSessions == (reason == .accountSwitch))
        _ = await scope.finishRetirement()
    }

    @Test func expiredRetirementSendsNoClose() async throws {
        let h = try ScopeHarness()
        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)

        h.scope.retire(reason: .expired)
        let outcome = try await h.scope.finishRetirement().get()

        #expect(outcome.sessions.map(\.transport) == [.deliberatelySkipped])
        #expect(outcome.sessions.map(\.audioPositionCommitted) == [true])
        await h.coordinator.waitForPendingCloses()
        #expect(h.s.h.service.closes.isEmpty)
    }

    // MARK: Shared writer

    /// A retired scope's delayed final write can't replace the newer scope's committed seek, as
    /// long as both share one writer; with two writers over the same store, it does.
    @Test(arguments: [true, false])
    func aDelayedRetiredScopeWriteCannotSupersedeANewerCommittedSeek(sharedWriter: Bool) async throws {
        let stack = try DataStack(location: .inMemory)
        let writer = LocalProgressStore(modelContainer: stack.container)
        let old = try ScopeHarness(progressStore: writer)
        let persistence = Gate()
        let saving = Gate()
        defer { persistence.open() }
        await old.loadAt100(holding: persistence, saving: saving)
        old.scope.retire(reason: .expired)
        await saving.wait()
        old.s.h.sleep.elapsesImmediately = true
        await #expect(throws: PlaybackCloseError.timedOut) { try await old.scope.finishRetirement().get() }

        let newer = try ScopeHarness(
            progressStore: sharedWriter ? writer : LocalProgressStore(modelContainer: stack.container),
            connectionID: old.s.h.connectionID)
        newer.s.h.clock.advance(by: -1)  // The order must not come from the wall clock.
        await newer.scope.play(itemID: "a", episodeID: nil, startTime: 50)
        await newer.coordinator.seek(to: 200)
        newer.s.syncer.quiesceTransport()
        await newer.s.settle()
        #expect(try await writer.progress(for: newer.s.h.key("a"))?.currentTime == 200)

        persistence.open()
        await old.s.syncer.waitForPendingWrites()

        #expect(try await writer.progress(for: newer.s.h.key("a"))?.currentTime == (sharedWriter ? 200 : 100))
        newer.scope.retire(reason: .expired)
        _ = await newer.scope.finishRetirement()
    }

    // MARK: Rejection

    @Test(arguments: [APIError.sessionExpired, .unauthorized(message: nil), .network(.notConnectedToInternet)])
    func onlyAnExpiredSessionRaisesOnSessionRejectedOnce(error: APIError) async throws {
        let h = try ScopeHarness()
        var rejections = 0
        h.scope.onSessionRejected = { rejections += 1 }
        h.s.h.service.state.withLock { $0.startError = error }

        await h.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        await h.scope.play(itemID: "b", episodeID: nil, startTime: nil)

        #expect(h.coordinator.error == .sessionStartFailed(error))
        #expect(rejections == (error == .sessionExpired ? 1 : 0))
        #expect(!h.nowPlaying.log.contains("primary"))
    }
}
