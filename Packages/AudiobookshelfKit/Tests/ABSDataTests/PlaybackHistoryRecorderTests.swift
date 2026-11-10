import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSData

@Suite struct PlaybackHistoryRecorderTests {
    private let now = Fixtures.date
    private let media = PlaybackHistoryMedia(
        key: MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1", episodeId: "ep_1"),
        displayTitle: "Episode 1"
    )

    /// A recorder whose clock starts at `now` and advances one second per event.
    private func makeRecorder() throws -> (PlaybackHistoryRecorder, PlaybackHistoryStore) {
        let store = PlaybackHistoryStore(modelContainer: try DataStack(location: .inMemory).container)
        let clock = SteppingClock(start: now)
        return (PlaybackHistoryRecorder(store: store, now: clock.next), store)
    }

    @Test func recordsPlaybackEventsWithTheirSyncResult() async throws {
        let (recorder, store) = try makeRecorder()
        await recorder.record(.play, for: media, at: 10)
        await recorder.record(.save, for: media, at: 25.5, sync: .succeeded, details: nil)
        await recorder.record(.pause, for: media, at: 30, sync: .failed(message: "offline"), details: nil)

        let events = try await store.events(for: media.key)
        #expect(events.map(\.name) == [.pause, .save, .play])
        let pause = try #require(events.first)
        #expect(pause.type == .playback)
        #expect(pause.currentTime == 30)
        #expect(pause.timestamp == now.addingTimeInterval(2))
        #expect(pause.mediaDisplayTitle == "Episode 1")
        #expect(pause.serverConnectionID == Fixtures.connectionID)
        #expect(pause.serverSyncAttempted)
        #expect(pause.serverSyncSuccess == false)
        #expect(pause.serverSyncMessage == "offline")
        let save = events[1]
        #expect(save.serverSyncAttempted && save.serverSyncSuccess == true && save.serverSyncMessage == nil)
        let play = events[2]
        #expect(play.serverSyncAttempted == false && play.serverSyncSuccess == nil)
    }

    @Test func syncEventsNeedExistingHistory() async throws {
        let (recorder, store) = try makeRecorder()
        await recorder.record(.sync, for: media, at: 40, sync: .notAttempted, details: "Socket update")
        #expect(try await store.hasEvents(for: media.key) == false)

        await recorder.record(.play, for: media, at: 0)
        await recorder.record(.sync, for: media, at: 40, sync: .notAttempted, details: "Socket update")
        let sync = try #require(try await store.events(for: media.key).first { $0.name == .sync })
        #expect(sync.type == .sync)
        #expect(sync.details == "Socket update")
        #expect(sync.currentTime == 40)
    }

    @Test func invalidPositionsAreClampedOrDropped() throws {
        let (recorder, _) = try makeRecorder()
        let negative = recorder.event(.seek, for: media, at: -3, sync: .notAttempted, details: nil)
        #expect(negative.currentTime == 0)
        let infinite = recorder.event(.seek, for: media, at: .infinity, sync: .notAttempted, details: nil)
        #expect(infinite.currentTime == nil)
        let missing = recorder.event(.stop, for: media, at: nil, sync: .notAttempted, details: nil)
        #expect(missing.currentTime == nil)
    }
}

/// Returns `start`, then one second later on each call.
private final class SteppingClock: Sendable {
    private let date: Mutex<Date>

    init(start: Date) {
        date = Mutex(start)
    }

    @Sendable func next() -> Date {
        date.withLock { date in
            defer { date.addTimeInterval(1) }
            return date
        }
    }
}
