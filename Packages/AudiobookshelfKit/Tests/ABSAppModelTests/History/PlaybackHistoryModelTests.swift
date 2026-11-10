import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

private let connectionID = UUID(uuidString: "6F1E2A4B-1C2D-4E5F-8A9B-0C1D2E3F4A5B")!
private let mediaKey = MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1")

private func calendar(_ timeZone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    return calendar
}

private func date(
    _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0
) throws -> Date {
    try #require(
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )
    )
}

private func event(
    _ name: PlaybackHistoryEventName,
    at timestamp: Date,
    position: Double? = 10,
    sync: (attempted: Bool, success: Bool?) = (false, nil),
    title: String = "The Book"
) -> PlaybackHistoryEventDTO {
    PlaybackHistoryEventDTO(
        serverConnectionID: connectionID,
        mediaKey: mediaKey,
        mediaDisplayTitle: title,
        name: name,
        type: name == .sync ? .sync : .playback,
        currentTime: position,
        serverSyncAttempted: sync.attempted,
        serverSyncSuccess: sync.success,
        timestamp: timestamp
    )
}

@MainActor
private func makeModel(
    calendar: Calendar,
    now: Date,
    locale: Locale = Locale(identifier: "en_US"),
    source: @escaping PlaybackHistoryModel.EventSource = { _ in AsyncStream { $0.finish() } },
    play: @escaping PlaybackHistoryModel.PlayFromTime = { _, _ in }
) -> PlaybackHistoryModel {
    PlaybackHistoryModel(
        mediaKey: mediaKey, source: source, playFromTime: play, calendar: calendar, locale: locale, now: { now }
    )
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes; the timeout only bounds a
/// failing test.
@MainActor
private func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return true
}

@MainActor
@Suite struct PlaybackHistoryModelTests {
    // MARK: Grouping and ordering

    @Test func groupsByDayNewestFirst() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let model = makeModel(calendar: utc, now: now)
        let todayLate = event(.pause, at: try date(utc, 2026, 11, 10, 9, 30))
        let todayEarly = event(.play, at: try date(utc, 2026, 11, 10, 0, 0))
        let yesterday = event(.stop, at: try date(utc, 2026, 11, 9, 23, 59, 59))
        let older = event(.seek, at: try date(utc, 2026, 11, 2, 8))
        // Unsorted on purpose: the model doesn't rely on the store's order.
        model.apply([older, todayEarly, yesterday, todayLate])

