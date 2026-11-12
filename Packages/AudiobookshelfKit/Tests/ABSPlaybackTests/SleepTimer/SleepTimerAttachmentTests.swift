import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// ``AppSettings`` in a `UserDefaults` suite of its own, removed when the test ends.
@MainActor
final class ScratchSettings {
    let name = "SleepTimerAttachmentTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let value: AppSettings

    init() throws {
        defaults = try #require(UserDefaults(suiteName: name))
        value = AppSettings(defaults: defaults)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

@MainActor
private struct AttachmentHarness {
    let h: CoordinatorHarness
    let settings: ScratchSettings
    let clock = ManualClock()
    let feedback = FakeFeedback()
    let shake = FakeShakeDetector()

    var coordinator: PlaybackCoordinator { h.coordinator }

    init() throws {
        h = try CoordinatorHarness()
        settings = try ScratchSettings()
    }

    func attach(hour: Int = 23) throws -> SleepTimerAttachment {
        let date = try makeDate(2026, 1, 15, hour, 0)
        return SleepTimerAttachment(
            coordinator: coordinator, settings: settings.value, feedback: feedback, shakeDetector: shake,
            clock: clock, calendar: .gregorianUTC, now: { date }, tickInterval: .seconds(1))
    }

    /// Plays item A from 1000 and lets a 5-second timer expire. The fade covers the whole run, so the timer seeks
    /// back to 1000.
    func expire(_ timer: SleepTimer) async {
        await coordinator.play(itemID: "A", startTime: 1000)
        #expect(timer.start(.duration(5)))
        for time in 1001...1005 {
            h.engine.currentTime = Double(time)
            await advanceTicking(clock, timer, seconds: 1)
        }
        await until { h.engine.pendingSeekTarget == nil && h.engine.currentTime == 1000 }
        #expect(!coordinator.isPlaying)
        #expect(timer.canRestart)
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SleepTimerAttachmentTests {
    @Test func installsWillResumeAndObserver() async throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach()
        #expect(t.coordinator.willResume != nil)

        await t.expire(attachment.timer)
        t.coordinator.pause()

        #expect(!attachment.timer.canRestart, "A pause from elsewhere ends the grace period")
        attachment.detach()
    }

    @Test func optionsFollowSettingsChanges() async throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach()
        let timer = attachment.timer
        #expect(timer.options == SleepTimerOptions())
        await t.coordinator.play(itemID: "A", startTime: 1000)
        #expect(timer.start(.duration(600)))
        #expect(t.shake.sensitivity == .medium)

        t.settings.value.disableSleepTimerFadeOut = true
        t.settings.value.disableShakeToResetSleepTimer = true
        await until { !timer.options.fadesOut && timer.options.shakeSensitivity == nil }
        #expect(t.shake.sensitivity == nil)

        // Tracking is re-armed after each change.
        t.settings.value.disableShakeToResetSleepTimer = false
        t.settings.value.shakeSensitivity = .high
        await until { timer.options.shakeSensitivity == .high }
        #expect(t.shake.sensitivity == .high)
        t.settings.value.enableSleepTimerAlmostDoneChime = true
        await until { timer.options.playsAlmostDoneChime }

        #expect(timer.options == SleepTimerOptions(settings: AppSettings.snapshot(from: t.settings.defaults)))
        #expect(!timer.options.fadesOut)
        attachment.detach()
    }

    @Test func everySleepTimerSettingUpdatesOptions() async throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach()
        let timer = attachment.timer
        let settings = t.settings.value
        // Each change must alter the options: the sensitivity before shake is disabled, the rewind time after the
        // rewind is enabled.
        let changes: [(name: String, apply: () -> Void)] = [
            ("sleepTimerLength", { settings.sleepTimerLength = 600_000 }),
            ("shakeSensitivity", { settings.shakeSensitivity = .high }),
            ("disableShakeToResetSleepTimer", { settings.disableShakeToResetSleepTimer = true }),
            ("disableSleepTimerFadeOut", { settings.disableSleepTimerFadeOut = true }),
            ("disableSleepTimerResetFeedback", { settings.disableSleepTimerResetFeedback = true }),
            ("enableSleepTimerAlmostDoneChime", { settings.enableSleepTimerAlmostDoneChime = true }),
            ("autoSleepTimer", { settings.autoSleepTimer = true }),
            ("autoSleepTimerStartTime", { settings.autoSleepTimerStartTime = "21:00" }),
            ("autoSleepTimerEndTime", { settings.autoSleepTimerEndTime = "07:00" }),
            ("autoSleepTimerAutoRewind", { settings.autoSleepTimerAutoRewind = true }),
            ("autoSleepTimerAutoRewindTime", { settings.autoSleepTimerAutoRewindTime = 120_000 }),
        ]
        for change in changes {
            let before = timer.options
            change.apply()
            await until { timer.options != before }
            #expect(timer.options != before, "\(change.name) didn't update the options")
            #expect(timer.options == SleepTimerOptions(settings: AppSettings.snapshot(from: t.settings.defaults)))
        }
        attachment.detach()
    }

    @Test(arguments: [(hour: 23, starts: true), (hour: 12, starts: false)])
    func autoSleepStartsInsideWindowFromSettings(hour: Int, starts: Bool) async throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach(hour: hour)
        let timer = attachment.timer
        t.settings.value.autoSleepTimer = true
        t.settings.value.sleepTimerLength = 600_000
        await until { timer.options.autoSleep.isEnabled && timer.options.autoSleep.mode == .duration(600) }

        await t.coordinator.play(itemID: "A", startTime: 1000)

        #expect(timer.isRunning == starts)
        #expect(timer.isAutomatic == starts)
        #expect(timer.mode == (starts ? .duration(600) : nil))
        attachment.detach()
    }

