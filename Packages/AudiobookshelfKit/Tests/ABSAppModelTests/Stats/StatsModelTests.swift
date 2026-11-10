import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A ``StatsService`` whose responses come from closures.
private struct FakeStatsService: StatsService {
    var statsHandler: @Sendable () async throws -> ListeningStats = { ListeningStats() }
    var finishedHandler: @Sendable () async throws -> Int = { 0 }

    func listeningStats() async throws -> ListeningStats { try await statsHandler() }
    func finishedItemCount() async throws -> Int { try await finishedHandler() }
}

/// `GET /api/me/listening-stats`, the same JSON as `UserFixtures.listeningStats` in
/// ABSCoreTests. The second recent session has a null `libraryItemId`.
private let listeningStatsFixture = """
    {"totalTime":5400.5,"items":{"li-book-1":{"id":"li-book-1","timeListening":3600,"mediaMetadata":\
    {"title":"The First Book","subtitle":null,"authors":[{"id":"au-1","name":"Author One"}],\
    "narrators":["Narrator One"],"series":[],"genres":["Fantasy"]}},"li-pod-1":{"id":"li-pod-1",\
    "timeListening":1800.5,"mediaMetadata":{"title":"The Show","author":"Host"}}},\
    "days":{"2024-03-01":3600,"2024-03-02":1800.5},"dayOfWeek":{"Friday":3600,"Saturday":1800.5},\
    "today":1800.5,"recentSessions":[{"id":"ps-1","userId":"usr-1","libraryId":"lib-books",\
    "libraryItemId":"li-book-1","bookId":"book-1","episodeId":null,"mediaType":"book","mediaMetadata":\
    {"title":"The First Book","authors":[{"id":"au-1","name":"Author One"}]},"chapters":[],\
    "displayTitle":"The First Book","displayAuthor":"Author One","coverPath":null,"duration":3725.5,\
    "playMethod":0,"mediaPlayer":"html5","deviceInfo":null,"serverVersion":"2.26.0","date":"2024-03-01",\
    "dayOfWeek":"Friday","timeListening":3600,"startTime":0,"currentTime":3600,"startedAt":1709280000000,\
    "updatedAt":1709283600000},{"id":"ps-2","libraryItemId":null,"mediaType":"book","timeListening":1}]}
    """

private func decodeStats(_ json: String) throws -> ListeningStats {
    try JSONDecoder().decode(ListeningStats.self, from: Data(json.utf8))
}

private func calendar(_ identifier: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: identifier))
    return calendar
}

private func date(_ iso: String) throws -> Date {
    try Date(iso, strategy: .iso8601)
}

private let enUS = Locale(identifier: "en_US")

@MainActor
@Suite struct StatsModelTests {
    @Test func loadsTheFixture() async throws {
        let stats = try decodeStats(listeningStatsFixture)
        let service = FakeStatsService(statsHandler: { stats }, finishedHandler: { 3 })
        let now = try date("2024-03-02T15:00:00Z")
        let model = StatsModel(service: service, calendar: try calendar("America/Toronto"), now: { now })
        #expect(!model.hasLoaded)

        await model.load()
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.error == nil)
        #expect(!model.isEmpty)
        #expect(model.totalTime == 5400.5)
        #expect(model.daysListened == 2)
        #expect(model.itemsFinished == 3)
        #expect(model.lastSevenDays.map(\.seconds) == [0, 0, 0, 0, 0, 3600, 1800.5])
        #expect(model.lastSevenDays.map(\.minutes) == [0, 0, 0, 0, 0, 60, 30])

