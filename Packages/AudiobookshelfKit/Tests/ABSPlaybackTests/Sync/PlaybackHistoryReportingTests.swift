import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// Records what ``ProgressSyncer`` hands to playback history; while `hold` is set, each record
/// waits for it, as a slow store would.
final class HistorySpy: PlaybackHistoryRecording {
    struct Entry: Equatable {
        let name: PlaybackHistoryEventName
        let key: MediaKey
        let title: String
        let position: TimeInterval?
        let sync: PlaybackHistorySyncResult
        let details: String?
    }

    private let state = Mutex<(entries: [Entry], hold: Gate?, recorded: Gate?)>(([], nil, nil))

    var entries: [Entry] { state.withLock { $0.entries } }
    func entries(_ name: PlaybackHistoryEventName) -> [Entry] { entries.filter { $0.name == name } }

    func hold(_ gate: Gate?) { state.withLock { $0.hold = gate } }
    /// Opens `gate` once the next entry is recorded.
    func signal(_ gate: Gate) { state.withLock { $0.recorded = gate } }

    func record(
        _ name: PlaybackHistoryEventName, for media: PlaybackHistoryMedia, at position: TimeInterval?,
        sync: PlaybackHistorySyncResult, details: String?
    ) async {
        if let gate = state.withLock({ $0.hold }) { await gate.wait() }
        let entry = Entry(
            name: name, key: media.key, title: media.displayTitle, position: position, sync: sync, details: details)
        let recorded = state.withLock {
            $0.entries.append(entry)
            defer { $0.recorded = nil }
            return $0.recorded
        }
        recorded?.open()
    }
}

/// The coordinator as the syncer's source, with `before` running ahead of the syncer's
/// observer: as if another observer ran first (the coordinator's order is unspecified).
@MainActor
private final class ObserverFirstSource: PlaybackProgressSource {
    let base: PlaybackCoordinator
    var before: (@MainActor (PlaybackCoordinatorEvent) -> Void)?

    init(_ base: PlaybackCoordinator) { self.base = base }

