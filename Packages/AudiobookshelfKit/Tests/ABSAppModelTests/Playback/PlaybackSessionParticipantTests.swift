import ABSAPI
import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSPlayback

private struct FixedDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

private let serverFeatures = ServerFeatures(version: ServerVersion(2, 37, 2))

private func user(of connectionID: UUID) -> String {
    connectionID == identityA.connectionID ? "a" : "b"
}

/// A scope that records into the shared log as `<user>.<call>`. Its retirement waits for
/// ``finishGate`` when one is set, ignoring cancellation, like a close held behind an
/// uncancellable `/sync`.
@MainActor
private final class FakeScope: PlaybackScopeHandle {
    let request: PlaybackScopeRequest
    let control = FakePlaybackControl()
    var onSessionRejected: (@MainActor () -> Void)?
    var finishGate: Gate?
    var finishResult: Result<PlaybackCloseOutcome, any Error> = .success(PlaybackCloseOutcome(sessions: []))
    private(set) var retiredReason: PlaybackStopReason?
    private(set) var reconnects: [(client: APIClient?, features: ServerFeatures?)] = []
    private let log: CallLog
    private let name: String

    init(_ request: PlaybackScopeRequest, log: CallLog) {
        self.request = request
        self.log = log
        name = user(of: request.connectionID)
    }

    var playback: any PlayerPlaybackControlling { control }

    func start() -> Bool {
        log.record("\(name).restore")
        return false
    }

    func play(itemID: String, episodeID: String?, startTime: Double?) async {
        log.record("\(name).play(\(itemID))")
    }

    func reconnect(client: APIClient?, features: ServerFeatures?) {
        reconnects.append((client, features))
        log.record("\(name).reconnect")
    }

    func saveLocally() {
        log.record("\(name).saveLocally")
    }

    func retire(reason: PlaybackStopReason) {
        retiredReason = reason
        control.stop(reason: reason)
        log.record("\(name).retire(\(reason))")
    }

    func finishRetirement(timeout: Duration) async -> Result<PlaybackCloseOutcome, any Error> {
        log.record("\(name).finish")
        await finishGate?.wait()
        log.record("\(name).finished")
        return finishResult
    }
}

/// A lifecycle whose playback is the real participant over fake scopes, between an image-like
/// connect participant and a socket that ends first.
@MainActor
private struct Harness {
    let log = CallLog()
    let source: FakeAccountSource
    let images: FakeParticipant
    let socket: FakeParticipant
    let clock = ManualClock()
    let lifecycle: SessionLifecycle
    let current = CurrentPlayback()
    let writer: LocalProgressStore
    let participant: PlaybackSessionParticipant
    let scopes = ScopeList()
    let features: FeatureTable
    let signOuts = CallLog()

    @MainActor
    final class ScopeList {
        var all: [FakeScope] = []
        var last: FakeScope? { all.last }
        /// Set on every scope made from now on.
        var finishGate: Gate?
    }

    @MainActor
    final class FeatureTable {
        var byUser: [String: ServerFeatures] = ["a": serverFeatures, "b": serverFeatures]
    }

    init(restoredPhase: AccountSessionPhase = .active(identityA, isOffline: false), restoredClient: APIClient? = nil)
        throws
    {
        source = FakeAccountSource(log: log)
        source.restoredPhase = restoredPhase
        source.restoredClient = restoredClient
        images = FakeParticipant("images", log: log)
        socket = FakeParticipant("socket", log: log)
        lifecycle = SessionLifecycle(source: source, clock: clock)
        writer = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        let features = FeatureTable()
        self.features = features
        let scopes = scopes
        let log = log
        let signOuts = signOuts
        participant = PlaybackSessionParticipant(
            current: current, writer: writer, deviceIdentifiers: FixedDevice(),
            features: { features.byUser[$0.userID] },
            requestSignOut: { signOuts.record("signOut(\($0.identity.userID))") },
            makeScope: { request in
                log.record("\(user(of: request.connectionID)).make")
                let scope = FakeScope(request, log: log)
                scope.finishGate = scopes.finishGate
                scopes.all.append(scope)
                return scope
            })
        lifecycle.register(images, stage: .connect)
        lifecycle.register(participant, stage: .progressSource)
        lifecycle.register(socket, stage: .progressSource)
    }

