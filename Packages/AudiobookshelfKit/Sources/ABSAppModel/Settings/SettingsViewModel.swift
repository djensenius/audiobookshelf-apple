import ABSCore
import Foundation
import Observation

/// State for the Settings screen (port of `pages/settings.vue`).
///
/// Simple settings bind straight to ``settings``; this type adds what the legacy page
/// computed on top: the inverted bookshelf-view toggle, jump-interval options and labels,
/// sleep timer presets with a custom length, and the auto sleep timer window as dates.
/// Every write goes to ``AppSettings``, so changes apply live wherever it is observed.
/// See `docs/settings.md` for where each legacy setting went.
@MainActor
@Observable
public final class SettingsViewModel {
    /// Legacy `jumpForwardSecondsOptions` and `jumpBackwardsSecondsOptions` (`store/globals.js`).
    public nonisolated static let jumpIntervalOptions = [5, 10, 15, 30, 60, 120, 300]
    /// Legacy `SleepTimerLengthModal` and `AutoSleepTimerRewindLengthModal` presets, in minutes.
    public nonisolated static let durationPresetMinutes = [5, 10, 15, 30, 45, 60, 90]
    /// The custom length stepper's range, in minutes. Legacy starts at 1 and has no maximum.
    public nonisolated static let customMinutesRange = 1...1440

    /// The sleep timer length choices: the presets, end of chapter and a custom time.
    public nonisolated static let sleepTimerLengthChoices: [DurationChoice] =
        durationPresetMinutes.map(DurationChoice.minutes) + [.endOfChapter, .custom]

    /// The auto sleep timer's rewind length choices: the presets and a custom time.
    public nonisolated static let autoRewindLengthChoices: [DurationChoice] =
        durationPresetMinutes.map(DurationChoice.minutes) + [.custom]

    public let settings: AppSettings
    @ObservationIgnored private let calendar: Calendar

    /// Whether the length pickers are in "Custom time" mode, showing the stepper. Set when
    /// the stored length isn't a preset, when the user picks Custom and while they edit the
    /// custom minutes, so the stepper stays visible when it lands on a preset; cleared when
    /// they pick a preset (or end of chapter).
    private var isSleepTimerLengthCustom: Bool
    private var isAutoRewindLengthCustom: Bool

    public init(settings: AppSettings, calendar: Calendar = .autoupdatingCurrent) {
        self.settings = settings
        self.calendar = calendar
        isSleepTimerLengthCustom =
            settings.sleepTimerLength != 0 && Self.presetChoice(milliseconds: settings.sleepTimerLength) == .custom
        isAutoRewindLengthCustom = Self.presetChoice(milliseconds: settings.autoSleepTimerAutoRewindTime) == .custom
    }

    // MARK: Display

    /// "Use bookshelf view", the inverse of ``AppSettings/enableAltView`` (legacy
    /// `enableBookshelfView`).
    public var useBookshelfView: Bool {
        get { !settings.enableAltView }
        set { settings.enableAltView = !newValue }
    }

    // MARK: Playback

    /// The jump-forward choices, including the stored value if it isn't a preset.
    public var jumpForwardOptions: [Int] {
        Self.options(Self.jumpIntervalOptions, including: settings.jumpForwardTime)
    }

    /// The jump-backwards choices, including the stored value if it isn't a preset.
    public var jumpBackwardsOptions: [Int] {
        Self.options(Self.jumpIntervalOptions, including: settings.jumpBackwardsTime)
    }

    // MARK: Sleep timer lengths

