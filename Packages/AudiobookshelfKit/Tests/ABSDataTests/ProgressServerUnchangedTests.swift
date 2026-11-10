import ABSCore
import Foundation
import Testing

@testable import ABSData

/// Whether the server still holds a group as the row last saw it: the check that keeps an unsent
/// edit when only something else changed there, shared by the sync merge and the playback coordinator.
@Suite struct ProgressServerUnchangedTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func server(
        currentTime: Double = 100, duration: Double = 1000, isFinished: Bool = false, finishedAt: Date? = nil,
        ebookLocation: String? = nil, ebookProgress: Double? = nil, lastUpdate: Date = at(0)
    ) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: currentTime, progress: duration > 0 ? currentTime / duration : 0, duration: duration,
            isFinished: isFinished, finishedAt: finishedAt, ebookLocation: ebookLocation, ebookProgress: ebookProgress,
            lastUpdate: lastUpdate)
    }

    private static func mediaProgress(
        currentTime: Double = 100, duration: Double = 1000, ebookLocation: String? = nil, lastUpdate: TimeInterval = 0
    ) -> MediaProgress {
        MediaProgress(
            id: "p", libraryItemId: "li_1", duration: duration, progress: currentTime / duration,
            currentTime: currentTime, ebookLocation: ebookLocation, ebookProgress: ebookLocation == nil ? nil : 0.5,
            lastUpdate: Int(at(lastUpdate).timeIntervalSince1970 * 1000))
    }

    private static func seek(_ currentTime: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: currentTime, duration: 1000, progress: currentTime / 1000))
    }

    // MARK: - ProgressSyncState

    @Test func rowWithoutABaselineSeesNothingUnchanged() {
        var state = ProgressSyncState(lastUpdate: Self.at(0))
        state.apply(Self.seek(200), now: Self.at(10))
        for group in ProgressGroups.each {
            #expect(!state.serverUnchanged(group, in: Self.server()))
        }
    }

    @Test func audioIsComparedToTheMergeTolerance() {
        let state = ProgressSyncState(seed: Self.server(currentTime: 100, duration: 1000))
        #expect(state.serverUnchanged(.audio, in: Self.server(currentTime: 100.9, duration: 1000.9)))
        #expect(!state.serverUnchanged(.audio, in: Self.server(currentTime: 101.1)))
        #expect(!state.serverUnchanged(.audio, in: Self.server(duration: 1002)))
        // The server's date doesn't matter: it is row-wide.
        #expect(state.serverUnchanged(.audio, in: Self.server(lastUpdate: Self.at(5000))))
    }

    @Test func eachGroupIsComparedOnItsOwnFields() {
        let state = ProgressSyncState(seed: Self.server())
        let ebookMoved = Self.server(ebookLocation: "epubcfi(/6/2)", ebookProgress: 0.5, lastUpdate: Self.at(500))
        #expect(state.serverUnchanged(.audio, in: ebookMoved))
        #expect(state.serverUnchanged(.finished, in: ebookMoved))
        #expect(!state.serverUnchanged(.ebook, in: ebookMoved))

        let finished = Self.server(isFinished: true, finishedAt: Self.at(400), lastUpdate: Self.at(500))
        #expect(state.serverUnchanged(.audio, in: finished))
        #expect(!state.serverUnchanged(.finished, in: finished))
        #expect(state.serverUnchanged(.ebook, in: finished))
    }

    @Test func mergeKeepsAnUnsentEditExactlyWhenTheServerIsUnchanged() {
        var state = ProgressSyncState(seed: Self.server())
        state.apply(Self.seek(200), now: Self.at(10))

        state.merge(Self.server(ebookLocation: "epubcfi(/6/2)", ebookProgress: 0.5, lastUpdate: Self.at(500)))
        #expect(state.dirty == [.audio])
        #expect(state.currentTime == 200)

        state.merge(Self.server(currentTime: 800, lastUpdate: Self.at(600)))
        #expect(state.dirty.isEmpty)
        #expect(state.currentTime == 800)
    }

    // MARK: - LocalMediaProgressDTO

    @Test func rowComparesTheAudioOfProgressFromTheServer() async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let unsent = try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(), now: Self.at(10))
        #expect(unsent.audioDirty)

        // Another device moved only its ebook position: the row-wide date is newer, the audio isn't.
        #expect(unsent.serverAudioUnchanged(in: Self.mediaProgress(ebookLocation: "epubcfi(/6/2)", lastUpdate: 500)))
        #expect(!unsent.serverAudioUnchanged(in: Self.mediaProgress(currentTime: 800, lastUpdate: 500)))
        #expect(!unsent.serverAudioUnchanged(in: Self.mediaProgress(duration: 2000, lastUpdate: 500)))
    }

    @Test func rowWithoutABaselineHasNoUnchangedServerAudio() async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let unseeded = try await store.recordEdit(Self.seek(200), for: key, now: Self.at(10))
        #expect(unseeded.serverBaseline == nil)
        #expect(!unseeded.serverAudioUnchanged(in: Self.mediaProgress(currentTime: 200)))
    }
}