    func started() async throws {
        await lifecycle.start()
        try #require(await eventually { log.entries.contains("a.restore") })
        try #require(await eventually { lifecycle.reconciledObservations > 0 })
        log.clear()
    }
}

@MainActor
@Suite struct PlaybackSessionParticipantTests {
    @Test(arguments: [
        (SessionEndReason.switch, PlaybackStopReason.accountSwitch), (.signOut, .signOut),
        (.removed, .accountRemoved), (.expired, .expired),
    ])
    func eachEndReasonMapsToItsStopReason(end: SessionEndReason, stop: PlaybackStopReason) {
        #expect(PlaybackSessionParticipant.stopReason(for: end) == stop)
    }

    @Test func startBuildsBindsAndRestoresTheScope() async throws {
        let harness = try Harness()
        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("a.restore") })

        let scope = try #require(harness.scopes.last)
        #expect(harness.log.entries.filter { $0.hasPrefix("a.") } == ["a.make", "a.restore"])
        #expect(scope.request.connectionID == identityA.connectionID)
        #expect(scope.request.features == serverFeatures)
        #expect(scope.request.writer === harness.writer)
        #expect(harness.current.current === scope.control)
        #expect(harness.participant.playItem != nil)
    }

    /// Features are never invented: offline and unknown, the scope gets `nil` (and can't stream).
    @Test func unknownFeaturesReachTheScopeAsNil() async throws {
        let harness = try Harness(restoredPhase: .active(identityA, isOffline: true))
        harness.features.byUser = [:]
        try await harness.started()

        let scope = try #require(harness.scopes.last)
        #expect(scope.request.features == nil)
        #expect(scope.request.client == nil)
    }

    /// One writer for every scope, so a retired scope's late write can't supersede a newer one.
    @Test func everyScopeSharesTheOneWriter() async throws {
        let harness = try Harness()
        try await harness.started()
        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.scopes.all.count == 2 })

        let writers = harness.scopes.all.map(\.request.writer)
        #expect(writers[0] === writers[1])
        #expect(writers[0] === harness.writer)
        // The control: a store of its own is a different writer.
        let fresh = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        #expect(writers[0] !== fresh)
    }

    @Test func aSwitchSavesRetiresAndReleasesBeforeTheNextScope() async throws {
        let harness = try Harness()
        try await harness.started()

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })

        let scopeLog = harness.log.entries.filter { $0.hasPrefix("a.") || $0.hasPrefix("b.") }
        #expect(
            scopeLog == [
                "a.saveLocally", "a.retire(accountSwitch)", "a.finish", "a.finished", "b.make", "b.restore",
            ])
        #expect(harness.current.current === harness.scopes.last?.control)
        #expect(harness.scopes.all[0].retiredReason == .accountSwitch)
        if case .success = harness.participant.lastEnd {} else { Issue.record("Expected a successful end") }
    }

    /// Expiry must not reach the server: no flush, only the retirement.
    @Test func expiryRetiresWithoutFlushing() async throws {
        let harness = try Harness()
        try await harness.started()

        harness.source.expire()
        #expect(await eventually { harness.log.entries.contains("a.finished") })

        #expect(harness.log.entries.filter { $0.hasPrefix("a.") } == ["a.retire(expired)", "a.finish", "a.finished"])
        #expect(harness.current.current == nil)
        #expect(harness.participant.playItem == nil)
    }

    /// The scope stops in the synchronous part of `sessionWillEnd`: with the teardown's budget
    /// spent and the close held past it, the lifecycle moves on, and by then A is already
    /// retired. A's late close later lands without touching B.
    @Test func aScopeRetiresBeforeTheLifecycleMovesOnWithoutItsClose() async throws {
        let harness = try Harness()
        try await harness.started()
        let socketGate = Gate()
        harness.socket.endGate = socketGate
        let finishGate = Gate()
        try #require(harness.scopes.last).finishGate = finishGate
        let scopeA = try #require(harness.scopes.last)
        harness.images.onEnd = { [log = harness.log] in
            log.record(scopeA.retiredReason == nil ? "images.sawLiveA" : "images.sawRetiredA")
        }

        let switching = Task { try await harness.lifecycle.switchAccount(to: identityB.connectionID) }
        #expect(
            await eventually { harness.log.entries.contains("socket.end(switch)") && harness.clock.sleeperCount == 1 })
        // Spends the budget while the socket holds it; the playback end then gets no time.
        harness.clock.advance(by: .seconds(3))
        try await switching.value
        #expect(await eventually { harness.log.entries.contains("b.restore") })

        #expect(harness.log.entries.contains("images.sawRetiredA"))
        #expect(!harness.log.entries.contains("a.finished"))
        let scopeB = try #require(harness.scopes.last)
        #expect(scopeB !== scopeA)
        #expect(harness.current.current === scopeB.control)

        // A's close finishes late: recorded, and B stays bound.
        scopeA.finishResult = .failure(PlaybackCloseError.timedOut)
        finishGate.open()
        #expect(await eventually { harness.log.entries.contains("a.finished") })
        #expect(await eventually { harness.participant.lastEnd != nil })
        #expect(harness.current.current === scopeB.control)
        if case .failure(PlaybackCloseError.timedOut) = harness.participant.lastEnd {
        } else {
            Issue.record("Expected A's timed-out close")
        }
        socketGate.open()
    }

    /// A reconnect swaps the client and features into the same scope; nothing is rebuilt.
    @Test func reconnectSwapsIntoTheSameScope() async throws {
        let harness = try Harness(restoredPhase: .active(identityA, isOffline: true))
        harness.features.byUser = [:]
        try await harness.started()
        let scope = try #require(harness.scopes.last)

        harness.features.byUser = ["a": serverFeatures]
        let client = try makeClient()
        await harness.source.reconnect(client: client)
        #expect(await eventually { harness.log.entries.contains("a.reconnect") })

        #expect(harness.scopes.all.count == 1)
        #expect(!harness.log.entries.contains("a.make"))
        #expect(!harness.log.entries.contains { $0.hasPrefix("a.retire") })
        #expect(scope.reconnects.count == 1)
        #expect(scope.reconnects.first?.client === client)
        #expect(scope.reconnects.first?.features == serverFeatures)
        #expect(harness.current.current === scope.control)
    }

    @Test func flushSavesLocallyOnlyWhileRunning() async throws {
        let harness = try Harness()
        try await harness.started()

        await harness.participant.flush()
        #expect(harness.log.entries == ["a.saveLocally"])

        await harness.lifecycle.signOut()
        #expect(await eventually { harness.log.entries.contains("a.finished") })
        harness.log.clear()
        await harness.participant.flush()
        #expect(harness.log.entries.isEmpty)
    }

    @Test func playItemPlaysInTheCurrentScope() async throws {
        let harness = try Harness()
        try await harness.started()

        let playItem = try #require(harness.participant.playItem)
        try await playItem(itemID: "li_book")
        #expect(harness.log.entries == ["a.play(li_book)"])

        await harness.lifecycle.signOut()
        #expect(harness.participant.playItem == nil)
    }

    /// An expired session start signs the session out, once it's still the current one.
    @Test func aRejectedSessionRequestsSignOutOnlyWhileCurrent() async throws {
        let harness = try Harness()
        try await harness.started()
        let scopeA = try #require(harness.scopes.last)
        let rejectA = try #require(scopeA.onSessionRejected)

        rejectA()
        #expect(harness.signOuts.entries == ["signOut(a)"])

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        #expect(scopeA.onSessionRejected == nil)
        rejectA()
        #expect(harness.signOuts.entries == ["signOut(a)"])
    }
}
