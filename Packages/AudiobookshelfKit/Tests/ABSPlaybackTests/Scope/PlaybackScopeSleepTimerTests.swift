import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSPlayback

private struct TimerDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// A scope over a ``SyncHarness`` with a sleep timer attached to its coordinator, as
/// ``PlaybackScope/make(_:makeNowPlaying:)`` attaches the configured one. Only the scope holds
/// the attachment.
@MainActor
private struct TimedScope {
    let s: SyncHarness
    let settings: ScratchSettings
    let clock = ManualClock()
    let scope: PlaybackScope
    let timer: SleepTimer

    init() throws {
        s = try SyncHarness()
        settings = try ScratchSettings()
        scope = PlaybackScope(
            coordinator: s.coordinator, syncer: s.syncer, services: nil, nowPlaying: RecordingNowPlaying(),
            sleepTimer: SleepTimerAttachment(
                coordinator: s.coordinator, settings: settings.value, feedback: nil, shakeDetector: nil,
                clock: clock, tickInterval: .seconds(1)))
        timer = try #require(scope.sleepTimer)
    }

    var coordinator: PlaybackCoordinator { s.coordinator }
    var engine: CoordinatorTestEngine { s.h.engine }

    /// Plays `a` from 1000 and lets a 2-second timer expire. The fade covers the whole run, so
    /// the timer seeks back to 1000, and its grace period starts.
    func expire() async {
        await scope.play(itemID: "a", episodeID: nil, startTime: 1000)
        #expect(timer.start(.duration(2)))
        for time in 1001...1002 {
            engine.currentTime = Double(time)
            await advanceTicking(clock, timer, seconds: 1)
        }
        await until { engine.pendingSeekTarget == nil && engine.currentTime == 1000 }
        #expect(!coordinator.isPlaying)
        #expect(timer.canRestart)
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackScopeSleepTimerTests {
    @Test func makeAttachesTheConfiguredSleepTimerToItsCoordinator() throws {
        let settings = try ScratchSettings()
        var given: PlaybackCoordinator?
        let scope = try timedScope {
            given = $0
            return SleepTimerAttachment(coordinator: $0, settings: settings.value, feedback: nil, shakeDetector: nil)
        }

        #expect(given === scope.coordinator)
        #expect(scope.sleepTimer != nil)
        #expect(scope.coordinator.willResume != nil)
        // The control: without a factory, no timer and no hook.
        let plain = try timedScope(nil)
        #expect(plain.sleepTimer == nil)
        #expect(plain.coordinator.willResume == nil)
    }

    /// The player's play button resumes through the scope, and the coordinator asks the timer
    /// first: during the grace period, that restarts it.
    @Test func aResumeAsksTheTimerBeforePlaying() async throws {
        let t = try TimedScope()
        await t.expire()

        await t.scope.resume(rewindingBy: nil)

        #expect(t.coordinator.isPlaying)
        #expect(t.timer.isRunning)
        #expect(t.timer.mode == .duration(2))
    }

    /// Stopping the item is an item change, which ends the grace period.
    @Test func anItemChangeReachesTheTimer() async throws {
        let t = try TimedScope()
        await t.expire()

        t.coordinator.stop()

        #expect(!t.timer.canRestart)
    }

    /// A landed seek into the next chapter moves an end-of-chapter timer to that chapter's end
    /// at once, without waiting for a tick.
    @Test func aLandedSeekReachesTheTimer() async throws {
        let t = try TimedScope()
        await t.scope.play(itemID: "a", episodeID: nil, startTime: 500)
        #expect(t.timer.start(.endOfChapter))
        #expect(t.timer.remaining == 500)

        #expect(await t.coordinator.seek(to: 2000) == 2000)

        #expect(t.timer.remaining == 1600)
    }

    /// Retirement cancels a running timer and hands back `willResume` at once, before the close
    /// wait: nothing the timer does can reach the stopped coordinator.
    @Test func retireCancelsTheTimerBeforeTheCloseWait() async throws {
        let t = try TimedScope()
        await t.scope.play(itemID: "a", episodeID: nil, startTime: 1000)
        #expect(t.timer.start(.duration(600)))

        t.scope.retire(reason: .accountSwitch)

        #expect(!t.scope.isReleased)
        #expect(!t.timer.isRunning)
        #expect(t.coordinator.willResume == nil)
        _ = await t.scope.finishRetirement()
        #expect(t.scope.isReleased)
        #expect(!t.timer.isRunning)
    }

    /// The release detaches the timer again, as a backstop: a scope released without retiring
    /// still cancels it.
    @Test func releaseDetachesAndCancelsTheTimer() async throws {
        let t = try TimedScope()
        await t.scope.play(itemID: "a", episodeID: nil, startTime: 1000)
        #expect(t.timer.start(.duration(600)))

        _ = await t.scope.finishRetirement()

        #expect(t.scope.isReleased)
        #expect(!t.timer.isRunning)
        #expect(t.coordinator.willResume == nil)
    }
}

/// A scope built by ``PlaybackScope/make(_:makeNowPlaying:)`` over fakes, with `makeSleepTimer`.
@MainActor
private func timedScope(
    _ makeSleepTimer: (@MainActor (PlaybackCoordinator) -> SleepTimerAttachment)?
) throws -> PlaybackScope {
    let writer = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    let configuration = PlaybackScope.Configuration(
        connectionID: UUID(), client: nil, features: nil, deviceIdentifiers: TimerDevice(), writer: writer,
        settings: StubPlaybackSettings(), policy: StubStreamingPolicy(), engine: CoordinatorTestEngine(),
        tickInterval: 0.5, lastPlayed: { _ in InMemoryLastPlayedStore() }, queueStore: AdvanceQueueStore(),
        makeSleepTimer: makeSleepTimer)
    return PlaybackScope.make(configuration) { _ in RecordingNowPlaying() }
}