    /// ``AppSettings/sleepTimerLength`` as a picker choice; `0` is end of chapter, even
    /// after the user picked "Custom time" (another scene may have changed it since).
    public var sleepTimerLengthChoice: DurationChoice {
        get {
            if settings.sleepTimerLength == 0 { return .endOfChapter }
            if isSleepTimerLengthCustom { return .custom }
            return Self.presetChoice(milliseconds: settings.sleepTimerLength)
        }
        set {
            isSleepTimerLengthCustom = newValue == .custom
            switch newValue {
            case .minutes(let minutes):
                settings.sleepTimerLength = Self.milliseconds(minutes: minutes)
            case .endOfChapter:
                settings.sleepTimerLength = 0
            case .custom:
                // End of chapter has no length to adjust; start where the legacy stepper did.
                if settings.sleepTimerLength == 0 {
                    settings.sleepTimerLength = Self.milliseconds(minutes: Self.customMinutesRange.lowerBound)
                }
            }
        }
    }

    /// The sleep timer length in whole minutes, for the custom stepper. Editing it keeps the
    /// picker on Custom, even on a preset.
    public var sleepTimerCustomMinutes: Int {
        get { Self.customMinutes(milliseconds: settings.sleepTimerLength) }
        set {
            isSleepTimerLengthCustom = true
            settings.sleepTimerLength = Self.milliseconds(minutes: Self.clampedCustomMinutes(newValue))
        }
    }

    /// ``AppSettings/autoSleepTimerAutoRewindTime`` as a picker choice.
    public var autoRewindLengthChoice: DurationChoice {
        get {
            if isAutoRewindLengthCustom { return .custom }
            return Self.presetChoice(milliseconds: settings.autoSleepTimerAutoRewindTime)
        }
        set {
            isAutoRewindLengthCustom = newValue == .custom
            switch newValue {
            case .minutes(let minutes):
                settings.autoSleepTimerAutoRewindTime = Self.milliseconds(minutes: minutes)
            case .custom:
                // A stored 0 is below the stepper's range; start where the legacy stepper did.
                if settings.autoSleepTimerAutoRewindTime == 0 {
                    settings.autoSleepTimerAutoRewindTime = Self.milliseconds(
                        minutes: Self.customMinutesRange.lowerBound)
                }
            case .endOfChapter:
                break  // Not offered for the rewind length.
            }
        }
    }

    /// The auto sleep timer's rewind length in whole minutes, for the custom stepper. Editing
    /// it keeps the picker on Custom, even on a preset.
    public var autoRewindCustomMinutes: Int {
        get { Self.customMinutes(milliseconds: settings.autoSleepTimerAutoRewindTime) }
        set {
            isAutoRewindLengthCustom = true
            settings.autoSleepTimerAutoRewindTime = Self.milliseconds(minutes: Self.clampedCustomMinutes(newValue))
        }
    }

    // MARK: Auto sleep timer window

    /// ``AppSettings/autoSleepTimerStartTime`` as a date, for a time picker.
    public var autoSleepTimerStart: Date {
        get { date(forTimeOfDay: settings.autoSleepTimerStartTime) }
        set { settings.autoSleepTimerStartTime = timeOfDay(from: newValue) }
    }

    /// ``AppSettings/autoSleepTimerEndTime`` as a date, for a time picker.
    public var autoSleepTimerEnd: Date {
        get { date(forTimeOfDay: settings.autoSleepTimerEndTime) }
        set { settings.autoSleepTimerEndTime = timeOfDay(from: newValue) }
    }

    /// How many minutes the auto sleep window covers.
    public var autoSleepWindowMinutes: Int {
        Self.windowMinutes(start: settings.autoSleepTimerStartTime, end: settings.autoSleepTimerEndTime)
    }

    /// Whether the start and end times are equal, so the auto sleep timer never starts.
    public var isAutoSleepWindowEmpty: Bool { autoSleepWindowMinutes == 0 }

    /// The minutes from `start` to `end` (24-hour `HH:mm`). An end before the start runs
    /// past midnight, as in legacy `checkAutoSleepTimer`: 22:00–06:00 is 480. `0` when the
    /// times are equal or either is invalid.
    public nonisolated static func windowMinutes(start: String, end: String) -> Int {
        guard let start = AppSettings.minutesSinceMidnight(start), let end = AppSettings.minutesSinceMidnight(end)
        else { return 0 }
        return (end - start + minutesPerDay) % minutesPerDay
    }

