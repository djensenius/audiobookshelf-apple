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
    var ebookProgressSources: EbookProgressSources? {
        EbookProgressSources(service: NoEbookProgress(), syncer: NoDrain())
    }
    var queue: (any PlaybackQueueReading)? { nil }
    private(set) lazy var sleepTimer: SleepTimer? = SleepTimer(control: control)
    func editQueue(_ edit: (PlaybackQueue) -> Void) {}

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

    var onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)?

    func syncWithServer(isFirstSync: Bool) {
        log.record("\(name).sync(\(isFirstSync ? "first" : "reconnect"))")
    }

    func flush() async {
        log.record("\(name).flush")
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

/// A server without ebook progress.
private struct NoEbookProgress: EbookProgressService {
    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? { nil }
}

/// A syncer that sends nothing.
@MainActor
private final class NoDrain: ProgressDraining {
    func drainPendingProgress() async {}
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
    let progress = ProgressLog()

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

    /// What the participant's progress sink heard, with the session it came from.
    @MainActor
    final class ProgressLog {
        var heard: [(update: PlaybackProgressUpdate, sessionID: UInt64)] = []
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
        let progress = progress
        participant = PlaybackSessionParticipant(
            current: current, writer: writer, deviceIdentifiers: FixedDevice(),
            features: { features.byUser[$0.userID] },
            requestSignOut: { signOuts.record("signOut(\($0.identity.userID))") },
            progressSink: { progress.heard.append(($0, $1.sessionID)) },
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
        try await harness.lifecycle.switchAccount(to: identityA.connectionID)
        #expect(await eventually { harness.scopes.all.count == 3 })

        #expect(harness.scopes.all.map { user(of: $0.request.connectionID) } == ["a", "b", "a"])
        let writers = harness.scopes.all.map(\.request.writer)
        #expect(writers.allSatisfy { $0 === harness.writer })
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
                "a.saveLocally", "a.flush", "a.retire(accountSwitch)", "a.finish", "a.finished", "b.make",
                "b.restore",
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
        // Runs after the playback end's synchronous part, while A's close is still held.
        harness.images.onEnd = { [log = harness.log, current = harness.current] in
            log.record(scopeA.retiredReason == nil ? "images.sawLiveA" : "images.sawRetiredA")
            log.record(current.current == nil && current.phase == .idle ? "images.sawUnbound" : "images.sawBound")
        }

        let switching = Task { try await harness.lifecycle.switchAccount(to: identityB.connectionID) }
        #expect(
            await eventually { harness.log.entries.contains("socket.end(switch)") && harness.clock.sleeperCount == 1 })
        // Spends the budget while the socket holds it; the playback end then gets no time.
        harness.clock.advance(by: .seconds(3))
        try await switching.value
        #expect(await eventually { harness.log.entries.contains("b.restore") })

        #expect(harness.log.entries.contains("images.sawRetiredA"))
        #expect(harness.log.entries.contains("images.sawUnbound"))
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

    @Test func flushSavesLocallyThenFlushesOnlyWhileRunning() async throws {
        let harness = try Harness()
        try await harness.started()

        await harness.participant.flush()
        #expect(harness.log.entries == ["a.saveLocally", "a.flush"])

        await harness.lifecycle.signOut()
        #expect(await eventually { harness.log.entries.contains("a.finished") })
        harness.log.clear()
        await harness.participant.flush()
        #expect(harness.log.entries.isEmpty)
    }

    /// Sign-out flushes the scope's progress before it retires it and before the account logs
    /// out (#184).
    @Test func signOutFlushesBeforeRetiringAndLoggingOut() async throws {
        let harness = try Harness()
        try await harness.started()

        await harness.lifecycle.signOut()
        #expect(await eventually { harness.log.entries.contains("accounts.logout") })

        let entries = harness.log.entries
        let flush = try #require(entries.firstIndex(of: "a.flush"))
        #expect(flush < (entries.firstIndex(of: "a.retire(signOut)") ?? -1))
        #expect(flush < (entries.firstIndex(of: "accounts.logout") ?? -1))
    }

    /// An online start syncs with the server as the first sync after login; an offline one
    /// doesn't, and its reconnect syncs, not as the first.
    @Test(arguments: [false, true])
    func anOnlineSessionSyncsWithTheServer(startsOffline: Bool) async throws {
        let harness = try Harness(
            restoredPhase: .active(identityA, isOffline: startsOffline), restoredClient: try makeClient())
        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("a.restore") })
        for _ in 0..<50 { await Task.yield() }
        let started = harness.log.entries.filter { $0.hasPrefix("a.") }
        #expect(started == (startsOffline ? ["a.make", "a.restore"] : ["a.make", "a.restore", "a.sync(first)"]))

        harness.log.clear()
        await harness.source.reconnect(client: try makeClient())
        #expect(await eventually { harness.log.entries.contains("a.reconnect") })
        #expect(harness.log.entries.filter { $0.hasPrefix("a.") } == ["a.reconnect", "a.sync(reconnect)"])
    }

    /// The negative control: without a client, there's no server to sync with.
    @Test func aSessionWithoutAClientDoesNotSync() async throws {
        let harness = try Harness()
        // Not `started()`, which clears the log the start wrote.
        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("a.restore") })
        for _ in 0..<50 { await Task.yield() }

        #expect(!harness.log.entries.contains { $0.hasPrefix("a.sync") })
    }

    /// The scope's progress reaches the sink with its session, until the scope retires.
    @Test func progressReachesTheSinkOnlyWhileTheScopeRuns() async throws {
        let harness = try Harness()
        try await harness.started()
        let scopeA = try #require(harness.scopes.last)
        let reportA = try #require(scopeA.onProgress)
        let update = PlaybackProgressUpdate(
            key: MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "li"), currentTime: 30,
            duration: 60, date: Date(timeIntervalSince1970: 1_800_000_000))

        reportA(update)
        #expect(harness.progress.heard.map(\.update) == [update])
        let sessionA = try #require(harness.progress.heard.first?.sessionID)

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        #expect(scopeA.onProgress == nil)
        reportA(update)
        #expect(harness.progress.heard.count == 1)

        let reportB = try #require(harness.scopes.last?.onProgress)
        reportB(update)
        #expect(harness.progress.heard.count == 2)
        #expect(harness.progress.heard.last?.sessionID != sessionA)
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

    /// A's close, held past the budget, finishes only after B has ended too: B's result stays.
    @Test func aLateEndDoesNotReplaceANewerSessionsEnd() async throws {
        let harness = try Harness()
        try await harness.started()
        let socketGate = Gate()
        harness.socket.endGate = socketGate
        let scopeA = try #require(harness.scopes.last)
        let finishGate = Gate()
        scopeA.finishGate = finishGate
        scopeA.finishResult = .failure(PlaybackCloseError.timedOut)

        let switching = Task { try await harness.lifecycle.switchAccount(to: identityB.connectionID) }
        #expect(
            await eventually { harness.log.entries.contains("socket.end(switch)") && harness.clock.sleeperCount == 1 })
        harness.clock.advance(by: .seconds(3))
        try await switching.value
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        harness.socket.endGate = nil
        socketGate.open()
        #expect(harness.participant.lastEnd == nil)

        await harness.lifecycle.signOut()
        #expect(await eventually { harness.log.entries.contains("b.finished") })
        if case .success = harness.participant.lastEnd {} else { Issue.record("Expected B's successful end") }

        finishGate.open()
        #expect(await eventually { harness.log.entries.contains("a.finished") })
        for _ in 0..<100 { await Task.yield() }
        if case .success = harness.participant.lastEnd {} else { Issue.record("A's late end replaced B's") }
    }

    /// A start while a scope is running (a misordered lifecycle) retires and releases the old
    /// scope instead of orphaning its coordinator.
    @Test func aMisorderedStartRetiresTheRunningScope() async throws {
        let harness = try Harness()
        try await harness.started()
        let misuse = CallLog()
        harness.participant.reportMisuse = { misuse.record($0) }
        let scopeA = try #require(harness.scopes.last)

        await harness.participant.sessionDidStart(
            SessionContext(identity: identityB, client: nil, isOffline: true, sessionID: .max))

        #expect(misuse.entries.count == 1)
        #expect(scopeA.retiredReason == .accountSwitch)
        #expect(scopeA.onSessionRejected == nil)
        #expect(await eventually { harness.log.entries.contains("a.finished") })
        let scopeB = try #require(harness.scopes.last)
        #expect(scopeB !== scopeA)
        #expect(harness.current.current === scopeB.control)
    }

    /// The player reads the current scope's timer from the participant.
    @Test func theSleepTimerFollowsTheCurrentScope() async throws {
        let harness = try Harness()
        try await harness.started()
        let scopeA = try #require(harness.scopes.last)
        #expect(harness.participant.sleepTimer === scopeA.sleepTimer)

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        let scopeB = try #require(harness.scopes.last)
        #expect(harness.participant.sleepTimer === scopeB.sleepTimer)
        #expect(harness.participant.sleepTimer !== scopeA.sleepTimer)

        await harness.lifecycle.signOut()
        #expect(harness.participant.sleepTimer == nil)
    }

    /// Readers build progress models for the current session's connection only: each session
    /// gets a factory of its own, a switch's outgoing factory refuses the next account's books,
    /// and there is none between sessions.
    @Test func ebookProgressFollowsTheCurrentSession() async throws {
        let harness = try Harness()
        try await harness.started()
        let factoryA = try #require(harness.participant.ebookProgress)
        let bookA = MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "book")
        let bookB = MediaKey(serverConnectionID: identityB.connectionID, libraryItemId: "book")
        #expect(factoryA.serverConnectionID == identityA.connectionID)
        #expect(factoryA(bookA, .pdf, nil)?.key == bookA)
        #expect(factoryA(bookB, .pdf, nil) == nil)

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        let factoryB = try #require(harness.participant.ebookProgress)
        #expect(factoryB !== factoryA)
        #expect(factoryB(bookB, .epub, nil)?.key == bookB)
        #expect(factoryB(bookA, .epub, nil) == nil)

        await harness.lifecycle.signOut()
        #expect(harness.participant.ebookProgress == nil)
    }

    /// Each session gets a bookmark store of its own, connected to its client, and the last
    /// session's is ended: emptied and disconnected.
    @Test func eachSessionHasItsOwnBookmarkStore() async throws {
        let harness = try Harness(restoredClient: try makeClient())
        try await harness.started()
        let storeA = try #require(harness.participant.bookmarks)
        #expect(await eventually { storeA.isAvailable })
        storeA.replaceAll(from: bookmarkUser([bookmark("item", 10)]))
        #expect(storeA.bookmarks(itemID: "item").count == 1)

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        let storeB = try #require(harness.participant.bookmarks)
        #expect(storeB !== storeA)
        #expect(await eventually { storeB.isAvailable })
        #expect(storeB.bookmarks(itemID: "item").isEmpty)
        #expect(await eventually { !storeA.isAvailable })
        #expect(storeA.bookmarks(itemID: "item").isEmpty)

        await harness.lifecycle.signOut()
        #expect(harness.participant.bookmarks == nil)
        #expect(await eventually { !storeB.isAvailable })
    }

    /// A reconnect connects the same bookmark store; nothing is rebuilt.
    @Test func reconnectConnectsTheSameBookmarkStore() async throws {
        let harness = try Harness(restoredPhase: .active(identityA, isOffline: true))
        try await harness.started()
        let store = try #require(harness.participant.bookmarks)
        #expect(!store.isAvailable)

        await harness.source.reconnect(client: try makeClient())
        #expect(await eventually { harness.log.entries.contains("a.reconnect") })

        #expect(harness.participant.bookmarks === store)
        #expect(await eventually { store.isAvailable })
    }

    /// `lastEnd` describes only the latest ended session: cleared when a scope starts retiring,
    /// set when its close finishes.
    @Test func lastEndIsClearedWhileTheLatestCloseIsHeld() async throws {
        let harness = try Harness()
        try await harness.started()
        try #require(harness.scopes.last).finishResult = .failure(PlaybackCloseError.timedOut)
        let finishGate = Gate()
        harness.scopes.finishGate = finishGate

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("b.restore") })
        harness.scopes.finishGate = nil
        if case .failure(PlaybackCloseError.timedOut) = harness.participant.lastEnd {
        } else {
            Issue.record("Expected A's end")
        }

        // B's close is held: A's result must not stand in for it.
        let switching = Task { try await harness.lifecycle.switchAccount(to: identityA.connectionID) }
        #expect(await eventually { harness.log.entries.contains("b.finish") })
        #expect(harness.participant.lastEnd == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.participant.lastEnd == nil)

        finishGate.open()
        try await switching.value
        #expect(await eventually { harness.log.entries.contains("b.finished") })
        #expect(await eventually { harness.participant.lastEnd != nil })
        if case .success = harness.participant.lastEnd {} else { Issue.record("Expected B's end") }
    }
}
