import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

private typealias TimeOfDay = AutoSleepPolicy.TimeOfDay

private func policy(_ start: String, _ end: String, isEnabled: Bool = true) throws -> AutoSleepPolicy {
    AutoSleepPolicy(
        isEnabled: isEnabled, start: try #require(TimeOfDay(start)), end: try #require(TimeOfDay(end)),
        mode: .duration(900))
}

struct AutoSleepPolicyTests {
    @Test func parsesTwentyFourHourTimes() {
        #expect(TimeOfDay("22:00") == TimeOfDay(hour: 22, minute: 0))
        #expect(TimeOfDay("06:05") == TimeOfDay(hour: 6, minute: 5))
        #expect(TimeOfDay("00:00") == TimeOfDay(hour: 0, minute: 0))
        #expect(TimeOfDay("23:59") == TimeOfDay(hour: 23, minute: 59))
    }

    @Test(arguments: [
        "24:00", "12:60", "6:00", "06:0", "0600", "06:00:00", "ab:cd", "+6:00", "", ":", "12:5", "-0:30", "00:+1",
        "１２:００", "٠٧:٠٠",
    ])
    func rejectsMalformedTimes(_ text: String) {
        #expect(TimeOfDay(text) == nil)
    }

    @Test(arguments: [
        ("13:00", "15:30", ["13:00", "14:00", "15:29"], ["12:59", "15:30", "23:00", "00:00"]),
        ("22:00", "06:00", ["22:00", "23:30", "00:00", "03:00", "05:59"], ["21:59", "06:00", "12:00", "06:01"]),
    ])
    func windowIncludesItsStartButNotItsEnd(start: String, end: String, inside: [String], outside: [String]) throws {
        let policy = try policy(start, end)
        for text in inside + outside {
            let time = try #require(TimeOfDay(text))
            let date = try makeDate(2026, 1, 15, time.hour, time.minute)
            #expect(policy.shouldStart(at: date, calendar: .gregorianUTC) == inside.contains(text), "\(text)")
        }
    }

    @Test func windowOccurrences() throws {
        let day = try policy("13:00", "15:30").window(
            containing: try makeDate(2026, 1, 15, 14, 0), calendar: .gregorianUTC)
        #expect(day == DateInterval(start: try makeDate(2026, 1, 15, 13, 0), end: try makeDate(2026, 1, 15, 15, 30)))
        let policy = try policy("22:00", "06:00")
        let evening = DateInterval(start: try makeDate(2026, 1, 15, 22, 0), end: try makeDate(2026, 1, 16, 6, 0))
        #expect(policy.window(containing: try makeDate(2026, 1, 15, 23, 30), calendar: .gregorianUTC) == evening)
        let morning = DateInterval(start: try makeDate(2026, 1, 14, 22, 0), end: try makeDate(2026, 1, 15, 6, 0))
        #expect(policy.window(containing: try makeDate(2026, 1, 15, 5, 59), calendar: .gregorianUTC) == morning)
        let window = policy.window(containing: try makeDate(2027, 1, 1, 1, 0), calendar: .gregorianUTC)
        #expect(window == DateInterval(start: try makeDate(2026, 12, 31, 22, 0), end: try makeDate(2027, 1, 1, 6, 0)))
    }

    @Test func windowUsesTheCalendarsTimeZone() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let policy = try policy("22:00", "06:00")
        // 02:30 UTC is 21:30 in New York in January.
        let date = try makeDate(2026, 1, 15, 2, 30)
        #expect(policy.shouldStart(at: date, calendar: .gregorianUTC))
        #expect(!policy.shouldStart(at: date, calendar: newYork))

        // Daylight saving time starts at 02:00 on 8 March 2026; the window is an hour shorter.
        let window = policy.window(containing: try makeDate(2026, 3, 8, 1, 0, in: newYork), calendar: newYork)
        let expected = DateInterval(
            start: try makeDate(2026, 3, 7, 22, 0, in: newYork), end: try makeDate(2026, 3, 8, 6, 0, in: newYork))
        #expect(window == expected)
        #expect(expected.duration == 7 * 3600)
    }

    @Test func emptyAndDisabledWindowsNeverStart() throws {
        let empty = try policy("22:00", "22:00")
        #expect(empty.window(containing: try makeDate(2026, 1, 15, 22, 0), calendar: .gregorianUTC) == nil)
        let disabled = try policy("22:00", "06:00", isEnabled: false)
        let date = try makeDate(2026, 1, 15, 23, 0)
        #expect(!disabled.shouldStart(at: date, calendar: .gregorianUTC))
        #expect(disabled.window(containing: date, calendar: .gregorianUTC) != nil)
    }

    @MainActor
    @Test func readsTheSettings() throws {
        let suiteName = "AutoSleepPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultOptions = SleepTimerOptions(settings: AppSettings.snapshot(from: defaults))
        #expect(defaultOptions == SleepTimerOptions())
        #expect(defaultOptions.autoSleep == .disabled)
        #expect(defaultOptions.playsAlmostDoneChime == false)

        let settings = AppSettings(defaults: defaults)
        settings.shakeSensitivity = .high
        #expect(SleepTimerOptions(settings: AppSettings.snapshot(from: defaults)).shakeSensitivity == .high)
        settings.autoSleepTimer = true
        settings.autoSleepTimerStartTime = "21:30"
        settings.autoSleepTimerEndTime = "07:15"
        settings.sleepTimerLength = 0
        settings.autoSleepTimerAutoRewind = true
        settings.autoSleepTimerAutoRewindTime = 120_000
        settings.disableShakeToResetSleepTimer = true
        settings.disableSleepTimerFadeOut = true
        settings.disableSleepTimerResetFeedback = true
        settings.enableSleepTimerAlmostDoneChime = true

        let options = SleepTimerOptions(settings: AppSettings.snapshot(from: defaults))
        let expected = AutoSleepPolicy(
            start: try #require(TimeOfDay(hour: 21, minute: 30)), end: try #require(TimeOfDay(hour: 7, minute: 15)),
            mode: .endOfChapter, rewindOnExpiry: 120)
        let noRewind = AutoSleepPolicy(start: expected.start, end: expected.end, mode: .endOfChapter, rewindOnExpiry: 0)
        #expect(noRewind.rewindOnExpiry == nil, "Only positive rewinds")
        #expect(
            options
                == SleepTimerOptions(
                    fadesOut: false, playsAlmostDoneChime: true, playsResetFeedback: false, shakeSensitivity: nil,
                    autoSleep: expected))
    }
}