    /// `date`'s time of day in this model's calendar, as 24-hour `HH:mm`.
    func timeOfDay(from date: Date) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// A date at `timeOfDay` (`HH:mm`) on a fixed day without a daylight-saving change, so
    /// every time of day exists. Time pickers show only the time.
    func date(forTimeOfDay timeOfDay: String) -> Date {
        let minutes = AppSettings.minutesSinceMidnight(timeOfDay) ?? 0
        let day = calendar.startOfDay(for: Self.referenceDay)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    // MARK: Helpers

    private nonisolated static let minutesPerDay = 24 * 60
    private nonisolated static let millisecondsPerMinute = 60_000
    /// Midday on 2001-01-01 UTC.
    private nonisolated static let referenceDay = Date(timeIntervalSinceReferenceDate: 12 * 3600)

    nonisolated static func options(_ presets: [Int], including value: Int) -> [Int] {
        presets.contains(value) ? presets : (presets + [value]).sorted()
    }

    nonisolated static func presetChoice(milliseconds: Int) -> DurationChoice {
        guard milliseconds % millisecondsPerMinute == 0,
            durationPresetMinutes.contains(milliseconds / millisecondsPerMinute)
        else { return .custom }
        return .minutes(milliseconds / millisecondsPerMinute)
    }

    nonisolated static func customMinutes(milliseconds: Int) -> Int {
        clampedCustomMinutes(Int((Double(milliseconds) / Double(millisecondsPerMinute)).rounded()))
    }

    nonisolated static func clampedCustomMinutes(_ minutes: Int) -> Int {
        min(max(minutes, customMinutesRange.lowerBound), customMinutesRange.upperBound)
    }

    nonisolated static func milliseconds(minutes: Int) -> Int { minutes * millisecondsPerMinute }
}

/// A sleep timer or rewind length choice in the Settings screen.
public enum DurationChoice: Hashable, Sendable {
    /// A preset, in minutes.
    case minutes(Int)
    /// Stop at the end of the current chapter (a stored length of `0`).
    case endOfChapter
    /// A length set with the stepper.
    case custom
}

/// A jump interval's label. Port of legacy `getJumpLabel` (`mixins/jumpLabel.js`), which
/// shows minutes from 120 seconds and keeps 60 seconds in seconds.
public struct JumpIntervalLabel: Hashable, Sendable {
    public enum Unit: Hashable, Sendable {
        case seconds
        case minutes
    }

    public let seconds: Int
    public let unit: Unit

    public init(seconds: Int) {
        self.seconds = seconds
        unit = seconds >= 120 ? .minutes : .seconds
    }

    /// The number shown with the unit, for example `2` for 120 seconds or `2.5` for 150.
    public var value: Double {
        unit == .minutes ? Double(seconds) / 60 : Double(seconds)
    }

    /// ``value`` formatted for `locale`: the argument of the legacy `UnitSecondsShort` or
    /// `UnitMinutesShort` string.
    public func formattedValue(locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }

    /// The spoken form for VoiceOver, for example "10 seconds" or "2 minutes, 30 seconds".
    public func spokenText(locale: Locale = .autoupdatingCurrent) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = unit == .minutes ? [.minutes, .seconds] : [.seconds]
        let style = Duration.UnitsFormatStyle(allowedUnits: units, width: .wide).locale(locale)
        return Duration.seconds(seconds).formatted(style)
    }
}

/// Formats sleep timer and rewind lengths in minutes, like the legacy "15 min".
public enum MinutesFormatting {
    /// For example "15 min", or "15 minutes" when `spoken` (for VoiceOver).
    public static func string(minutes: Int, spoken: Bool = false, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: spoken ? .wide : .abbreviated)
            .locale(locale)
        return Duration.seconds(minutes * 60).formatted(style)
    }
}
