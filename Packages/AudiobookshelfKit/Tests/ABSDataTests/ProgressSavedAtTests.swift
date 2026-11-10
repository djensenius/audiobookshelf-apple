import ABSCore
import Foundation
import Testing

@testable import ABSData

/// When a row's audio and finished groups were saved, for comparing them with progress from elsewhere.
@Suite struct ProgressSavedAtTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func server(
        currentTime: Double = 100, duration: Double = 1000, ebookLocation: String? = nil, lastUpdate: Date
    ) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: currentTime, progress: duration > 0 ? currentTime / duration : 0, duration: duration,
            isFinished: false, ebookLocation: ebookLocation, lastUpdate: lastUpdate)
    }

    /// What the server holds for media that only has an ebook position: audio fields at 0.
    private static func ebookOnlyServer(lastUpdate: Date) -> ProgressBaseline {
        server(currentTime: 0, duration: 0, ebookLocation: "epubcfi(/6/2)", lastUpdate: lastUpdate)
    }

    private static func seek(_ currentTime: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: currentTime, duration: 1000, progress: currentTime / 1000))
    }

    private static let page = ProgressEdit(ebook: .init(location: "epubcfi(/6/8)", progress: 0.4))

    /// `beginSend()`, requiring a send.
    private static func send(
        _ state: inout ProgressSyncState, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ProgressSend {
        let send = state.beginSend()
        return try #require(send, sourceLocation: sourceLocation)
    }

    // MARK: - ProgressSyncState

    @Test func dirtyGroupIsDatedByItsEditNotByTheRowOrTheBaseline() {
        var state = ProgressSyncState(seed: Self.server(lastUpdate: Self.at(0)))
        state.apply(Self.seek(200), now: Self.at(10))
        #expect(state.savedAt(.audio) == Self.at(10))

        // An ebook edit moves the row's `lastUpdate`, and the server reports a later change that
        // leaves the audio as we last saw it: the unsent audio edit keeps its own date.
        state.apply(Self.page, now: Self.at(60))
        state.merge(Self.server(currentTime: 100, lastUpdate: Self.at(500)))
        #expect(state.dirty == [.audio, .ebook])
        #expect(state.lastUpdate == Self.at(500))
        #expect(state.savedAt(.audio) == Self.at(10))
        #expect(state.savedAt(.ebook) == Self.at(60))
    }

    @Test func dirtyGroupWithoutAnEditTimeIsDatedByTheRow() {
        var state = ProgressSyncState(lastUpdate: Self.at(5))
        state.dirty = [.audio, .finished]
        #expect(state.savedAt(.audio) == Self.at(5))
        #expect(state.savedAt(.finished) == Self.at(5))
    }

    @Test func cleanGroupIsDatedByTheLaterOfItsEditAndTheBaseline() throws {
        var state = ProgressSyncState(seed: Self.server(lastUpdate: Self.at(0)))
        state.apply(Self.seek(200), now: Self.at(10))
        let first = try Self.send(&state)
        state.acknowledge(first, serverLastUpdate: Self.at(12))
        #expect(state.dirty.isEmpty)
        // The server stamped it later than the device clock did …
        #expect(state.savedAt(.audio) == Self.at(12))

        state.apply(Self.seek(300), now: Self.at(100))
        let second = try Self.send(&state)
        state.acknowledge(second, serverLastUpdate: Self.at(90))
        // … or earlier (the device clock runs ahead).
        #expect(state.savedAt(.audio) == Self.at(100))
    }

    @Test func serverProgressMergedOverACleanGroupDatesItByTheBaselineNotTheOldEdit() throws {
        var state = ProgressSyncState(seed: Self.server(lastUpdate: Self.at(0)))
        state.apply(Self.seek(200), now: Self.at(10))
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: Self.at(10))

        state.merge(Self.server(currentTime: 800, lastUpdate: Self.at(500)))

        #expect(state.currentTime == 800)
        #expect(state.audioEditedAt == Self.at(10))
        #expect(state.savedAt(.audio) == Self.at(500))
    }

    @Test func seededRowIsDatedByItsBaseline() {
        let state = ProgressSyncState(seed: Self.server(lastUpdate: Self.at(30)))
        #expect(state.savedAt(.audio) == Self.at(30))
        #expect(state.savedAt(.finished) == Self.at(30))
        #expect(state.savedAt(.ebook) == Self.at(30))
    }

    @Test func ebookOnlyServerRowHasNoSavedAudio() {
        var state = ProgressSyncState(seed: Self.ebookOnlyServer(lastUpdate: Self.at(30)))
        #expect(state.savedAt(.audio) == nil)

        state.apply(Self.page, now: Self.at(60))
        #expect(state.savedAt(.audio) == nil)
        #expect(state.savedAt(.ebook) == Self.at(60))

        // Saving audio makes it a saved position, even at 0.
        state.apply(Self.seek(0), now: Self.at(90))
        #expect(state.savedAt(.audio) == Self.at(90))
    }

    @Test func serverAudioWithOnlyAPositionOrOnlyADurationIsSaved() {
        let position = ProgressSyncState(seed: Self.server(currentTime: 5, duration: 0, lastUpdate: Self.at(1)))
        let duration = ProgressSyncState(seed: Self.server(currentTime: 0, duration: 1000, lastUpdate: Self.at(2)))
        #expect(position.savedAt(.audio) == Self.at(1))
        #expect(duration.savedAt(.audio) == Self.at(2))
    }

    @Test func defaultRowHasNothingSaved() {
        var state = ProgressSyncState(lastUpdate: Self.at(5))
        #expect(state.savedAt(.audio) == nil)
        #expect(state.savedAt(.finished) == nil)
        #expect(state.savedAt(.ebook) == nil)

        // An edit of another group doesn't save audio.
        state.apply(ProgressEdit(isFinished: false), now: Self.at(20))
        #expect(state.savedAt(.audio) == nil)
        #expect(state.savedAt(.finished) == Self.at(20))
    }

    @Test func finishedGroupIsDatedByItsOwnEditUntilAcknowledged() throws {
        var state = ProgressSyncState(seed: Self.server(lastUpdate: Self.at(0)))
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(ProgressEdit(isFinished: true), now: Self.at(50))
        #expect(state.savedAt(.audio) == Self.at(10))
        #expect(state.savedAt(.finished) == Self.at(50))

        // Audio goes first, then finished; the baseline's date is row-wide, so it dates both.
        let audio = try Self.send(&state)
        state.acknowledge(audio, serverLastUpdate: Self.at(52))
        #expect(state.savedAt(.finished) == Self.at(50))
        let finished = try Self.send(&state)
        state.acknowledge(finished, serverLastUpdate: Self.at(55))
        #expect(state.savedAt(.finished) == Self.at(55))
        #expect(state.savedAt(.audio) == Self.at(55))

        // Un-finishing is dated by its own edit.
        state.apply(ProgressEdit(isFinished: false), now: Self.at(70))
        #expect(state.savedAt(.finished) == Self.at(70))
        #expect(state.savedAt(.audio) == Self.at(55))
    }

    // MARK: - LocalMediaProgressDTO

    @Test func rowFromTheStoreExposesTheDates() async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let ebook = try await store.recordEdit(
            Self.page, for: key, serverProgress: Self.ebookOnlyServer(lastUpdate: Self.at(30)), now: Self.at(60))
        #expect(ebook.lastUpdate == Self.at(60))
        #expect(ebook.audioSavedAt == nil)
        #expect(ebook.finishedSavedAt == Self.at(30))

        let edited = try await store.recordEdit(Self.seek(200), for: key, now: Self.at(90))
        #expect(edited.audioSavedAt == Self.at(90))
        #expect(edited.finishedSavedAt == Self.at(30))
    }

    @Test func rowMergedWithNewerServerProgressIsDatedByTheMerge() async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        try await store.recordEdit(Self.seek(200), for: key, now: Self.at(10))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: Self.at(10))

        let capture = await store.captureGeneration()
        let merged = try await store.applyServerProgress(
            [key: Self.server(currentTime: 800, lastUpdate: Self.at(500))], capturedAt: capture, source: .fetch)
        #expect(merged == [key])

        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 800)
        #expect(row.audioEditedAt == Self.at(10))
        #expect(row.audioSavedAt == Self.at(500))
    }
}