        let session = try #require(model.recentSessions.first)
        #expect(session.id == "ps-1")
        #expect(session.title == "The First Book")
        #expect(session.timeListening == 3600)
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_709_283_600))
        #expect(session.route == .item(id: "li-book-1"))
    }

    /// The decoder drops the fixture's session with a null `libraryItemId`; one with an empty
    /// ID is kept but has no route, so it isn't tappable.
    @Test func sessionsWithoutALibraryItemHaveNoRoute() async throws {
        let fixture = try decodeStats(listeningStatsFixture)
        #expect(fixture.recentSessions.map(\.id) == ["ps-1"])

        let stats = try decodeStats(
            #"{"recentSessions":[{"id":"ps-3","libraryItemId":"","mediaType":"book","timeListening":5,"#
                + #""displayTitle":"Orphan"},{"id":"ps-4","libraryItemId":"li-2","mediaType":"book"}]}"#)
        let model = StatsModel(service: FakeStatsService(statsHandler: { stats }))
        await model.load()
        #expect(model.recentSessions.map(\.id) == ["ps-3", "ps-4"])
        #expect(model.recentSessions.map(\.route) == [nil, .item(id: "li-2")])
        #expect(model.recentSessions.first?.title == "Orphan")
    }

    @Test func emptyStats() async throws {
        let now = try date("2024-03-02T12:00:00Z")
        let model = StatsModel(service: FakeStatsService(), calendar: try calendar("UTC"), now: { now })
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.isEmpty)
        #expect(model.totalTime == 0)
        #expect(model.daysListened == 0)
        #expect(model.itemsFinished == 0)
        #expect(model.recentSessions.isEmpty)
        #expect(model.lastSevenDays.count == 7)
        #expect(model.lastSevenDays.allSatisfy { $0.seconds == 0 && $0.minutes == 0 })
    }

    @Test func daysWithoutListeningDontCount() async throws {
        let stats = ListeningStats(days: ["2024-03-01": 0, "2024-03-02": 60])
        let model = StatsModel(service: FakeStatsService(statsHandler: { stats }))
        await model.load()
        #expect(model.daysListened == 1)
        #expect(!model.isEmpty)
    }

    /// At 03:00 UTC on March 3 it is still March 2 in Toronto but already noon on March 3 in
    /// Tokyo. Each series ends on the device's today and reads the server's keys as is; days
    /// without an entry, including leap day, are 0.
    @Test(arguments: [
        (
            "America/Toronto",
            ["2024-02-25", "2024-02-26", "2024-02-27", "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-02"],
            [0, 0, 0, 0, 0, 3600, 1800.5]
        ),
        (
            "Asia/Tokyo",
            ["2024-02-26", "2024-02-27", "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-02", "2024-03-03"],
            [0, 0, 0, 0, 3600, 1800.5, 600]
        ),
    ])
    func lastSevenDaysAcrossATimeZoneBoundary(timeZone: String, keys: [String], seconds: [Double]) throws {
        let days = ["2024-03-01": 3600, "2024-03-02": 1800.5, "2024-03-03": 600, "2024-02-20": 99]
        let series = StatsModel.lastSevenDays(
            of: days, endingAt: try date("2024-03-03T03:00:00Z"), in: try calendar(timeZone))
        #expect(series.map(\.key) == keys)
        #expect(series.map(\.seconds) == seconds)
    }

    /// Daylight saving time starts in Toronto on March 10, 2024: the series still has one key
    /// per calendar day.
    @Test func lastSevenDaysAcrossDaylightSavingTime() throws {
        let series = StatsModel.lastSevenDays(
            of: ["2024-03-10": 60], endingAt: try date("2024-03-10T23:30:00Z"), in: try calendar("America/Toronto"))
        #expect(
            series.map(\.key) == [
                "2024-03-04", "2024-03-05", "2024-03-06", "2024-03-07", "2024-03-08", "2024-03-09", "2024-03-10",
            ])
        #expect(series.last?.seconds == 60)
    }

    /// Labels show the key's day whatever time zone the format style carries.
    @Test(arguments: ["UTC", "Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Toronto"])
    func labelsUseTheKeyAsIs(timeZone: String) throws {
        let series = StatsModel.lastSevenDays(
            of: [:], endingAt: try date("2024-03-02T12:00:00Z"), in: try calendar("UTC"))
        let day = try #require(series.last)
        #expect(day.key == "2024-03-02")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let anchor = try #require(utc.date(from: DateComponents(year: 2024, month: 3, day: 2)))
        let style = Date.FormatStyle(locale: enUS, timeZone: .gmt).weekday(.wide).month(.wide).day()
        var shifted = style
        shifted.timeZone = try #require(TimeZone(identifier: timeZone))
        #expect(day.formatted(shifted) == anchor.formatted(style))
        #expect(utc.component(.weekday, from: anchor) == 7)  // Saturday
    }

    @Test func failedLoadReportsTheErrorAndRetrySucceeds() async throws {
        let fail = Locked(true)
        let service = FakeStatsService(
            statsHandler: {
                if fail.value { throw TestError.offline }
                return ListeningStats(totalTime: 60)
            })
        let model = StatsModel(service: service)
        await model.load()
        #expect(model.error is TestError)
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)

        fail.value = false
        await model.load()
        #expect(model.error == nil)
        #expect(model.totalTime == 60)
    }

    @Test func failedFinishedCountFailsTheLoad() async {
        let model = StatsModel(service: FakeStatsService(finishedHandler: { throw TestError.offline }))
        await model.load()
        #expect(model.error is TestError)
        #expect(!model.hasLoaded)
    }

    @Test func isLoadingWhileTheRequestRuns() async throws {
        let gate = GatedCalls<Void, ListeningStats>()
        var calls = gate.calls.makeAsyncIterator()
        let model = StatsModel(service: FakeStatsService(statsHandler: { try await gate.call(()) }))

        let load = Task { await model.load() }
        let call = try #require(await calls.next())
        #expect(model.isLoading)
        #expect(!model.hasLoaded)

        call.reply.resume(returning: ListeningStats(totalTime: 120))
        await load.value
        #expect(!model.isLoading)
        #expect(model.totalTime == 120)
    }
}