    var currentTime: Double { base.currentTime }
    var confirmedPlaybackTime: Double? { base.confirmedPlaybackTime }
    var loadedPositionIsExplicit: Bool { base.loadedPositionIsExplicit }
    var duration: Double { base.duration }
    var isPlaying: Bool { base.isPlaying }
    var chapterIndex: Int? { base.chapterIndex }
    var sessionDisplayTitle: String? { base.sessionDisplayTitle }
    var resumeRewindLanding: Double? { base.resumeRewindLanding }
    var startProgressChange: ServerAudioPositionChange? { base.startProgressChange }
    var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackCloseHandoff?)? {
        get { base.finalCloseReport }
        set { base.finalCloseReport = newValue }
    }
    var quiesceProgressTransport: (@MainActor () -> Void)? {
        get { base.quiesceProgressTransport }
        set { base.quiesceProgressTransport = newValue }
    }

    func addObserver(_ handler: @escaping @MainActor (PlaybackCoordinatorEvent) -> Void) -> PlaybackObserverToken {
        base.addObserver { [weak self] event in
            self?.before?(event)
            handler(event)
        }
    }

    func removeObserver(_ token: PlaybackObserverToken) { base.removeObserver(token) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackHistoryReportingTests {
    private static func harness() throws -> (SyncHarness, HistorySpy) {
        let spy = HistorySpy()
        return (try SyncHarness(history: spy), spy)
    }

    private static func settle(_ s: SyncHarness) async {
        await s.settle()
        await s.syncer.waitForHistory()
    }

    @Test func playIsRecordedAtTheStartPosition() async throws {
        let (s, spy) = try Self.harness()
        await s.coordinator.play(itemID: "a", startTime: 120)
        await Self.settle(s)

        #expect(
            spy.entries(.play) == [
                .init(
                    name: .play, key: s.h.key("a"), title: "Title a", position: 120, sync: .notAttempted,
                    details: nil)
            ])
    }

    @Test func seeksAreRecordedButNotTheResumeLanding() async throws {
        let (s, spy) = try Self.harness()
        await s.coordinator.play(itemID: "a", startTime: 120)
        await s.play(for: 1)
        await s.coordinator.seek(to: 500)
        await Self.settle(s)

        #expect(spy.entries(.seek).map(\.position) == [500])
        #expect(spy.entries(.seek).map(\.sync) == [.notAttempted])
    }

    nonisolated static let syncOutcomes: [(APIError?, PlaybackHistorySyncResult)] = [
        (nil, .succeeded), (.http(status: 500, message: "down"), .failed(message: "http")),
    ]

    @Test(arguments: syncOutcomes)
    func pauseCarriesItsSyncResult(error: APIError?, result: PlaybackHistorySyncResult) async throws {
        let (s, spy) = try Self.harness()
        s.service.state.withLock { $0.syncErrors = [error] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 4)
        s.coordinator.pause()
        await Self.settle(s)
        // Pausing again (a sleep timer cancelling its resume) may report, but isn't another pause.
        s.coordinator.pause()
        await Self.settle(s)

        #expect(s.service.reports.first?.currentTime == 4)
        #expect(spy.entries(.pause).map(\.position) == [4])
        #expect(spy.entries(.pause).map(\.sync) == [result])
    }

    @Test(arguments: syncOutcomes)
    func periodicSavesCarryTheirSyncResult(error: APIError?, result: PlaybackHistorySyncResult) async throws {
        let (s, spy) = try Self.harness()
        s.service.state.withLock { $0.syncErrors = [error] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await Self.settle(s)

        #expect(spy.entries(.save).map(\.position) == [15])
        #expect(spy.entries(.save).map(\.sync) == [result])
    }

    @Test func aPauseHeldBackByTheBackoffIsNotAttempted() async throws {
        let (s, spy) = try Self.harness()
        s.service.state.withLock { $0.syncErrors = [.http(status: 503, message: nil)] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        // The backoff (15 s) holds the pause's report back: the position is only saved.
        await s.play(for: 2)
        s.coordinator.pause()
        await Self.settle(s)

        #expect(s.service.reports.count == 1)
        #expect(spy.entries(.save).map(\.sync) == [.failed(message: "http")])
        #expect(spy.entries(.pause).map(\.sync) == [.notAttempted])
        #expect(spy.entries(.pause).map(\.position) == [17])
    }

    @Test func finishedIsRecordedAtTheDurationWithItsSyncResult() async throws {
        let (s, spy) = try Self.harness()
        await s.coordinator.play(itemID: "a", startTime: 3590)
        await s.play(for: 2)
        s.h.engine.finish()
        await Self.settle(s)

        #expect(s.service.reports.last?.currentTime == 3600)
        #expect(spy.entries(.finished).map(\.position) == [3600])
        #expect(spy.entries(.finished).map(\.sync) == [.succeeded])
        #expect(spy.entries(.pause).isEmpty)
    }

    /// A harness whose syncer sees each event after an observer that stops on the events
    /// `stopsOn` matches. The syncer holds its source weakly: keep the returned one alive.
    private static func harness(
        stoppingFirstOn stopsOn: @escaping @MainActor (PlaybackCoordinatorEvent) -> Bool
    ) throws -> (SyncHarness, HistorySpy, ObserverFirstSource) {
        let spy = HistorySpy()
        var wrapped: ObserverFirstSource?
        let s = try SyncHarness(history: spy) { coordinator in
            let source = ObserverFirstSource(coordinator)
            wrapped = source
            return source
        }
        let source = try #require(wrapped)
        source.before = { [coordinator = s.coordinator] event in
            if stopsOn(event) { coordinator.stop() }
        }
        return (s, spy, source)
    }

    @Test func finishedIsRecordedWhenAnotherEndedObserverStopsFirst() async throws {
        let (s, spy, source) = try Self.harness { if case .ended = $0 { true } else { false } }
        await s.coordinator.play(itemID: "a", startTime: 3590)
        await s.play(for: 2)
        s.h.engine.finish()
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)
        withExtendedLifetime(source) {}

        #expect(s.h.service.closes.count == 1)
        #expect(spy.entries.filter { $0.name != .play }.map(\.name) == [.finished, .stop])
        #expect(spy.entries(.finished).map(\.position) == [3600])
        #expect(spy.entries(.finished).map(\.sync) == [.succeeded])
        #expect(spy.entries(.stop).map(\.sync) == [.succeeded])
    }

    @Test func pauseIsRecordedWhenAnotherObserverStopsFirst() async throws {
        let (s, spy, source) = try Self.harness { if case .paused = $0 { true } else { false } }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        s.coordinator.pause()
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)
        withExtendedLifetime(source) {}

        #expect(spy.entries.map(\.name) == [.play, .pause, .stop])
        #expect(spy.entries(.pause).map(\.position) == [6])
        // The `/close` carries the pause's report.
        #expect(spy.entries(.pause).map(\.sync) == [.succeeded])
        #expect(spy.entries(.stop).map(\.sync) == [.succeeded])
    }

    @Test func seekIsRecordedWhenAnotherObserverStopsFirst() async throws {
        let (s, spy, source) = try Self.harness {
            // Not the load's own seek: the user's.
            if case .didSeek(let time) = $0 { time == 100 } else { false }
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        await s.coordinator.seek(to: 100)
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)
        withExtendedLifetime(source) {}

        #expect(spy.entries.map(\.name) == [.play, .seek, .stop])
        #expect(spy.entries(.seek).map(\.position) == [100])
        #expect(spy.entries(.seek).map(\.sync) == [.notAttempted])
        #expect(spy.entries(.stop).map(\.position) == [100])
    }

    @Test func playIsRecordedWhenAnotherObserverStopsFirst() async throws {
        let (s, spy, source) = try Self.harness { if case .playbackStarted = $0 { true } else { false } }
        await s.coordinator.play(itemID: "a", startTime: 120)
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)
        withExtendedLifetime(source) {}

        #expect(spy.entries.map(\.name) == [.play, .stop])
        #expect(spy.entries.map(\.position) == [120, 120])
        #expect(spy.entries(.play).map(\.sync) == [.notAttempted])
    }

    nonisolated static let closeOutcomes: [(String, PlaybackHistorySyncResult)] = [
        ("acknowledged", .succeeded), ("failed", .failed(message: "http")), ("signOut", .notAttempted),
    ]

    @Test(arguments: closeOutcomes)
    func stopCarriesTheCloseResult(close: String, result: PlaybackHistorySyncResult) async throws {
        let (s, spy) = try Self.harness()
        if close == "failed" { s.h.service.state.withLock { $0.closeError = .http(status: 500, message: nil) } }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        s.coordinator.stop(reason: close == "signOut" ? .signOut : .user)
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)

        #expect(spy.entries(.stop).map(\.position) == [6])
        #expect(spy.entries(.stop).map(\.sync) == [result])
        #expect(spy.entries(.stop).map(\.title) == ["Title a"])
    }

    @Test func aPauseClosedBeforeItsSyncCarriesTheCloseResult() async throws {
        let (s, spy) = try Self.harness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        // The pause's `/sync` is still queued when the session closes: the `/close` reports it.
        s.coordinator.pause()
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)

        #expect(s.service.reports.isEmpty)
        #expect(spy.entries.filter { $0.name != .play }.map(\.name) == [.pause, .stop])
        #expect(spy.entries(.pause).map(\.sync) == [.succeeded])
    }

    @Test func aPauseClosedWhileItsSyncIsPreparedCarriesTheCloseResult() async throws {
        let (s, spy) = try Self.harness()
        let preparing = Gate()
        let preparation = Gate()
        defer { preparation.open() }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        s.syncer.beforeSessionAudioPreparation = {
            preparing.open()
            await preparation.wait()
        }
        s.coordinator.pause()
        await preparing.wait()
        // The session closes while the pause's `/sync` is still being prepared, so never sent.
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        preparation.open()
        await Self.settle(s)
        s.syncer.beforeSessionAudioPreparation = nil

        #expect(s.service.reports.isEmpty)
        #expect(spy.entries.filter { $0.name != .play }.map(\.name) == [.pause, .stop])
        #expect(spy.entries(.pause).map(\.sync) == [.succeeded])
    }

    @Test func aReusedSessionIDClosingWhileItsCloseIsPendingIsNotAttempted() async throws {
        let (s, spy) = try Self.harness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        let gate = Gate()
        defer { gate.open() }
        let session = try #require(s.coordinator.session)
        s.h.service.state.withLock {
            $0.closeGates[session.id] = gate
            // The server hands out the same session ID again.
            $0.sessionOverride = session
        }
        s.h.sleep.elapsesImmediately = true
        s.coordinator.stop()
        await s.coordinator.play(itemID: "a")
        #expect(s.coordinator.session?.id == session.id)
        await s.play(for: 3)
        // Its close is still pending, so this one is never sent.
        s.coordinator.stop()
        await yieldUntil { !spy.entries(.stop).isEmpty }

        #expect(spy.entries(.stop).map(\.position) == [9])
        // Without a result, the history waits forever: stop here rather than hang.
        try #require(spy.entries(.stop).map(\.sync) == [.notAttempted])
        gate.open()
        await s.coordinator.waitForPendingCloses()
        await Self.settle(s)
        #expect(s.h.service.closes == [session.id])
        #expect(spy.entries(.stop).map(\.position) == [9, 6])
        #expect(spy.entries(.stop).map(\.sync) == [.notAttempted, .succeeded])
    }

    @Test func aReplacementUnderAReusedIDKeepsItsOwnPauseResult() async throws {
        let (s, spy) = try Self.harness()
        let preparing = Gate()
        let preparation = Gate()
        defer { preparation.open() }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 6)
        let session = try #require(s.coordinator.session)
        // The server hands out the same session ID again.
        s.h.service.state.withLock { $0.sessionOverride = session }
        s.syncer.beforeSessionAudioPreparation = {
            preparing.open()
            await preparation.wait()
        }
        s.coordinator.pause()
        await preparing.wait()
        // The session closes while the pause's `/sync` is prepared: its `/close` reports the pause.
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        s.syncer.beforeSessionAudioPreparation = nil
        // The replacement, under the same ID, pauses while the old `/sync` is still held.
        await s.coordinator.play(itemID: "a")
        #expect(s.coordinator.session?.id == session.id)
        await s.play(for: 3, settling: false)
        s.coordinator.pause()
        preparation.open()
        await Self.settle(s)

        #expect(s.service.reports.map(\.currentTime) == [9])
        #expect(spy.entries(.pause).map(\.position) == [6, 9])
        #expect(spy.entries(.pause).map(\.sync) == [.succeeded, .succeeded])
    }

    @Test func closeEventsAreRecordedAfterTheLogIsReleased() async throws {
        let spy = HistorySpy()
        let recorded = Gate()
        spy.signal(recorded)
        let close = PlaybackCloseResult<Bool>()
        let media = PlaybackHistoryMedia(key: .init(serverConnectionID: UUID(), libraryItemId: "a"), displayTitle: "A")
        var log: PlaybackHistoryLog? = PlaybackHistoryLog(spy)
        log?.record([.init(name: .stop, media: media, position: 6)], after: close)
        // The playback scope released its syncer before its `/close` answered.
        log = nil
        close.resolve(.success(true))
        await recorded.wait()

        #expect(spy.entries.map(\.name) == [.stop])
        #expect(spy.entries.map(\.sync) == [.succeeded])
    }

    @Test func serverProgressIsASyncOnlyWhenItMovesTheStoredPosition() async throws {
        let (s, spy) = try Self.harness()
        await ActiveRefreshFixture.loadPaused(s)
        for _ in 0..<2 {
            s.h.clock.advance(by: 60)
            let response = ActiveRefreshFixture.reply(s, time: 900)
            s.service.state.withLock { $0.serverProgress[s.h.key("a")] = response }
            await s.syncer.drainPendingProgress()
            await Self.settle(s)
        }

        #expect(s.service.state.withLock { $0.fetches.count } == 2)
        // Playback stays where it was; the second fetch moved nothing.
        #expect(spy.entries(.sync).map(\.position) == [900])
    }

    @Test func aSyncIsRecordedEvenWhenAnEarlierRecordIsSlow() async throws {
        let (s, spy) = try Self.harness()
        let gate = Gate()
        defer { gate.open() }
        await ActiveRefreshFixture.loadPaused(s)
        spy.hold(gate)
        await s.coordinator.seek(to: 300)
        await s.settle()
        s.h.clock.advance(by: 60)
        let response = ActiveRefreshFixture.reply(s, time: 900)
        s.service.state.withLock { $0.serverProgress[s.h.key("a")] = response }
        await s.syncer.drainPendingProgress()
        await s.settle()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 900)
        s.service.state.withLock { $0.serverProgress[s.h.key("a")] = nil }
        // A later seek saves over the server's position before history catches up.
        await s.coordinator.seek(to: 50)
        await s.settle()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 50)
        gate.open()
        await Self.settle(s)

        #expect(spy.entries.map(\.name) == [.seek, .sync, .seek])
        #expect(spy.entries(.sync).map(\.position) == [900])
    }

    @Test func serverProgressAppliedAtStartIsASyncBeforeThePlay() async throws {
        let (s, spy) = try Self.harness()
        let response = ActiveRefreshFixture.reply(s, time: 900)
        s.h.service.state.withLock { $0.progress["a"] = response }
        await s.coordinator.play(itemID: "a")
        await Self.settle(s)

        #expect(spy.entries.map(\.name) == [.sync, .play])
        #expect(spy.entries.map(\.position) == [900, 900])
        #expect(spy.entries(.sync).map(\.details) == ["Fetched from the server"])
    }

    @Test func theResumeRewindIsNotASeek() async throws {
        let (s, spy) = try Self.harness()
        s.h.settings.disableAutoRewind = false
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        s.coordinator.pause()
        await s.settle()
        // Two minutes paused: resuming rewinds 10 s.
        s.h.clock.advance(by: 120)
        await s.coordinator.resume()
        await s.coordinator.seek(to: 5)
        await Self.settle(s)

        #expect(s.h.engine.seeks.contains(10))
        #expect(spy.entries(.play).map(\.position) == [0, 10])
        #expect(spy.entries(.seek).map(\.position) == [5])
    }

    @Test(arguments: [false, true])
    func anInterruptedResumeRewindIsNotASeekUnlessSuperseded(superseded: Bool) async throws {
        let (s, spy) = try Self.harness()
        s.h.settings.disableAutoRewind = false
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        s.coordinator.pause()
        await s.settle()
        s.h.clock.advance(by: 120)
        // The rewind's seek is interrupted, and the engine lands it later on a tick.
        s.h.engine.seekResults = superseded ? [.interrupted, .interrupted] : [.interrupted]
        await s.coordinator.resume()
        // A user seek, itself interrupted, replaces the rewind before it lands.
        if superseded { await s.coordinator.seek(to: 5) }
        s.h.engine.landPendingSeek()
        await Self.settle(s)

        #expect(s.h.engine.seeks.prefix(1) == [10])
        #expect(spy.entries(.seek).map(\.position) == (superseded ? [5] : []))
    }

    @Test func retryingAnInterruptedResumeRewindIsNotASeek() async throws {
        let (s, spy) = try Self.harness()
        s.h.settings.disableAutoRewind = false
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        s.coordinator.pause()
        await s.settle()
        s.h.clock.advance(by: 120)
        // The rewind's seek is interrupted; pausing and resuming again retries it, and it lands.
        s.h.engine.seekResults = [.interrupted]
        await s.coordinator.resume()
        s.coordinator.pause()
        await s.coordinator.resume()
        await Self.settle(s)

        #expect(s.h.engine.seeks.suffix(2) == [10, 10])
        #expect(s.coordinator.currentTime == 10)
        #expect(spy.entries(.seek).isEmpty)
    }

    @Test func aLateSupersededSeekLeavesTheInterruptedRewindARewind() async throws {
        let (s, spy) = try Self.harness()
        s.h.settings.disableAutoRewind = false
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        s.coordinator.pause()
        await s.settle()
        s.h.clock.advance(by: 120)
        // A user seek is held; a second one replaces it and lands.
        let held = Gate()
        defer { held.open() }
        s.h.engine.seekGates = [held]
        let first = Task { await s.coordinator.seek(to: 30) }
        await yieldUntil { s.h.engine.seeks.count == 1 }
        await s.coordinator.seek(to: 60)
        // Resuming rewinds 10 s; that seek is interrupted, so the engine owes its landing.
        s.h.engine.seekResults = [.interrupted]
        await s.coordinator.resume()
        // The held seek returns superseded, then the rewind lands on a tick.
        held.open()
        #expect(await first.value == nil)
        s.h.engine.landPendingSeek()
        await Self.settle(s)

        #expect(s.h.engine.seeks == [30, 60, 50])
        #expect(spy.entries(.seek).map(\.position) == [60])
    }

    @Test func aReportIsRecordedBeforeTheDrainAfterIt() async throws {
        let (s, spy) = try Self.harness()
        let started = Gate()
        let response = Gate()
        defer { response.open() }
        await s.coordinator.play(itemID: "a")
        s.service.state.withLock {
            $0.fetchStarted = started
            $0.fetchGates = [response]
        }
        await s.play(for: 15, settling: false)
        // The save's `/sync` succeeded; the drain after it is held at its GET.
        await started.wait()
        await s.coordinator.seek(to: 100)
        await s.syncer.waitForHistory()

        #expect(spy.entries.map(\.name) == [.play, .save, .seek])
        #expect(spy.entries(.save).map(\.sync) == [.succeeded])
        response.open()
        await Self.settle(s)
    }

    @Test(arguments: [900.0, 0])
    func serverProgressThatReplacedThePositionIsASync(serverTime: Double) async throws {
        let (s, spy) = try Self.harness()
        await ActiveRefreshFixture.loadPaused(s)
        s.h.clock.advance(by: 60)
        let response = ActiveRefreshFixture.reply(s, time: serverTime)
        s.service.state.withLock { $0.serverProgress[s.h.key("a")] = response }

        await s.syncer.drainPendingProgress()
        await Self.settle(s)

        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == serverTime)
        // The server's position matching playback's (an echo) replaced nothing.
        let expected = serverTime == 0 ? [] : [serverTime]
        #expect(spy.entries(.sync).map(\.position) == expected)
        #expect(spy.entries(.sync).allSatisfy { $0.details == "Fetched from the server" && $0.sync == .notAttempted })
    }

    @Test func recordingNeverHoldsPlaybackOrSync() async throws {
        let (s, spy) = try Self.harness()
        let gate = Gate()
        defer { gate.open() }
        spy.hold(gate)
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        s.coordinator.pause()
        await s.settle()

        #expect(s.service.reports.map(\.currentTime) == [15, 15])
        #expect(spy.entries.isEmpty)
        gate.open()
        await Self.settle(s)
        #expect(spy.entries.map(\.name) == [.play, .save, .pause])
    }

    @Test func anEventTheStoreCannotSaveIsDroppedAlone() async throws {
        let store = PlaybackHistoryStore(modelContainer: try DataStack(location: .inMemory).container)
        let s = try SyncHarness(history: PlaybackHistoryRecorder(store: store))
        await store.failNextCommit(with: CocoaError(.fileWriteUnknown))
        await s.coordinator.play(itemID: "a")
        await s.play(for: 4)
        s.coordinator.pause()
        await Self.settle(s)

        #expect(s.service.reports.map(\.currentTime) == [4])
        #expect(try await store.events(for: s.h.key("a")).map(\.name) == [.pause])
    }

    /// Each item keeps its own history: past the cap, the item's oldest saves go first, so its
    /// oldest play stays, and other items are untouched.
    @Test func historyIsPrunedPerItemSavesFirst() async throws {
        let store = PlaybackHistoryStore(modelContainer: try DataStack(location: .inMemory).container)
        let clock = TestClock()
        let s = try SyncHarness(history: PlaybackHistoryRecorder(store: store, now: { clock.now }))
        let (a, b) = (s.h.key("a"), s.h.key("b"))
        let past = Mutex(clock.now.addingTimeInterval(-10_000))
        let backfill = PlaybackHistoryRecorder(store: store) {
            past.withLock {
                $0.addTimeInterval(1)
                return $0
            }
        }
        await backfill.record(.save, for: .init(key: b, displayTitle: "Title b"), at: 1)
        await backfill.record(.play, for: .init(key: a, displayTitle: "Title a"), at: 0)
        for index in 1..<PlaybackHistoryStore.maxEventsPerMedia {
            await backfill.record(
                .save, for: .init(key: a, displayTitle: "Title a"), at: Double(index), sync: .succeeded, details: nil)
        }
        let oldest = try await store.events(for: a).suffix(2).map(\.id)

        await s.coordinator.play(itemID: "a", startTime: 600)
        await Self.settle(s)

        let kept = try await store.events(for: a, limit: 1_000)
        #expect(kept.count == PlaybackHistoryStore.maxEventsPerMedia)
        #expect(kept.first?.name == .play && kept.first?.currentTime == 600)
        // The oldest save went; the older play stayed.
        #expect(kept.last?.id == oldest.last && kept.last?.name == .play)
        #expect(!kept.map(\.id).contains(try #require(oldest.first)))
        #expect(try await store.events(for: b).count == 1)
    }
}
