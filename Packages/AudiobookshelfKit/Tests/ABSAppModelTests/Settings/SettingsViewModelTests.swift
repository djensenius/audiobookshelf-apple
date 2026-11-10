import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Runs `body` with settings backed by a fresh, uniquely named `UserDefaults` suite.
@MainActor
private func withSettings(_ body: @MainActor (AppSettings, UserDefaults) throws -> Void) throws {
    let suiteName = "ABSAppModelTests.Settings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(AppSettings(defaults: defaults), defaults)
}

private let english = Locale(identifier: "en_US")

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

@MainActor
@Suite struct SettingsViewModelTests {
    // MARK: Live binding

    @Test func writesGoToAppSettingsAndItsStore() throws {
        try withSettings { settings, defaults in
            let model = SettingsViewModel(settings: settings)

            model.useBookshelfView = true
            #expect(settings.enableAltView == false)
            #expect(defaults.object(forKey: AppSettings.Key.enableAltView.rawValue) as? Bool == false)

            model.sleepTimerLengthChoice = .minutes(30)
            #expect(settings.sleepTimerLength == 1_800_000)
            #expect(defaults.integer(forKey: AppSettings.Key.sleepTimerLength.rawValue) == 1_800_000)

            model.autoRewindLengthChoice = .minutes(10)
            #expect(settings.autoSleepTimerAutoRewindTime == 600_000)
        }
    }

    @Test func readsChangesMadeElsewhere() throws {
        try withSettings { settings, defaults in
            let model = SettingsViewModel(settings: settings, calendar: utcCalendar)

            // Another writer (another scene, a widget, @AppStorage) changes the store.
            defaults.set(false, forKey: AppSettings.Key.enableAltView.rawValue)
            defaults.set(45, forKey: AppSettings.Key.jumpForwardTime.rawValue)
            defaults.set(0, forKey: AppSettings.Key.sleepTimerLength.rawValue)
            defaults.set("23:15", forKey: AppSettings.Key.autoSleepTimerStartTime.rawValue)

            #expect(model.useBookshelfView == true)
            #expect(model.jumpForwardOptions == [5, 10, 15, 30, 45, 60, 120, 300])
            #expect(model.sleepTimerLengthChoice == .endOfChapter)
            #expect(model.autoSleepWindowMinutes == 405)
        }
    }

    // MARK: Jump intervals

    @Test func jumpOptionsMatchLegacy() throws {
        #expect(SettingsViewModel.jumpIntervalOptions == [5, 10, 15, 30, 60, 120, 300])
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings)
            #expect(model.jumpForwardOptions == SettingsViewModel.jumpIntervalOptions)
            #expect(model.jumpBackwardsOptions == SettingsViewModel.jumpIntervalOptions)

