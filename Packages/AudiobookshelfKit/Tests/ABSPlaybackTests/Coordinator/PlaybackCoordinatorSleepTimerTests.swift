import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// Real timer and coordinator, connected by a ``SleepTimerAttachment``, with deterministic time, engine seeks and Now
/// Playing publication.
@MainActor
private final class CoordinatorTimerHarness {
    let b: BridgeHarness
    let clock = ManualClock()
    let feedback = FakeFeedback()
    let settings: ScratchSettings
    let attachment: SleepTimerAttachment
    private(set) var willResumeCount = 0

    var h: CoordinatorHarness { b.h }
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var timer: SleepTimer { attachment.timer }

    init(automatic: Bool = false) throws {
        b = try BridgeHarness()
        let date = try makeDate(2026, 1, 15, 23, 0)
        settings = try ScratchSettings()
        if automatic {
            settings.value.autoSleepTimer = true
            settings.value.sleepTimerLength = 70_000
            settings.value.autoSleepTimerAutoRewind = true
            settings.value.autoSleepTimerAutoRewindTime = 300_000
        }
        attachment = SleepTimerAttachment(
            coordinator: b.coordinator, settings: settings.value, feedback: feedback, shakeDetector: nil,
            clock: clock, calendar: .gregorianUTC, now: { date }, tickInterval: .seconds(1))
        let willResume = coordinator.willResume
        coordinator.willResume = { [weak self] in
            self?.willResumeCount += 1
            return willResume?() ?? 0
        }
    }

