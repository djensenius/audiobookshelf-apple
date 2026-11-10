import ABSCore
import ABSData
import Foundation
import Observation

/// The playback history page for one media item: the events this device recorded, grouped by
/// day. Port of the legacy `pages/media/_id/history.vue`.
///
/// Days and rows are newest first. As in legacy, a run of consecutive saves with the same sync
/// outcome, or of consecutive syncs, within one day shows as its newest event with the number
/// of hidden events (``Row/collapsedCount``).
///
/// Run ``observe()`` (the view's `.task`) to load the events and follow the store's updates.
@MainActor
@Observable
public final class PlaybackHistoryModel {
    /// Starts playback of `mediaKey` at `position` seconds. Supplied by the app, which wires it to
    /// the playback coordinator (#52).
    public typealias PlayFromTime = @MainActor (_ mediaKey: MediaKey, _ position: TimeInterval) async -> Void
    /// The media's events, newest first: the current ones, then one snapshot per change.
    public typealias EventSource =
        @Sendable (MediaKey) async throws -> AsyncStream<[PlaybackHistoryEventDTO]>

    public enum Day: Hashable, Sendable {
        case today
        case yesterday
        case earlier
    }

    public enum SyncStatus: Hashable, Sendable {
        case notAttempted
        case succeeded
        case failed
    }

    public struct DaySection: Identifiable, Hashable, Sendable {
        /// The start of the day in the model's calendar.
        public let id: Date
        public let day: Day
        /// The date, e.g. "Nov 10, 2026"; views show "Today" or "Yesterday" instead for those days.
        public let dateText: String
        public let rows: [Row]
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let name: PlaybackHistoryEventName
        /// The playback position in seconds, if the event recorded one.
        public let position: TimeInterval?
        /// The position as `hh:mm:ss` (legacy `$secondsToTimestampFull`).
        public let positionText: String?
        /// The position rounded to the whole second ``positionText`` shows; speak this one so
        /// VoiceOver and the screen agree (3723.6 is "01:02:04" and 1 h 2 min 4 s).
        public let shownPosition: TimeInterval?
        public let timestamp: Date
        /// The localized time of day the event happened.
        public let timeText: String
        public let sync: SyncStatus
        /// How many older events in a run of saves or syncs this row stands for (legacy "+n").
        public internal(set) var collapsedCount = 0
    }

    /// The book, or the podcast episode (`episodeId` set), whose history this is; build it from
    /// `Route.history(itemID:episodeID:)` and the scene's server connection.
    public let mediaKey: MediaKey
    /// The media's title as recorded with its newest event; `nil` until there is one.
    public private(set) var title: String?
    public private(set) var sections: [DaySection] = []
    /// The first snapshot has arrived, or loading failed.
    public private(set) var isLoaded = false
    /// Why the events couldn't be loaded.
    public private(set) var error: (any Error)?
    /// A ``play(from:)`` call is waiting for playback to start; other taps are ignored meanwhile.
    public private(set) var isStartingPlayback = false
    /// Changes on every ``retry()``; restart ``observe()`` when it does (for example with
    /// `.task(id:)`).
    public private(set) var loadAttempt = 0

    public var isEmpty: Bool { sections.isEmpty }

    @ObservationIgnored private let source: EventSource
    @ObservationIgnored private let playFromTime: PlayFromTime
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The newest snapshot, newest first, kept so ``regroup()`` can redo the days.
    @ObservationIgnored private var events: [PlaybackHistoryEventDTO] = []

    /// - Parameters:
    ///   - calendar: Groups events into days, in the calendar's time zone.
    ///   - locale: Formats dates and times.
    ///   - now: Decides which day is today.
    public init(
        mediaKey: MediaKey,
        source: @escaping EventSource,
        playFromTime: @escaping PlayFromTime,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.mediaKey = mediaKey
        self.source = source
        self.playFromTime = playFromTime
        self.calendar = calendar
        self.locale = locale
        self.now = now
    }