            settings.jumpBackwardsTime = 90
            #expect(model.jumpBackwardsOptions == [5, 10, 15, 30, 60, 90, 120, 300])
            #expect(model.jumpForwardOptions == SettingsViewModel.jumpIntervalOptions)
        }
    }

    @Test func jumpLabelsSwitchToMinutesFrom120Seconds() {
        let labels = SettingsViewModel.jumpIntervalOptions.map(JumpIntervalLabel.init(seconds:))
        #expect(labels.map(\.unit) == [.seconds, .seconds, .seconds, .seconds, .seconds, .minutes, .minutes])
        #expect(labels.map { $0.formattedValue(locale: english) } == ["5", "10", "15", "30", "60", "2", "5"])

        let odd = JumpIntervalLabel(seconds: 150)
        #expect(odd.value == 2.5)
        #expect(odd.formattedValue(locale: english) == "2.5")
        #expect(odd.formattedValue(locale: Locale(identifier: "de_DE")) == "2,5")
    }

    @Test func jumpLabelsAreSpokenInFull() {
        #expect(JumpIntervalLabel(seconds: 10).spokenText(locale: english) == "10 seconds")
        #expect(JumpIntervalLabel(seconds: 60).spokenText(locale: english) == "60 seconds")
        #expect(JumpIntervalLabel(seconds: 120).spokenText(locale: english) == "2 minutes")
        #expect(JumpIntervalLabel(seconds: 150).spokenText(locale: english) == "2 minutes, 30 seconds")
    }

    // MARK: Sleep timer lengths

    @Test func sleepTimerChoicesMatchLegacyModal() {
        let presets = [5, 10, 15, 30, 45, 60, 90].map(DurationChoice.minutes)
        #expect(SettingsViewModel.sleepTimerLengthChoices == presets + [.endOfChapter, .custom])
        #expect(SettingsViewModel.autoRewindLengthChoices == presets + [.custom])
    }

    @Test func sleepTimerLengthChoiceReflectsStoredValue() throws {
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings)
            #expect(model.sleepTimerLengthChoice == .minutes(15))
            #expect(model.autoRewindLengthChoice == .minutes(5))

            settings.sleepTimerLength = 0
            #expect(model.sleepTimerLengthChoice == .endOfChapter)
            settings.sleepTimerLength = 7 * 60_000
            #expect(model.sleepTimerLengthChoice == .custom)
            #expect(model.sleepTimerCustomMinutes == 7)
            settings.sleepTimerLength = 90_500
            #expect(model.sleepTimerLengthChoice == .custom)
            #expect(model.sleepTimerCustomMinutes == 2)
        }
    }

    @Test func customLengthStaysCustomOnAPreset() throws {
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings)
            model.sleepTimerLengthChoice = .custom
            #expect(model.sleepTimerLengthChoice == .custom)
            #expect(settings.sleepTimerLength == 900_000)

            model.sleepTimerCustomMinutes = 16
            #expect(settings.sleepTimerLength == 960_000)
            model.sleepTimerCustomMinutes = 15
            #expect(model.sleepTimerLengthChoice == .custom)

            model.sleepTimerLengthChoice = .minutes(60)
            #expect(model.sleepTimerLengthChoice == .minutes(60))
            #expect(settings.sleepTimerLength == 3_600_000)
        }
    }

    @Test func customAfterEndOfChapterStartsAtOneMinute() throws {
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings)
            model.sleepTimerLengthChoice = .endOfChapter
            #expect(settings.sleepTimerLength == 0)
            model.sleepTimerLengthChoice = .custom
            #expect(settings.sleepTimerLength == 60_000)
        }
    }

    @Test func customMinutesAreClamped() throws {
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings)
            model.autoRewindCustomMinutes = 0
            #expect(settings.autoSleepTimerAutoRewindTime == 60_000)
            model.autoRewindCustomMinutes = 5000
            #expect(settings.autoSleepTimerAutoRewindTime == 1440 * 60_000)
            model.sleepTimerCustomMinutes = -3
            #expect(settings.sleepTimerLength == 60_000)
        }
    }

    @Test func minutesFormatting() {
        #expect(MinutesFormatting.string(minutes: 15, locale: english) == "15 min")
        #expect(MinutesFormatting.string(minutes: 90, locale: english) == "90 min")
        #expect(MinutesFormatting.string(minutes: 1, spoken: true, locale: english) == "1 minute")
        #expect(MinutesFormatting.string(minutes: 15, spoken: true, locale: english) == "15 minutes")
    }

    // MARK: Auto sleep timer window

    @Test func timePickerDatesRoundTrip() throws {
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings, calendar: utcCalendar)
            let components = utcCalendar.dateComponents([.hour, .minute], from: model.autoSleepTimerStart)
            #expect(components.hour == 22 && components.minute == 0)

            let picked = try #require(
                utcCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 7, minute: 5)))
            model.autoSleepTimerEnd = picked
            #expect(settings.autoSleepTimerEndTime == "07:05")
            let end = utcCalendar.dateComponents([.hour, .minute], from: model.autoSleepTimerEnd)
            #expect(end.hour == 7 && end.minute == 5)
        }
    }

    @Test func timeOfDayUsesTheModelsTimeZone() throws {
        try withSettings { settings, _ in
            var tokyo = Calendar(identifier: .gregorian)
            tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
            let model = SettingsViewModel(settings: settings, calendar: tokyo)
            // 13:30 UTC is 22:30 in Tokyo.
            model.autoSleepTimerStart = try #require(
                utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 13, minute: 30)))
            #expect(settings.autoSleepTimerStartTime == "22:30")
        }
    }

    @Test func windowWrapsPastMidnight() {
        #expect(SettingsViewModel.windowMinutes(start: "22:00", end: "06:00") == 480)
        #expect(SettingsViewModel.windowMinutes(start: "06:00", end: "22:00") == 960)
        #expect(SettingsViewModel.windowMinutes(start: "00:00", end: "23:59") == 1439)
        #expect(SettingsViewModel.windowMinutes(start: "23:59", end: "00:00") == 1)
    }

    @Test func equalTimesMakeAnEmptyWindow() throws {
        try withSettings { settings, _ in
            let model = SettingsViewModel(settings: settings)
            #expect(model.isAutoSleepWindowEmpty == false)
            settings.autoSleepTimerEndTime = "22:00"
            #expect(model.isAutoSleepWindowEmpty)
            #expect(model.autoSleepWindowMinutes == 0)
        }
    }

    @Test func invalidTimesAreRejected() {
        for value in ["24:00", "12:60", "7:00", "07:5", "+1:00", "07:00:00", "ab:cd", "", "٠٧:٠٠"] {
            #expect(SettingsViewModel.minutesSinceMidnight(value) == nil, "\(value)")
        }
        #expect(SettingsViewModel.minutesSinceMidnight("00:00") == 0)
        #expect(SettingsViewModel.minutesSinceMidnight("23:59") == 1439)
        #expect(SettingsViewModel.windowMinutes(start: "bad", end: "06:00") == 0)
    }
}
