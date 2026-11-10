import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A ``StatsService`` whose responses come from closures.
private struct FakeStatsService: StatsService {
    var statsHandler: @Sendable () async throws -> ListeningStatsResponse = { response() }
    var finishedHandler: @Sendable () async throws -> Int = { 0 }

    func listeningStats() async throws -> ListeningStatsResponse { try await statsHandler() }
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

private func response(_ stats: ListeningStats = ListeningStats()) -> ListeningStatsResponse {
    ListeningStatsResponse(stats: stats)
}

private func decodeStats(_ json: String) throws -> ListeningStatsResponse {
    try JSONDecoder().decode(ListeningStatsResponse.self, from: Data(json.utf8))
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

    /// The fixture's session with a null `libraryItemId` is kept, without a route, so it shows
    /// but isn't tappable.
    @Test func sessionWithNullLibraryItemIsKeptWithoutARoute() async throws {
        let fixture = try decodeStats(listeningStatsFixture)
        let model = StatsModel(service: FakeStatsService(statsHandler: { fixture }))
        await model.load()
        #expect(model.recentSessions.map(\.id) == ["ps-1", "ps-2"])
        #expect(model.recentSessions.map(\.route) == [.item(id: "li-book-1"), nil])
        let orphan = try #require(model.recentSessions.last)
        #expect(orphan.timeListening == 1)
        #expect(orphan.title == nil)
    }

    /// A session with an empty item ID has no route either.
    @Test func sessionsWithoutALibraryItemHaveNoRoute() async throws {
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
        let stats = response(ListeningStats(days: ["2024-03-01": 0, "2024-03-02": 60]))
        let model = StatsModel(service: FakeStatsService(statsHandler: { stats }))
        await model.load()
        #expect(model.daysListened == 1)
        #expect(!model.isEmpty)
    }

    private func day(seconds: Double) throws -> StatsDay {
        StatsDay(key: "2024-03-02", date: try date("2024-03-02T00:00:00Z"), seconds: seconds)
    }

    /// Whole minutes round half up, like the legacy chart.
    @Test(arguments: [(0, 0), (29.9, 0), (30, 1), (3_600, 60), (3_630, 61), (5_400.5, 90)] as [(Double, Int)])
    func dayMinutesRoundToTheNearestMinute(seconds: Double, expected: Int) throws {
        #expect(try day(seconds: seconds).minutes == expected)
    }

    /// Negative and non-finite times are no listening.
    @Test(arguments: [-5, -1e30, -.greatestFiniteMagnitude, -.infinity, .infinity, .nan] as [Double])
    func dayMinutesOfNegativeAndNonFiniteTimesAreZero(seconds: Double) throws {
        #expect(try day(seconds: seconds).minutes == 0)
    }

    /// Finite values `Int` can't hold are clamped to the duration formatter's bound before they
    /// are converted: 1e30 used to trap.
    @Test(
        arguments: [
            1e30, .greatestFiniteMagnitude, TimeFormatting.maxSeconds, TimeFormatting.maxSeconds.nextUp,
            TimeFormatting.maxSeconds.nextDown,
        ] as [Double])
    func dayMinutesPastTheBoundAreClamped(seconds: Double) throws {
        #expect(try day(seconds: seconds).minutes == TimeFormatting.maxMinutes)
    }

    @Test func dayMinutesJustUnderTheBoundAreNotClamped() throws {
        #expect(try day(seconds: TimeFormatting.maxSeconds - 60).minutes == TimeFormatting.maxMinutes - 1)
    }

    /// A server can send finite numbers far past `Int`'s range, and JSON `1e30` decodes as one.
    /// Loading them keeps the raw seconds and gives every day whole minutes within the bound.
    @Test func hugeServerTimesLoadWithClampedMinutes() async throws {
        let stats = try decodeStats(
            #"{"totalTime":1e30,"days":{"2024-03-02":1e30,"2024-03-01":1.7976931348623157e308,"#
                + #""2024-02-29":3630,"2024-02-28":-1e30}}"#)
        #expect(stats.stats.totalTime == 1e30)
        let now = try date("2024-03-02T12:00:00Z")
        let model = StatsModel(
            service: FakeStatsService(statsHandler: { stats }), calendar: try calendar("UTC"), now: { now })
        await model.load()
        #expect(model.totalTime == 1e30)
        #expect(model.daysListened == 3)
        #expect(!model.isEmpty)
        let bound = TimeFormatting.maxMinutes
        #expect(model.lastSevenDays.map(\.minutes) == [0, 0, 0, 0, 61, bound, bound])
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
                return response(ListeningStats(totalTime: 60))
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

    /// A failed pull-to-refresh keeps the shown stats and reports the failure with a retry.
    @Test func failedRefreshKeepsTheStatsAndRetrySucceeds() async throws {
        let fail = Locked(false)
        let total = Locked(60.0)
        let service = FakeStatsService(
            statsHandler: {
                if fail.value { throw TestError.offline }
                return response(ListeningStats(totalTime: total.value))
            })
        let model = StatsModel(service: service)
        await model.load()
        #expect(model.hasLoaded)
        #expect(!model.refreshFailed)

        fail.value = true
        await model.load()
        #expect(model.error is TestError)
        #expect(model.hasLoaded)
        #expect(model.totalTime == 60)
        #expect(model.refreshFailed)

        fail.value = false
        total.value = 120
        await model.load()
        #expect(model.error == nil)
        #expect(!model.refreshFailed)
        #expect(model.totalTime == 120)
    }

    @Test func refreshFailedIsClearedWhileRetrying() async throws {
        let gate = GatedCalls<Void, ListeningStatsResponse>()
        var calls = gate.calls.makeAsyncIterator()
        let attempts = Locked(0)
        let service = FakeStatsService(
            statsHandler: {
                attempts.value += 1
                switch attempts.value {
                case 1: return response(ListeningStats(totalTime: 60))
                case 2: throw TestError.offline
                default: return try await gate.call(())
                }
            })
        let model = StatsModel(service: service)
        await model.load()
        await model.load()
        #expect(model.refreshFailed)

        let retry = Task { await model.load() }
        let call = try #require(await calls.next())
        #expect(model.isLoading)
        #expect(!model.refreshFailed)
        call.reply.resume(returning: response(ListeningStats(totalTime: 90)))
        await retry.value
        #expect(!model.refreshFailed)
        #expect(model.totalTime == 90)
    }

    @Test func failedFinishedCountFailsTheLoad() async {
        let model = StatsModel(service: FakeStatsService(finishedHandler: { throw TestError.offline }))
        await model.load()
        #expect(model.error is TestError)
        #expect(!model.hasLoaded)
    }

    @Test func isLoadingWhileTheRequestRuns() async throws {
        let gate = GatedCalls<Void, ListeningStatsResponse>()
        var calls = gate.calls.makeAsyncIterator()
        let model = StatsModel(service: FakeStatsService(statsHandler: { try await gate.call(()) }))

        let load = Task { await model.load() }
        let call = try #require(await calls.next())
        #expect(model.isLoading)
        #expect(!model.hasLoaded)

        call.reply.resume(returning: response(ListeningStats(totalTime: 120)))
        await load.value
        #expect(!model.isLoading)
        #expect(model.totalTime == 120)
    }

    /// The view's task is cancelled when it disappears mid-load. The model stays unloaded with no
    /// error, and the next appearance loads again.
    @Test func cancelledFirstLoadIsRetriedOnReappearance() async throws {
        let gate = GatedCalls<Void, ListeningStatsResponse>()
        var calls = gate.calls.makeAsyncIterator()
        let model = StatsModel(service: FakeStatsService(statsHandler: { try await gate.call(()) }))

        let firstAppearance = Task { await model.loadIfNeeded() }
        let first = try #require(await calls.next())
        firstAppearance.cancel()
        first.reply.resume(throwing: CancellationError())
        await firstAppearance.value
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.error == nil)

        let secondAppearance = Task { await model.loadIfNeeded() }
        let second = try #require(await calls.next())
        #expect(model.isLoading)
        second.reply.resume(returning: response(ListeningStats(totalTime: 60)))
        await secondAppearance.value
        #expect(model.hasLoaded)
        #expect(model.totalTime == 60)
    }

    @Test func loadIfNeededSkipsALoadedModel() async {
        let count = Locked(0)
        let model = StatsModel(
            service: FakeStatsService(statsHandler: {
                count.value += 1
                return response()
            }))
        await model.loadIfNeeded()
        await model.loadIfNeeded()
        #expect(count.value == 1)
        #expect(model.hasLoaded)

        // An explicit reload (pull to refresh) still reloads.
        await model.load()
        #expect(count.value == 2)
    }

    @Test func failedFirstLoadIsRetriedOnReappearance() async {
        let fail = Locked(true)
        let model = StatsModel(
            service: FakeStatsService(statsHandler: {
                if fail.value { throw TestError.offline }
                return response()
            }))
        await model.loadIfNeeded()
        #expect(model.error is TestError)
        fail.value = false
        await model.loadIfNeeded()
        #expect(model.hasLoaded)
        #expect(model.error == nil)
    }
}