    /// Reads the events from `store` and follows its changes.
    public convenience init(
        mediaKey: MediaKey,
        store: PlaybackHistoryStore,
        playFromTime: @escaping PlayFromTime,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.init(
            mediaKey: mediaKey,
            source: { try await store.updates(for: $0) },
            playFromTime: playFromTime,
            calendar: calendar,
            locale: locale,
            now: now
        )
    }

    /// Loads the events and applies each update until the source ends or the task is cancelled.
    /// After a failure, call ``retry()`` and run this again.
    public func observe() async {
        if error != nil {
            error = nil
            isLoaded = false
        }
        let stream: AsyncStream<[PlaybackHistoryEventDTO]>
        do {
            stream = try await source(mediaKey)
        } catch {
            self.error = error
            isLoaded = true
            return
        }
        for await events in stream {
            apply(events)
        }
    }

    /// Asks for another ``observe()`` after loading failed, by changing ``loadAttempt``.
    public func retry() {
        loadAttempt += 1
    }

    /// Redoes the days against the current time and calendar, so "Today" and "Yesterday" stay
    /// right after midnight or a time zone change. Call it on `.NSCalendarDayChanged`,
    /// `.NSSystemTimeZoneDidChange`, and when the scene becomes active.
    public func regroup() {
        guard isLoaded, error == nil else { return }
        sections = group(events)
    }

    /// Plays the media from the row's position. Ignored for a row without one, or while an
    /// earlier call is starting playback.
    public func play(from row: Row) async {
        guard let position = row.position, !isStartingPlayback else { return }
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        await playFromTime(mediaKey, position)
    }

    func apply(_ events: [PlaybackHistoryEventDTO]) {
        let sorted = events.sorted { $0.timestamp > $1.timestamp }
        self.events = sorted
        title = sorted.first?.mediaDisplayTitle
        sections = group(sorted)
        error = nil
        isLoaded = true
    }

    // MARK: - Grouping

    /// Groups events sorted newest first, collapsing runs like the legacy `groupedMediaEvents`.
    private func group(_ events: [PlaybackHistoryEventDTO]) -> [DaySection] {
        let today = calendar.startOfDay(for: now())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var days: [(start: Date, rows: [Row])] = []
        for event in events {
            let start = calendar.startOfDay(for: event.timestamp)
            if days.last?.start != start {
                days.append((start, []))
            }
            let day = days.endIndex - 1
            if let previous = days[day].rows.indices.last, collapses(event, into: days[day].rows[previous]) {
                days[day].rows[previous].collapsedCount += 1
            } else {
                days[day].rows.append(row(for: event))
            }
        }
        return days.map { start, rows in
            let day: Day = start == today ? .today : start == yesterday ? .yesterday : .earlier
            return DaySection(id: start, day: day, dateText: start.formatted(dateStyle), rows: rows)
        }
    }

    /// Whether `event` is hidden behind `row`, the newer event just before it on the same day.
    private func collapses(_ event: PlaybackHistoryEventDTO, into row: Row) -> Bool {
        switch event.name {
        case .save: row.name == .save && row.sync == syncStatus(event)
        case .sync: row.name == .sync
        default: false
        }
    }

    private func row(for event: PlaybackHistoryEventDTO) -> Row {
        Row(
            id: event.id,
            name: event.name,
            position: event.currentTime,
            positionText: event.currentTime.map(TimeFormatting.fullTimestamp),
            // Rounded like `TimeFormatting.fullTimestamp`.
            shownPosition: event.currentTime.map { $0.isFinite ? max($0, 0).rounded() : 0 },
            timestamp: event.timestamp,
            timeText: event.timestamp.formatted(timeStyle),
            sync: syncStatus(event)
        )
    }

    private func syncStatus(_ event: PlaybackHistoryEventDTO) -> SyncStatus {
        guard event.serverSyncAttempted else { return .notAttempted }
        return event.serverSyncSuccess == true ? .succeeded : .failed
    }

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    private var timeStyle: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    private var timeZone: TimeZone { calendar.timeZone }
}
