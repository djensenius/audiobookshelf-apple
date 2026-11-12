import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

/// A sleep timer that records what it was asked to start.
@MainActor
private final class FakeSleepTimer: SleepTimerStarting {
    var accepts = true
    private(set) var started: [SleepTimerMode] = []

    func start(_ mode: SleepTimerMode) -> Bool {
        guard accepts else { return false }
        started.append(mode)
        return true
    }
}

/// Runs `body` with a performer over a fake playback, a fake sleep timer (`nil` with `hasTimer: false`) and
/// settings on a fresh `UserDefaults` suite, with jump intervals of 30 seconds forward and 15 back.
@MainActor
private func withPerformer(
    hasTimer: Bool = true,
    _ body: @MainActor (PlaybackIntentPerformer, FakePlaybackControl, FakeSleepTimer) async throws -> Void
) async throws {
    let suiteName = "ABSAppModelTests.Intents.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.jumpForwardTime = 30
    settings.jumpBackwardsTime = 15
    let playback = FakePlaybackControl()
    let timer = FakeSleepTimer()
    let performer = PlaybackIntentPerformer(
        playback: playback, sleepTimer: hasTimer ? timer : nil, settings: settings)
    try await body(performer, playback, timer)
}

private let restored = LastPlayedRecord(
    serverConnectionID: FakePlaybackControl.serverID, libraryItemID: "li_book", episodeID: nil, position: 120,
    duration: 400, timestamp: Date(timeIntervalSince1970: 0), title: "Restored", author: "Author", coverPath: nil,
    chapterTitle: nil)

@MainActor
@Suite struct PlaybackIntentPerformerTests {
    // MARK: Resume

