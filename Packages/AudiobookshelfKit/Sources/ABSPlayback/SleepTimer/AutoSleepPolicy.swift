import ABSCore
import Foundation

/// When a sleep timer starts by itself, ported from the Android `SleepTimerManager.checkAutoSleepTimer` (the iOS
/// app had no automatic timer).
///
/// Playback that starts inside the daily window from ``start`` to ``end`` (wall-clock time in the calendar's time
/// zone) starts a timer in ``mode``. The start is included and the end is not. A window whose end is before its
/// start wraps past midnight (22:00–06:00 covers 23:30 and 05:59); one whose start equals its end is empty.
public struct AutoSleepPolicy: Sendable, Hashable {
    /// A wall-clock time with minute precision.
    public struct TimeOfDay: Sendable, Hashable, Comparable {
        public let hour: Int
        public let minute: Int

        /// `nil` unless `hour` is 0–23 and `minute` is 0–59.
        public init?(hour: Int, minute: Int) {
            guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
            self.init(validHour: hour, minute: minute)
        }

        /// Parses 24-hour `HH:mm`, the format of the `autoSleepTimerStartTime` and `autoSleepTimerEndTime` settings.
        public init?(_ text: String) {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }),
                let hour = Int(parts[0]), let minute = Int(parts[1])
            else { return nil }
            self.init(hour: hour, minute: minute)
        }

        fileprivate init(validHour hour: Int, minute: Int) {
            self.hour = hour
            self.minute = minute
        }

        public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
            (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
        }
    }

    public var isEnabled: Bool
    public var start: TimeOfDay
    public var end: TimeOfDay
    /// The timer to start.
    public var mode: SleepTimerMode
    /// Seconds to rewind when playback starts again after an automatic timer expired, or `nil` for none.
    public var rewindOnExpiry: TimeInterval?

    /// The policy for the default settings: off, 22:00–06:00, 15 minutes, no rewind.
    public static let disabled = AutoSleepPolicy(
        isEnabled: false, start: TimeOfDay(validHour: 22, minute: 0), end: TimeOfDay(validHour: 6, minute: 0),
        mode: .duration(900))

    public init(
        isEnabled: Bool = true, start: TimeOfDay, end: TimeOfDay, mode: SleepTimerMode,
        rewindOnExpiry: TimeInterval? = nil
    ) {
        self.isEnabled = isEnabled
        self.start = start
        self.end = end
        self.mode = mode
        self.rewindOnExpiry = rewindOnExpiry.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The policy for the settings. Times that don't parse fall back to the defaults (``AppSettings`` already
    /// rejects them).
    public init(settings: AppSettings.Snapshot) {
        let rewind = settings.autoSleepTimerAutoRewind ? Double(settings.autoSleepTimerAutoRewindTime) / 1000 : nil
        self.init(
            isEnabled: settings.autoSleepTimer,
            start: TimeOfDay(settings.autoSleepTimerStartTime) ?? Self.disabled.start,
            end: TimeOfDay(settings.autoSleepTimerEndTime) ?? Self.disabled.end,
            mode: SleepTimerMode(settingsLength: settings.sleepTimerLength),
            rewindOnExpiry: rewind)
    }

    /// Whether playback starting at `date` starts an automatic timer.
    public func shouldStart(at date: Date, calendar: Calendar) -> Bool {
        isEnabled && window(containing: date, calendar: calendar) != nil
    }

    /// The occurrence of the window that contains `date` (`start <= date < end`), or `nil` when `date` is outside
    /// it. Ignores ``isEnabled``. Cancelling an automatic timer suppresses it until this interval's end.
    public func window(containing date: Date, calendar: Calendar) -> DateInterval? {
        guard start != end else { return nil }
        let today = calendar.startOfDay(for: date)
        // A window that wraps past midnight and contains `date` may have started the day before.
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                let window = occurrence(startingOn: day, calendar: calendar)
            else { continue }
            if window.start <= date && date < window.end {
                return window
            }
        }
        return nil
    }

    /// The window that starts on `day`; it ends the next day when it wraps past midnight.
    private func occurrence(startingOn day: Date, calendar: Calendar) -> DateInterval? {
        guard let startDate = calendar.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: day),
            let endDay = end > start ? day : calendar.date(byAdding: .day, value: 1, to: day),
            let endDate = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: endDay),
            endDate > startDate
        else { return nil }
        return DateInterval(start: startDate, end: endDate)
    }
}