    /// Plays 70 seconds from 1000. The fade starts at 1010; expiry pauses at 1070.
    func expire() async {
        await coordinator.play(itemID: "A", startTime: 1000)
        if !timer.isRunning { #expect(timer.start(.duration(70))) }
        for time in 1001...1070 {
            engine.currentTime = Double(time)
            await advanceTicking(clock, timer, seconds: 1)
        }
        #expect(!coordinator.isPlaying)
        #expect(timer.canRestart)
        #expect(!timer.isRunning)
    }

    func waitForFadeRewind() async {
        await until { engine.pendingSeekTarget == nil && engine.currentTime == 1010 }
        #expect(engine.seeks == [1010])
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackCoordinatorSleepTimerTests {
    @Test func expiryFadesPausesPublishesAndRestoresVolume() async throws {
        let t = try CoordinatorTimerHarness()
        await t.expire()
        await t.waitForFadeRewind()

        let ramp = (1...59).reversed().map { Float(Double($0) / 60) }
        #expect(t.engine.volumes == ramp + [1])
        #expect(t.engine.volumeAtPause == Float(1.0 / 60))
        #expect(t.engine.volume == 1)
        #expect(t.engine.playCount == 1)
        #expect(t.willResumeCount == 1, "The timer's pause and seek are plain commands")
        #expect(
            Array(t.h.events.events.suffix(2)) == [.paused(time: 1070), .didSeek(time: 1010)])
        #expect(try t.b.session.snapshot == t.b.snapshot(.paused, at: 1010))
        t.timer.cancel()
    }

    @Test func graceResetRewindsAndResumesExactlyOnceWithoutAnotherWillResume() async throws {
        let t = try CoordinatorTimerHarness(automatic: true)
        await t.expire()
        await t.waitForFadeRewind()
        let events = t.h.events.count
        t.h.clock.advance(by: 3600)  // A normal resume would also apply AutoRewind.
        t.h.settings.playbackRate = 1.5

        #expect(t.timer.reset())
        await until { t.coordinator.isPlaying }

        #expect(t.engine.seeks == [1010, 710])
        #expect(t.engine.currentTime == 710)
        #expect(t.engine.playCount == 2)
        #expect(t.engine.defaultRate == 1.5)
        #expect(t.willResumeCount == 1)
        #expect(t.feedback.resets == 1)
        #expect(t.timer.mode == .duration(70))
        #expect(t.timer.remaining == 70)
        #expect(t.engine.volume == 1)
        #expect(t.h.events.since(events) == [.didSeek(time: 710), .playbackStarted])
        #expect(try t.b.session.snapshot == t.b.snapshot(.playing(rate: 1.5), at: 710))
        t.timer.cancel()
    }

    @Test func graceResetUsesPendingFadeTargetRatherThanOldEngineTime() async throws {
        let t = try CoordinatorTimerHarness(automatic: true)
        let gate = Gate()
        defer { gate.open() }
        t.engine.seekGates = [gate]
        await t.expire()
        await until { t.coordinator.pendingSeekTarget == 1010 }
        #expect(t.engine.currentTime == 1070)

        #expect(t.timer.reset())
        await until { t.coordinator.isPlaying }
        gate.open()
        await until { t.engine.returnedSeekCount == 2 }

        #expect(t.engine.seeks == [1010, 710], "Rewind 300 from the pending fade target, not 1070")
        #expect(t.engine.currentTime == 710)
        #expect(t.engine.playCount == 2)
        #expect(t.willResumeCount == 1)
        #expect(t.feedback.resets == 1)
        #expect(t.coordinator.pendingSeekTarget == nil)
        t.timer.cancel()
    }

    @Test(arguments: [false, true])
    func userSeekSupersedesTimerRewind(duringGraceReset: Bool) async throws {
        let t = try CoordinatorTimerHarness(automatic: true)
        let gate = Gate()
        defer { gate.open() }
        if !duringGraceReset { t.engine.seekGates = [gate] }
        await t.expire()
        if duringGraceReset {
            await t.waitForFadeRewind()
            t.engine.seekGates = [gate]
            #expect(t.timer.reset())
        }
        let target: Double = duringGraceReset ? 710 : 1010
        await until { t.coordinator.pendingSeekTarget == target }
        let events = t.h.events.count

        #expect(await t.coordinator.seek(to: 1200) == 1200)
        gate.open()
        let expectedSeeks: [Double] = duringGraceReset ? [1010, 710, 1200] : [1010, 1200]
        await until { t.engine.returnedSeekCount == expectedSeeks.count }
        if duringGraceReset { await until { t.timer.canRestart } }

        #expect(t.engine.currentTime == 1200)
        #expect(t.coordinator.pendingSeekTarget == nil)
        #expect(t.engine.playCount == 1)
        #expect(t.h.events.since(events) == [.didSeek(time: 1200)])
        #expect(t.engine.seeks == expectedSeeks)
        #expect(t.engine.volume == 1)
        // A subsequent user resume must not apply the timer's abandoned automatic rewind.
        await t.coordinator.resume(rewindingBy: 0)
        #expect(t.engine.currentTime == 1200)
        #expect(t.engine.seeks == expectedSeeks)
        #expect(t.engine.playCount == 2)
        t.timer.cancel()
    }

    @Test func remotePauseDuringGraceRewindCancelsTimerResume() async throws {
        let t = try CoordinatorTimerHarness(automatic: true)
        await t.expire()
        await t.waitForFadeRewind()
        let gate = Gate()
        defer { gate.open() }
        t.engine.seekGates = [gate]
        #expect(t.timer.reset())
        await until { t.coordinator.pendingSeekTarget == 710 }
        #expect(!t.engine.isPlaybackRequested)
        let events = t.h.events.count

        try await t.b.controller.perform(.pause)
        #expect(t.h.events.since(events) == [.paused(time: 710)])
        gate.open()
        await until { t.h.events.events.last == .didSeek(time: 710) }
        await advanceTicking(t.clock, t.timer, seconds: 1)

        #expect(t.h.events.since(events) == [.paused(time: 710), .didSeek(time: 710)])
        #expect(t.engine.playCount == 1)
        #expect(!t.coordinator.isPlaybackRequested)
        #expect(!t.coordinator.isPlaying)
        #expect(t.feedback.resets == 0)
        #expect(t.timer.remaining == 70, "No countdown while the remote pause holds")
        #expect(!t.timer.canRestart)
        #expect(t.engine.volume == 1)
        #expect(try t.b.session.snapshot == t.b.snapshot(.paused, at: 710))
        t.timer.cancel()
    }

    @Test func cancelDuringFadeRestoresVolumeWithoutPausing() async throws {
        let t = try CoordinatorTimerHarness()
        await t.coordinator.play(itemID: "A", startTime: 1000)
        #expect(t.timer.start(.duration(5)))
        await advanceTicking(t.clock, t.timer, seconds: 1)
        #expect(t.engine.volume == Float(4.0 / 60))

        t.timer.cancel()

        #expect(t.engine.volumes == [Float(5.0 / 60), Float(4.0 / 60), 1])
        #expect(t.coordinator.isPlaying)
        #expect(t.engine.volumeAtPause == nil)
    }

    @Test func timerPlayUsesNormalActivationFailureAndRetryEventsWithoutSeeking() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.play(itemID: "A", startTime: 1000)
        h.coordinator.pause()
        h.coordinator.willResume = {
            Issue.record("Timer play must not invoke willResume")
            return 300
        }
        h.engine.failingPlays = 1
        let events = h.events.count
        let control: any SleepTimerPlaybackControl = h.coordinator
        control.play()
        let failure = PlaybackCoordinatorError.engine(
            .audioSessionActivationFailed(description: "Session activation failed"))
        #expect(h.coordinator.error == failure)
        #expect(!h.coordinator.isPlaying)
        #expect(h.events.since(events) == [.failed(failure)])

        control.play()
        control.play()  // Already playing: do not announce or request a duplicate start.
        #expect(h.events.since(events) == [.failed(failure), .playbackStarted])
        #expect(h.engine.playCount == 3)
        #expect(h.coordinator.error == nil)
        #expect(h.coordinator.isPlaying)
        #expect(h.engine.seeks.isEmpty)
        #expect(h.engine.currentTime == 1000)
    }

    @Test func pendingTargetIncludesInterruptedLoadAndSeekUntilLanding() async throws {
        let h = try CoordinatorHarness()
        let control: any SleepTimerPlaybackControl = h.coordinator
        #expect(control.pendingSeekTarget == nil)
        control.play()
        #expect(h.engine.playCount == 0, "Timer play never opens a session or loads media")
        h.engine.interruptedLoads = 1
        await h.coordinator.play(itemID: "A", startTime: 1000)
        #expect(control.pendingSeekTarget == 1000)
        #expect(h.engine.currentTime == 0)
        h.engine.landPendingSeek()
        #expect(control.pendingSeekTarget == nil)

        h.engine.seekResults = [.interrupted]
        #expect(await control.seek(to: 800) == nil)
        #expect(control.pendingSeekTarget == 800)
        #expect(h.engine.currentTime == 1000)
        h.engine.landPendingSeek()
        #expect(control.pendingSeekTarget == nil)
        #expect(h.events.events.suffix(2) == [.didSeek(time: 800), .tick(time: 800)])
        h.coordinator.stop()
        #expect(control.pendingSeekTarget == nil)
        let plays = h.engine.playCount
        control.play()
        #expect(h.engine.playCount == plays)
    }

    @Test func willResumeIsClearedOnlyByItsOwner() throws {
        let h = try CoordinatorHarness()
        let owner = NSObject()
        let other = NSObject()

        h.coordinator.setWillResume({ 1 }, owner: owner)
        h.coordinator.clearWillResume(ownedBy: other)
        #expect(h.coordinator.willResume?() == 1, "Another owner keeps the hook")
        h.coordinator.clearWillResume(ownedBy: owner)
        #expect(h.coordinator.willResume == nil)

        h.coordinator.setWillResume({ 1 }, owner: owner)
        h.coordinator.willResume = { 2 }
        h.coordinator.clearWillResume(ownedBy: owner)
        #expect(h.coordinator.willResume?() == 2, "A direct assignment ends the ownership")

        h.coordinator.setWillResume({ 3 }, owner: other)
        h.coordinator.clearWillResume(ownedBy: owner)
        #expect(h.coordinator.willResume?() == 3, "A later owner takes over")
    }

    @Test func everyPauseIsPublishedWithoutChangingSavedPauseTime() async throws {
        let h = try CoordinatorHarness()
        h.coordinator.pause()
        #expect(h.events.events == [.paused(time: 0)])
        await h.coordinator.play(itemID: "A", startTime: 1000)
        h.coordinator.pause()
        let saved = h.lastPlayed.record
        let events = h.events.count
        h.clock.advance(by: 3600)
        h.coordinator.pause()
        #expect(h.events.since(events) == [.paused(time: 1000)])
        #expect(h.lastPlayed.record == saved)
    }
}
