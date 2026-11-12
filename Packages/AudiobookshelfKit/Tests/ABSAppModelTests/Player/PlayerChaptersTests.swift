import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

/// Runs `body` with a fake playback and a view model over it, with settings in a fresh suite.
@MainActor
private func withPlayer(_ body: @MainActor (PlayerViewModel, FakePlaybackControl) async throws -> Void) async throws {
    let suiteName = "ABSAppModelTests.PlayerChapters.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let playback = FakePlaybackControl()
    try await body(PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults)), playback)
}

/// The fake's chapters as rows: 0–100, 100–250 and 250–400.
private let fixtureRows = FakePlaybackControl.chapters.enumerated().map {
    PlayerChapterRow(id: $0.offset, chapter: $0.element)
}

@MainActor
@Suite struct PlayerChaptersTests {
    @Test func chaptersComeFromLoadedTimeline() async throws {
        try await withPlayer { model, playback in
            playback.load(FakePlaybackControl.bookSession(), at: 120)
            #expect(model.hasChapters)
            #expect(model.chapters == fixtureRows)
            #expect(model.chapters.map(\.title) == ["Opening", "Middle", "Ending"])
            #expect(model.chapters.map(\.duration) == [100, 150, 150])

            // Rows are the normalised chapters: one past the end of the media is dropped.
            playback.load(
                FakePlaybackControl.bookSession(chapters: [
                    Chapter(id: 7, start: 0, end: 300, title: "In"),
                    Chapter(id: 8, start: 500, end: 600, title: "Past the end"),
                ]))
            #expect(model.chapters.map(\.title) == ["In"])
            #expect(model.chapters.map(\.id) == [0])
        }
    }

    @Test func chaptersFallBackToSessionWhenUnloaded() async throws {
        try await withPlayer { model, playback in
            playback.start(FakePlaybackControl.bookSession(), at: 260)
            #expect(playback.timeline == nil)
            #expect(model.hasChapters)
            #expect(model.chapters == fixtureRows)
            #expect(model.currentChapterIndex == 2)
        }
    }

    @Test func noChaptersWithoutTimelineOrSession() async throws {
        try await withPlayer { model, playback in
            #expect(model.chapters.isEmpty)
            #expect(!model.hasChapters)
            #expect(model.currentChapterIndex == nil)

            playback.restore(
                LastPlayedRecord(
                    serverConnectionID: FakePlaybackControl.serverID, libraryItemID: "li_book", episodeID: nil,
                    position: 120, duration: 400, timestamp: Date(timeIntervalSince1970: 0), title: "Restored",
                    author: "Author", coverPath: nil, chapterTitle: "Restored Chapter"))
            #expect(model.chapters.isEmpty)
            #expect(!model.hasChapters)
            #expect(model.currentChapterIndex == nil)

            playback.load(FakePlaybackControl.bookSession(chapters: []))
            #expect(model.chapters.isEmpty)
            #expect(!model.hasChapters)
        }
    }

    @Test func durationsClampNegativeToZero() {
        let inverted = PlayerChapterRow(id: 3, chapter: Chapter(id: 9, start: 200, end: 150, title: "Backwards"))
        #expect(inverted.duration == 0)
        #expect(inverted.start == 200)
        #expect(inverted.id == 3)
        #expect(inverted.title == "Backwards")
        #expect(PlayerChapterRow(id: 0, chapter: Chapter(id: 0, start: 10, end: 10)).duration == 0)
        #expect(PlayerChapterRow(id: 0, chapter: Chapter(id: 0, start: 10, end: 25.5)).duration == 15.5)
    }

    @Test func currentIndexFollowsTime() async throws {
        try await withPlayer { model, playback in
            playback.load(FakePlaybackControl.bookSession(), at: 0)
            #expect(model.currentChapterIndex == 0)
            playback.currentTime = 99.9
            #expect(model.currentChapterIndex == 0)
            playback.currentTime = 100
            #expect(model.currentChapterIndex == 1)
            playback.currentTime = 399
            #expect(model.currentChapterIndex == 2)

            // A gap between 100 and 150 has no current chapter.
            playback.load(
                FakePlaybackControl.bookSession(chapters: [
                    Chapter(id: 0, start: 0, end: 100, title: "One"),
                    Chapter(id: 1, start: 150, end: 400, title: "Two"),
                ]), at: 120)
            #expect(model.currentChapterIndex == nil)
            playback.currentTime = 150
            #expect(model.currentChapterIndex == 1)
        }
    }

    @Test func selectChapterSeeksToStart() async throws {
        try await withPlayer { model, playback in
            let session = FakePlaybackControl.bookSession(chapters: [
                Chapter(id: 0, start: 0, end: 3_600, title: "One"),
                Chapter(id: 1, start: 3_600, end: 7_200, title: "Two"),
            ])
            playback.load(session, at: 10)
            playback.timeline = PlaybackTimeline(
                tracks: [AudioTrack(index: 1, startOffset: 0, duration: 7_200, mimeType: "audio/mpeg")],
                chapters: session.chapters)
            playback.clearCalls()
            let row = try #require(model.chapters.last)
            await model.selectChapter(row)
            #expect(playback.calls == [.seek(3_600)])
            #expect(model.currentChapterIndex == 1)
        }
    }

    @Test func selectChapterDoesNotResumeOrPause() async throws {
        try await withPlayer { model, playback in
            playback.load(FakePlaybackControl.bookSession(), at: 10, playing: false)
            await model.selectChapter(fixtureRows[1])
            #expect(playback.calls == [.seek(100)])
            #expect(!playback.isPlaybackRequested)

            playback.load(FakePlaybackControl.bookSession(), at: 10, playing: true)
            playback.clearCalls()
            await model.selectChapter(fixtureRows[2])
            #expect(playback.calls == [.seek(250)])
            #expect(playback.isPlaybackRequested)
        }
    }
}
