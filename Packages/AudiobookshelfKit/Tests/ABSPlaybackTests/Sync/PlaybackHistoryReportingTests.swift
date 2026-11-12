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

    private let state = Mutex<(entries: [Entry], hold: Gate?)>(([], nil))

    var entries: [Entry] { state.withLock { $0.entries } }
    func entries(_ name: PlaybackHistoryEventName) -> [Entry] { entries.filter { $0.name == name } }

    func hold(_ gate: Gate?) { state.withLock { $0.hold = gate } }

    func record(
        _ name: PlaybackHistoryEventName, for media: PlaybackHistoryMedia, at position: TimeInterval?,
        sync: PlaybackHistorySyncResult, details: String?
    ) async {
        if let gate = state.withLock({ $0.hold }) { await gate.wait() }
        let entry = Entry(
            name: name, key: media.key, title: media.displayTitle, position: position, sync: sync, details: details)
        state.withLock { $0.entries.append(entry) }
    }
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