        #expect(model.sections.map(\.day) == [.today, .yesterday, .earlier])
        #expect(
            model.sections.map(\.id) == [
                try date(utc, 2026, 11, 10, 0), try date(utc, 2026, 11, 9, 0), try date(utc, 2026, 11, 2, 0),
            ])
        #expect(
            model.sections.map { $0.rows.map(\.id) } == [[todayLate.id, todayEarly.id], [yesterday.id], [older.id]])
        #expect(model.isLoaded)
        #expect(model.isEmpty == false)
    }

    @Test func titleComesFromTheNewestEvent() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let model = makeModel(calendar: utc, now: now)
        #expect(model.title == nil)
        model.apply([
            event(.play, at: now.addingTimeInterval(-60), title: "Old title"),
            event(.pause, at: now, title: "New title"),
        ])
        #expect(model.title == "New title")
    }

    @Test func emptyHistory() throws {
        let utc = try calendar("UTC")
        let model = makeModel(calendar: utc, now: try date(utc, 2026, 11, 10, 12))
        model.apply([])
        #expect(model.isLoaded)
        #expect(model.isEmpty)
        #expect(model.title == nil)
    }

    @Test func daysFollowTheCalendarTimeZone() throws {
        let utc = try calendar("UTC")
        let tokyo = try calendar("Asia/Tokyo")
        // 14:30 and 15:30 UTC on Nov 9: the same day in UTC, but 23:30 on Nov 9 and 00:30 on
        // Nov 10 in Tokyo (UTC+9).
        let first = event(.play, at: try date(utc, 2026, 11, 9, 14, 30))
        let second = event(.pause, at: try date(utc, 2026, 11, 9, 15, 30))
        let now = try date(utc, 2026, 11, 10, 3)

        let utcModel = makeModel(calendar: utc, now: now)
        utcModel.apply([first, second])
        #expect(utcModel.sections.map(\.day) == [.yesterday])
        #expect(utcModel.sections.first?.rows.count == 2)

        let tokyoModel = makeModel(calendar: tokyo, now: now)
        tokyoModel.apply([first, second])
        #expect(tokyoModel.sections.map(\.day) == [.today, .yesterday])
        #expect(tokyoModel.sections.map { $0.rows.map(\.id) } == [[second.id], [first.id]])
        #expect(tokyoModel.sections.first?.rows.first?.timeText == "12:30\u{202F}AM")
    }

    @Test func yesterdayIsTheCalendarDayBeforeAcrossSpringForward() throws {
        // DST starts on Mar 8, 2026 in New York, so that day has 23 hours. 24 hours before
        // 00:30 on Mar 9 is still Mar 7, but yesterday is Mar 8.
        let newYork = try calendar("America/New_York")
        let now = try date(newYork, 2026, 3, 9, 0, 30)
        let model = makeModel(calendar: newYork, now: now)
        let lateYesterday = event(.pause, at: try date(newYork, 2026, 3, 8, 23))
        let earlyYesterday = event(.play, at: try date(newYork, 2026, 3, 8, 0, 15))
        let dayBefore = event(.stop, at: try date(newYork, 2026, 3, 7, 23, 45))
        model.apply([lateYesterday, earlyYesterday, dayBefore])

        #expect(model.sections.map(\.day) == [.yesterday, .earlier])
        #expect(model.sections.first?.rows.map(\.id) == [lateYesterday.id, earlyYesterday.id])
        #expect(model.sections.last?.dateText == "Mar 7, 2026")
    }

    @Test func aFallBackDayIsOneGroup() throws {
        // DST ends on Nov 1, 2026 in New York, so that day has 25 hours and 1:30 happens twice.
        let newYork = try calendar("America/New_York")
        let start = try date(newYork, 2026, 11, 1, 0)
        let firstOneThirty = start.addingTimeInterval(90 * 60)
        let secondOneThirty = firstOneThirty.addingTimeInterval(3600)
        let lastMinute = start.addingTimeInterval(25 * 3600 - 60)
        let now = start.addingTimeInterval(25 * 3600 - 1)
        let model = makeModel(calendar: newYork, now: now)
        let events = [lastMinute, secondOneThirty, firstOneThirty, start].map { event(.seek, at: $0) }
        model.apply(events)

        #expect(model.sections.count == 1)
        #expect(model.sections.first?.day == .today)
        #expect(model.sections.first?.rows.map(\.id) == events.map(\.id))
        #expect(
            model.sections.first?.rows.map(\.timeText) == [
                "11:59\u{202F}PM", "1:30\u{202F}AM", "1:30\u{202F}AM", "12:00\u{202F}AM",
            ])
    }

    // MARK: Collapsing (legacy `groupedMediaEvents`)

    @Test func collapsesRunsOfMatchingSavesAndOfSyncs() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let model = makeModel(calendar: utc, now: now)
        let ok = (attempted: true, success: Bool?.some(true))
        let failed = (attempted: true, success: Bool?.some(false))
        // Newest first.
        let events = [
            event(.save, at: now.addingTimeInterval(-1), sync: ok),
            event(.save, at: now.addingTimeInterval(-2), sync: ok),
            event(.save, at: now.addingTimeInterval(-3), sync: ok),
            event(.save, at: now.addingTimeInterval(-4), sync: failed),
            event(.sync, at: now.addingTimeInterval(-5)),
            event(.sync, at: now.addingTimeInterval(-6)),
            event(.pause, at: now.addingTimeInterval(-7)),
            event(.save, at: now.addingTimeInterval(-8), sync: ok),
        ]
        model.apply(events)

        let rows = try #require(model.sections.first?.rows)
        #expect(rows.map(\.id) == [events[0].id, events[3].id, events[4].id, events[6].id, events[7].id])
        #expect(rows.map(\.collapsedCount) == [2, 0, 1, 0, 0])
        #expect(rows.map(\.sync) == [.succeeded, .failed, .notAttempted, .notAttempted, .succeeded])
    }

    @Test func runsDoNotCollapseAcrossDays() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let model = makeModel(calendar: utc, now: now)
        let today = event(.save, at: try date(utc, 2026, 11, 10, 0, 0, 5))
        let yesterday = event(.save, at: try date(utc, 2026, 11, 9, 23, 59, 55))
        model.apply([today, yesterday])
        #expect(model.sections.map { $0.rows.map(\.collapsedCount) } == [[0], [0]])
    }

    // MARK: Formatting

    @Test func formatsRows() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 15, 45)
        let model = makeModel(calendar: utc, now: now, locale: Locale(identifier: "en_GB"))
        model.apply([
            event(.pause, at: now, position: 3723.6),
            event(.stop, at: try date(utc, 2026, 11, 2, 7, 5), position: nil),
        ])

        let pause = try #require(model.sections.first?.rows.first)
        #expect(pause.name == .pause)
        #expect(pause.position == 3723.6)
        #expect(pause.positionText == "01:02:04")
        #expect(pause.timeText == "15:45")
        let stop = try #require(model.sections.last?.rows.first)
        #expect(stop.position == nil)
        #expect(stop.positionText == nil)
        #expect(stop.timeText == "7:05")
        #expect(model.sections.map(\.dateText) == ["10 Nov 2026", "2 Nov 2026"])
    }

    // MARK: Live updates

    @Test func followsTheSource() async throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let (stream, continuation) = AsyncStream.makeStream(of: [PlaybackHistoryEventDTO].self)
        let model = makeModel(calendar: utc, now: now, source: { _ in stream })
        let task = Task { await model.observe() }
        defer { task.cancel() }

        let play = event(.play, at: now.addingTimeInterval(-10))
        continuation.yield([play])
        #expect(await eventually { model.sections.first?.rows.count == 1 })

        let pause = event(.pause, at: now)
        continuation.yield([pause, play])
        #expect(await eventually { model.sections.first?.rows.map(\.id) == [pause.id, play.id] })

        continuation.yield([])
        #expect(await eventually { model.isEmpty })
        continuation.finish()
        await task.value
    }

    @Test func updatesWhenTheStoreRecords() async throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let store = PlaybackHistoryStore(modelContainer: try DataStack(location: .inMemory).container)
        let model = PlaybackHistoryModel(
            mediaKey: mediaKey, store: store, playFromTime: { _, _ in }, calendar: utc, now: { now }
        )
        let task = Task { await model.observe() }
        defer { task.cancel() }
        #expect(await eventually { model.isLoaded })
        #expect(model.isEmpty)

        let recorder = PlaybackHistoryRecorder(store: store) { now }
        await recorder.record(.play, for: PlaybackHistoryMedia(key: mediaKey, displayTitle: "The Book"), at: 42)
        #expect(await eventually { model.sections.first?.rows.first?.position == 42 })
        #expect(model.title == "The Book")

        try await store.deleteEvents(for: mediaKey)
        #expect(await eventually { model.isEmpty })
    }

    @Test func reportsASourceFailure() async throws {
        struct Failure: Error {}
        let utc = try calendar("UTC")
        let model = makeModel(calendar: utc, now: try date(utc, 2026, 11, 10, 12), source: { _ in throw Failure() })
        await model.observe()
        #expect(model.error is Failure)
        #expect(model.isLoaded)
    }

    // MARK: Play from time

    @Test func playsFromTheRowPosition() async throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        var calls: [(MediaKey, TimeInterval)] = []
        let model = makeModel(calendar: utc, now: now, play: { calls.append(($0, $1)) })
        model.apply([event(.seek, at: now, position: 125), event(.stop, at: now.addingTimeInterval(-1), position: nil)])
        let rows = try #require(model.sections.first?.rows)

        await model.play(from: rows[0])
        await model.play(from: rows[1])
        #expect(calls.map(\.0) == [mediaKey])
        #expect(calls.map(\.1) == [125])
        #expect(model.isStartingPlayback == false)
    }

    @Test func ignoresTapsWhilePlaybackStarts() async throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2026, 11, 10, 12)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        var positions: [TimeInterval] = []
        let model = makeModel(
            calendar: utc, now: now,
            play: { _, position in
                positions.append(position)
                startedContinuation.yield()
                for await _ in release { break }
            })
        model.apply([event(.seek, at: now, position: 5), event(.seek, at: now.addingTimeInterval(-1), position: 9)])
        let rows = try #require(model.sections.first?.rows)

        let first = Task { await model.play(from: rows[0]) }
        for await _ in started { break }
        #expect(model.isStartingPlayback)
        await model.play(from: rows[1])
        releaseContinuation.yield()
        await first.value

        #expect(positions == [5])
        #expect(model.isStartingPlayback == false)
    }
}