    @Test func itemChangePassesRawKey() async throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach()
        let timer = attachment.timer
        await t.expire(timer)

        timer.itemDidChange(t.h.key("A").rawValue)
        #expect(timer.canRestart, "The timer already holds A's raw key")
        timer.itemDidChange("A")
        #expect(!timer.canRestart)
        attachment.detach()
    }

    /// The timer pauses on `.ended`, before its next tick, so the queue doesn't advance and retarget it to B.
    @Test func endOfChapterTimerOnTheFinalChapterStopsTheQueueAdvance() async throws {
        let a = try AdvanceHarness()
        let settings = try ScratchSettings()
        let clock = ManualClock()
        let attachment = SleepTimerAttachment(
            coordinator: a.coordinator, settings: settings.value, feedback: nil, shakeDetector: nil, clock: clock,
            calendar: .gregorianUTC, tickInterval: .seconds(1))
        let timer = attachment.timer
        a.enqueue("B")
        await a.play("A")
        #expect(await a.coordinator.seek(to: 3000) == 3000)
        #expect(timer.start(.endOfChapter))
        #expect(timer.remaining == 600)

        a.h.engine.finish()
        await a.coordinator.waitForAutoAdvance()

        #expect(a.coordinator.mediaKey == a.key("A"))
        #expect(a.service.starts == ["A"])
        #expect(!a.coordinator.isPlaying)
        #expect(!timer.isRunning)
        #expect(timer.canRestart, "The grace period still applies")
        #expect(a.queue.items.map(\.libraryItemID) == ["B"])
        attachment.detach()
    }

    /// A duration with time left carries on into the next item.
    @Test func durationTimerContinuesIntoTheNextItem() async throws {
        let a = try AdvanceHarness()
        let settings = try ScratchSettings()
        let attachment = SleepTimerAttachment(
            coordinator: a.coordinator, settings: settings.value, feedback: nil, shakeDetector: nil,
            clock: ManualClock(), calendar: .gregorianUTC, tickInterval: .seconds(1))
        let timer = attachment.timer
        a.enqueue("B")
        await a.play("A")
        #expect(timer.start(.duration(600)))

        a.h.engine.finish()
        await a.coordinator.waitForAutoAdvance()

        #expect(a.coordinator.mediaKey == a.key("B"))
        #expect(a.coordinator.isPlaying)
        #expect(timer.mode == .duration(600))
        attachment.detach()
    }

    @Test func detachRestoresHooksAndCancels() async throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach()
        let timer = attachment.timer
        await t.coordinator.play(itemID: "A", startTime: 1000)
        #expect(timer.start(.duration(30)))
        await advanceTicking(t.clock, timer, seconds: 1)
        #expect(t.h.engine.volume < 1)

        attachment.detach()
        attachment.detach()

        #expect(t.coordinator.willResume == nil)
        #expect(!timer.isRunning)
        #expect(t.h.engine.volume == 1)
        await expectEventsIgnored(t, timer)
    }

    @Test func detachDoesNotClearForeignWillResume() throws {
        let t = try AttachmentHarness()
        let attachment = try t.attach()
        t.coordinator.willResume = { 7 }

        attachment.detach()

        #expect(t.coordinator.willResume?() == 7)
    }

    @Test func secondAttachmentReplacesFirst() async throws {
        let t = try AttachmentHarness()
        t.settings.value.autoSleepTimer = true
        let first = try t.attach()
        let second = try t.attach()

        await t.coordinator.play(itemID: "A", startTime: 1000)
        #expect(!first.timer.isRunning)
        #expect(second.timer.isAutomatic)

        first.detach()
        #expect(t.coordinator.willResume != nil)
        #expect(second.timer.isRunning)
        second.detach()
        #expect(t.coordinator.willResume == nil)
    }

    @Test func deinitDetaches() async throws {
        let t = try AttachmentHarness()
        var attachment: SleepTimerAttachment? = try t.attach()
        weak let released = attachment
        let timer = try #require(attachment?.timer)
        await t.coordinator.play(itemID: "A", startTime: 1000)
        #expect(timer.start(.duration(600)))

        attachment = nil

        #expect(released == nil)
        #expect(t.coordinator.willResume == nil)
        #expect(!timer.isRunning)
        await expectEventsIgnored(t, timer)
    }

    /// After detaching, a pause no longer reaches the timer, so it doesn't end the grace period.
    private func expectEventsIgnored(_ t: AttachmentHarness, _ timer: SleepTimer) async {
        t.coordinator.stop()
        await t.expire(timer)
        t.coordinator.pause()
        #expect(timer.canRestart)
        timer.cancel()
    }
}