    @Test func resumeResumesAPausedItem() async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 50)
            try await performer.resume()
            #expect(playback.calls == [.resume(rewindingBy: nil)])
        }
    }

    @Test func resumeStartsTheRestoredLastPlayedItem() async throws {
        try await withPerformer { performer, playback, _ in
            playback.restore(restored)
            try await performer.resume()
            #expect(playback.calls == [.resume(rewindingBy: nil)])
        }
    }

    @Test func resumeThatDoesNotStartFails() async throws {
        try await withPerformer { performer, playback, _ in
            playback.restore(restored)
            playback.resumeFailure = .unexpected("The audio session wouldn't activate")
            await #expect(throws: PlaybackIntentFailure.playbackFailed) { try await performer.resume() }
            await #expect(throws: PlaybackIntentFailure.playbackFailed) { try await performer.togglePlayPause() }
            #expect(playback.calls == [.resume(rewindingBy: nil), .resume(rewindingBy: nil)])
        }
    }

    @Test func resumeWithNothingLoadedFails() async throws {
        try await withPerformer { performer, playback, _ in
            await #expect(throws: PlaybackIntentFailure.nothingToResume) { try await performer.resume() }
            #expect(playback.calls.isEmpty)
        }
    }

    @Test func resumeSignedOutFails() async throws {
        let suiteName = "ABSAppModelTests.Intents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Signed out, the app's playback proxy is bound to nothing.
        let performer = PlaybackIntentPerformer(
            playback: CurrentPlayback(), sleepTimer: nil, settings: AppSettings(defaults: defaults))
        await #expect(throws: PlaybackIntentFailure.nothingToResume) { try await performer.resume() }
        await #expect(throws: PlaybackIntentFailure.nothingToResume) { try await performer.togglePlayPause() }
    }

    // MARK: Pause and toggle

    @Test func pausePausesTheItem() async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), playing: true)
            try performer.pause()
            #expect(playback.calls == [.pause])
        }
    }

    @Test func pauseCancelsAFirstPlayWaitingOnTheStreamingPolicy() async throws {
        try await withPerformer { performer, playback, _ in
            // The coordinator is still idle while the first play's policy check runs.
            playback.isPlaybackRequested = true
            try performer.pause()
            playback.isPlaybackRequested = true
            try await performer.togglePlayPause()
            #expect(playback.calls == [.pause, .pause])
        }
    }

    @Test func pauseWithNothingLoadedFails() async throws {
        try await withPerformer { performer, playback, _ in
            #expect(throws: PlaybackIntentFailure.nothingPlaying) { try performer.pause() }
            #expect(playback.calls.isEmpty)
        }
    }

    @Test func toggleFollowsThePlayIntent() async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), playing: true)
            try await performer.togglePlayPause()
            #expect(playback.calls == [.pause])
            try await performer.togglePlayPause()
            #expect(playback.calls == [.pause, .resume(rewindingBy: nil)])
        }
    }

    @Test func togglePausesWhileStarting() async throws {
        try await withPerformer { performer, playback, _ in
            playback.start(FakePlaybackControl.bookSession())
            try await performer.togglePlayPause()
            #expect(playback.calls == [.pause])
        }
    }

    @Test func toggleWithNothingLoadedFails() async throws {
        try await withPerformer { performer, playback, _ in
            await #expect(throws: PlaybackIntentFailure.nothingToResume) { try await performer.togglePlayPause() }
            #expect(playback.calls.isEmpty)
        }
    }

    // MARK: Jump

    @Test func jumpUsesTheUsersIntervalsByDefault() async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 100)
            let first = try await performer.jump(forward: true, seconds: nil)
            let second = try await performer.jump(forward: false, seconds: nil)
            #expect(first == 30)
            #expect(second == 15)
            #expect(playback.calls == [.jump(30), .jump(-15)])
        }
    }

    @Test func jumpByGivenSecondsInBothDirections() async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 100)
            let first = try await performer.jump(forward: true, seconds: 45)
            let second = try await performer.jump(forward: false, seconds: 60)
            #expect(first == 45)
            #expect(second == 60)
            #expect(playback.calls == [.jump(45), .jump(-60)])
        }
    }

    @Test func jumpByNonPositiveSecondsUsesTheUsersInterval() async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 100)
            let first = try await performer.jump(forward: true, seconds: 0)
            let second = try await performer.jump(forward: false, seconds: -20)
            #expect(first == 30)
            #expect(second == 15)
            #expect(playback.calls == [.jump(30), .jump(-15)])
        }
    }

    @Test func jumpWithNothingLoadedFails() async throws {
        try await withPerformer { performer, playback, _ in
            await #expect(throws: PlaybackIntentFailure.nothingPlaying) {
                try await performer.jump(forward: true, seconds: nil)
            }
            #expect(playback.calls.isEmpty)
        }
    }

    // MARK: Sleep timer

    @Test func sleepTimerStartsForMinutes() async throws {
        try await withPerformer { performer, playback, timer in
            playback.load(FakePlaybackControl.bookSession(), playing: true)
            let result = try performer.setSleepTimer(.minutes(30))
            #expect(result == .minutes(30))
            #expect(timer.started == [.duration(1800)])
        }
    }

    @Test func sleepTimerClampsMinutes() async throws {
        try await withPerformer { performer, playback, timer in
            playback.load(FakePlaybackControl.bookSession(), playing: true)
            let first = try performer.setSleepTimer(.minutes(0))
            let second = try performer.setSleepTimer(.minutes(5000))
            #expect(first == .minutes(1))
            #expect(second == .minutes(1440))
            #expect(timer.started == [.duration(60), .duration(1440 * 60)])
        }
    }

    @Test func sleepTimerStartsAtEndOfChapter() async throws {
        try await withPerformer { performer, playback, timer in
            playback.load(FakePlaybackControl.bookSession(), at: 50, playing: true)
            let result = try performer.setSleepTimer(.endOfChapter)
            #expect(result == .endOfChapter)
            #expect(timer.started == [.endOfChapter])
        }
    }

    @Test func sleepTimerWithoutAChapterEndFails() async throws {
        try await withPerformer { performer, playback, timer in
            playback.load(FakePlaybackControl.bookSession(), at: 400)
            timer.accepts = false
            #expect(throws: PlaybackIntentFailure.noChapterEnd) { try performer.setSleepTimer(.endOfChapter) }
            #expect(throws: PlaybackIntentFailure.sleepTimerUnavailable) { try performer.setSleepTimer(.minutes(5)) }
        }
    }

    @Test func sleepTimerWithoutATimerFails() async throws {
        try await withPerformer(hasTimer: false) { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession(), playing: true)
            #expect(throws: PlaybackIntentFailure.sleepTimerUnavailable) { try performer.setSleepTimer(.minutes(5)) }
        }
    }

    @Test func sleepTimerWithNothingLoadedFails() async throws {
        try await withPerformer { performer, _, timer in
            #expect(throws: PlaybackIntentFailure.nothingPlaying) { try performer.setSleepTimer(.minutes(5)) }
            #expect(timer.started.isEmpty)
        }
    }

    // MARK: Speed

    @Test(arguments: zip([1.5, 1.25, 0.1, 20, -1, Double.nan], [1.5, 1.3, 0.5, 10, 1, 1]))
    func speedIsNormalizedAndClamped(requested: Double, expected: Double) async throws {
        try await withPerformer { performer, playback, _ in
            playback.load(FakePlaybackControl.bookSession())
            let result = try performer.setSpeed(requested)
            #expect(result == expected)
            #expect(playback.calls == [.setRate(expected)])
        }
    }

    @Test func speedWithNothingLoadedFails() async throws {
        try await withPerformer { performer, playback, _ in
            #expect(throws: PlaybackIntentFailure.nothingPlaying) { try performer.setSpeed(1.5) }
            #expect(playback.calls.isEmpty)
        }
    }
}
