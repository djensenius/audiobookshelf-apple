import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

private struct Offline: Error {}

/// A ``StatsService`` serving year stats, recording which years and variants were asked for.
private final class FakeYearService: StatsService {
    let type: UserType?
    let calls = Mutex<[String]>([])
    let failsYearStats = Mutex(false)
    /// When set, the user-type check and the user's year stats wait for the test to answer them.
    let typeGate: GatedCalls<Void, UserTypeResponse>?
    let yearGate: GatedCalls<Int, UserYearStats>?

    /// `type` `nil` fails the user-type check.
    init(
        type: UserType?, typeGate: GatedCalls<Void, UserTypeResponse>? = nil,
        yearGate: GatedCalls<Int, UserYearStats>? = nil
    ) {
        self.type = type
        self.typeGate = typeGate
        self.yearGate = yearGate
    }

    func listeningStats() async throws -> ListeningStatsResponse { ListeningStatsResponse(stats: ListeningStats()) }
    func finishedItemCount() async throws -> Int { 0 }

    func userType() async throws -> UserTypeResponse {
        calls.withLock { $0.append("me") }
        if let typeGate { return try await typeGate.call(()) }
        guard let type else { throw Offline() }
        return UserTypeResponse(type: type)
    }

    func userYearStats(year: Int) async throws -> UserYearStats {
        calls.withLock { $0.append("user/\(year)") }
        if let yearGate { return try await yearGate.call(year) }
        if failsYearStats.withLock({ $0 }) { throw Offline() }
        return UserYearStats(
            totalListeningTime: Double(year), numBooksFinished: 2, booksWithCovers: ["li-2", "li-1", ""],
            finishedBooksWithCovers: ["li-1"])
    }

    func serverYearStats(year: Int) async throws -> ServerYearStats {
        calls.withLock { $0.append("server/\(year)") }
        return ServerYearStats(numBooksAdded: 7, booksAddedWithCovers: ["li-9"])
    }
}

private func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

private func date(_ iso: String) throws -> Date {
    try Date(iso, strategy: .iso8601)
}

@MainActor
@Suite struct YearInReviewModelTests {
    private func model(_ service: FakeYearService, now iso: String = "2025-06-15T12:00:00Z") throws
        -> YearInReviewModel
    {
        let now = try date(iso)
        return YearInReviewModel(service: service, calendar: utc(), now: { now })
    }

    // MARK: Year

    /// Legacy opens on the previous year until December.
    @Test func opensOnThePreviousYearUntilDecember() throws {
        let calendar = utc()
        #expect(YearInReviewModel.defaultYear(for: try date("2025-01-01T00:00:00Z"), in: calendar) == 2024)
        #expect(YearInReviewModel.defaultYear(for: try date("2025-11-30T23:59:59Z"), in: calendar) == 2024)
        #expect(YearInReviewModel.defaultYear(for: try date("2025-12-01T00:00:00Z"), in: calendar) == 2025)
        #expect(YearInReviewModel.defaultYear(for: try date("2025-12-31T23:59:59Z"), in: calendar) == 2025)
    }

    /// The stats endpoints take Gregorian years, whatever the device's calendar. The negative
    /// control shows each calendar would give a different year for the same date.
    @Test(arguments: [(Calendar.Identifier.japanese, 7), (.buddhist, 2568)])
    func yearsAreGregorianInAnyCalendar(identifier: Calendar.Identifier, nativeYear: Int) async throws {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = .gmt
        let june = try date("2025-06-15T12:00:00Z")
        #expect(calendar.component(.year, from: june) == nativeYear)

        let service = FakeYearService(type: .user)
        let model = YearInReviewModel(service: service, calendar: calendar, now: { june })
        #expect(model.year == 2024)
        #expect(model.availableYears == [2025, 2024, 2023, 2022, 2021])
        #expect(YearInReviewModel.defaultYear(for: try date("2025-12-15T12:00:00Z"), in: calendar) == 2025)
        await model.load()
        #expect(service.calls.withLock { $0 } == ["me", "user/2024"])
    }

    /// The supplied calendar's time zone still decides the year: in Tokyo, 20:00 UTC on
    /// 31 December is already January.
    @Test func gregorianYearsKeepTheCalendarsTimeZone() throws {
        var calendar = Calendar(identifier: .japanese)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let instant = try date("2025-12-31T20:00:00Z")
        #expect(YearInReviewModel.defaultYear(for: instant, in: calendar) == 2025)
        let model = YearInReviewModel(service: FakeYearService(type: .user), calendar: calendar, now: { instant })
        #expect(model.availableYears.first == 2026)
        // Negative control: in UTC it is still 2025.
        let utcModel = YearInReviewModel(service: FakeYearService(type: .user), calendar: utc(), now: { instant })
        #expect(utcModel.availableYears.first == 2025)
    }

    @Test func pickerOffersTheCurrentAndEarlierYears() throws {
        let model = try model(FakeYearService(type: .user))
        #expect(model.year == 2024)
        #expect(model.availableYears == [2025, 2024, 2023, 2022, 2021])
    }

    @Test func selectingAYearLoadsIt() async throws {
        let service = FakeYearService(type: .user)
        let model = try model(service)
        await model.load()
        guard case .user(let first) = model.content else { Issue.record("no user stats"); return }
        #expect(first.totalListeningTime == 2024)
        await model.select(year: 2025)
        #expect(model.year == 2025)
        guard case .user(let stats) = model.content else { Issue.record("no user stats"); return }
        #expect(stats.totalListeningTime == 2025)
        // Years the picker doesn't offer are ignored.
        await model.select(year: 1999)
        #expect(model.year == 2025)
        #expect(service.calls.withLock { $0 } == ["me", "user/2024", "user/2025"])
    }

    // MARK: Variants

    /// The guard this slice must keep: a non-admin never sees, nor fetches, the server's year.
    @Test func serverVariantIsHiddenForNonAdmins() async throws {
        for type in [UserType.user, .guest, .unknown("superuser")] {
            let service = FakeYearService(type: type)
            let model = try model(service)
            await model.load()
            #expect(!model.isAdminOrUp)
            #expect(model.availableVariants == [.user])
            await model.select(variant: .server)
            #expect(model.variant == .user)
            #expect(service.calls.withLock { $0 } == ["me", "user/2024"])
        }
    }

    @Test func serverVariantIsHiddenWhenTheUserTypeCheckFails() async throws {
        let service = FakeYearService(type: nil)
        let model = try model(service)
        await model.load()
        #expect(model.availableVariants == [.user])
        #expect(model.content != nil)
        await model.select(variant: .server)
        #expect(model.variant == .user)
        // The check runs again on the next load.
        await model.load()
        #expect(service.calls.withLock { $0 } == ["me", "user/2024", "me", "user/2024"])
    }

    @Test func serverVariantIsHiddenBeforeTheFirstLoad() throws {
        let model = try model(FakeYearService(type: .admin))
        #expect(model.availableVariants == [.user])
    }

    @Test func adminsCanSwitchToTheServerVariant() async throws {
        for type in [UserType.admin, .root] {
            let service = FakeYearService(type: type)
            let model = try model(service)
            await model.load()
            #expect(model.isAdminOrUp)
            #expect(model.availableVariants == [.user, .server])
            await model.select(variant: .server)
            #expect(model.variant == .server)
            guard case .server(let stats) = model.content else { Issue.record("no server stats"); return }
            #expect(stats.numBooksAdded == 7)
            await model.select(year: 2023)
            await model.select(variant: .user)
            #expect(
                service.calls.withLock { $0 } == ["me", "user/2024", "server/2024", "server/2023", "user/2023"])
        }
    }

    // MARK: Loading

    @Test func failedLoadKeepsTheErrorUntilALoadSucceeds() async throws {
        let service = FakeYearService(type: .user)
        service.failsYearStats.withLock { $0 = true }
        let model = try model(service)
        await model.loadIfNeeded()
        #expect(model.error != nil)
        #expect(model.content == nil)
        #expect(!model.isLoading)
        service.failsYearStats.withLock { $0 = false }
        await model.loadIfNeeded()
        #expect(model.error == nil)
        #expect(model.content != nil)
        // Already loaded.
        await model.loadIfNeeded()
        #expect(service.calls.withLock { $0 }.count(where: { $0.hasPrefix("user/") }) == 2)
    }

    /// Each successful load bumps the revision, even with unchanged stats, so the view renders
    /// the card again and retries covers that failed. Negative control: a failed load doesn't.
    @Test func successfulLoadsBumpTheRevisionEvenWithUnchangedStats() async throws {
        let service = FakeYearService(type: .user)
        let model = try model(service)
        #expect(model.loadRevision == 0)
        await model.load()
        let first = model.content
        #expect(model.loadRevision == 1)
        await model.load()
        #expect(model.content == first)
        #expect(model.loadRevision == 2)
        service.failsYearStats.withLock { $0 = true }
        await model.load()
        #expect(model.error != nil)
        #expect(model.loadRevision == 2)
    }

    @Test func changingTheYearClearsTheOldStatsWhileLoading() async throws {
        let service = FakeYearService(type: .user)
        let model = try model(service)
        await model.load()
        service.failsYearStats.withLock { $0 = true }
        await model.select(year: 2023)
        #expect(model.content == nil)
        #expect(model.error != nil)
    }

    /// A year's stats arriving after another year was picked are dropped.
    @Test func staleYearStatsAreDropped() async throws {
        let gate = GatedCalls<Int, UserYearStats>()
        var calls = gate.calls.makeAsyncIterator()
        let model = try model(FakeYearService(type: .user, yearGate: gate))

        let first = Task { await model.load() }
        let stale = try #require(await calls.next())
        #expect(stale.request == 2024)
        let second = Task { await model.select(year: 2023) }
        let current = try #require(await calls.next())
        #expect(current.request == 2023)
        current.reply.resume(returning: UserYearStats(totalListeningTime: 2023))
        await second.value
        stale.reply.resume(returning: UserYearStats(totalListeningTime: 2024))
        await first.value

        #expect(model.year == 2023)
        #expect(model.content == .user(UserYearStats(totalListeningTime: 2023)))
        #expect(!model.isLoading)
    }

    /// A load overtaken while checking the user type stops there, and both loads share one check.
    @Test func staleLoadStopsAfterTheUserTypeCheck() async throws {
        let gate = GatedCalls<Void, UserTypeResponse>()
        var calls = gate.calls.makeAsyncIterator()
        let service = FakeYearService(type: .user, typeGate: gate)
        let model = try model(service)

        let first = Task { await model.load() }
        let check = try #require(await calls.next())
        let second = Task { await model.select(year: 2023) }
        // `select(year:)` sets the year and starts its load in one step on the main actor.
        while model.year != 2023 { await Task.yield() }
        check.reply.resume(returning: UserTypeResponse(type: .user))
        await first.value
        await second.value

        #expect(service.calls.withLock { $0 } == ["me", "user/2023"])
        guard case .user(let stats) = model.content else { Issue.record("no user stats"); return }
        #expect(stats.totalListeningTime == 2023)
        #expect(!model.isLoading)
    }

    /// The view's task is cancelled when it disappears mid-load: no error, nothing loaded, and
    /// the next appearance loads again.
    @Test func cancelledLoadIsRetriedOnReappearance() async throws {
        let gate = GatedCalls<Int, UserYearStats>()
        var calls = gate.calls.makeAsyncIterator()
        let model = try model(FakeYearService(type: .user, yearGate: gate))

        let firstAppearance = Task { await model.loadIfNeeded() }
        let first = try #require(await calls.next())
        firstAppearance.cancel()
        first.reply.resume(throwing: CancellationError())
        await firstAppearance.value
        #expect(model.error == nil)
        #expect(model.content == nil)
        #expect(!model.isLoading)

        let secondAppearance = Task { await model.loadIfNeeded() }
        let second = try #require(await calls.next())
        #expect(model.isLoading)
        second.reply.resume(returning: UserYearStats(totalListeningTime: 60))
        await secondAppearance.value
        #expect(model.content == .user(UserYearStats(totalListeningTime: 60)))
        #expect(!model.isLoading)
    }

    // MARK: Covers

    @Test func coverIDsListFinishedBooksFirstWithoutDuplicates() {
        let user = YearInReviewContent.user(
            UserYearStats(
                booksWithCovers: ["li-3", "li-1", "", "li-3"], finishedBooksWithCovers: ["li-1", "li-2", "li-1"]))
        #expect(user.coverItemIDs == ["li-1", "li-2", "li-3"])
        #expect(user.finishedItemIDs == ["li-1", "li-2"])
        let server = YearInReviewContent.server(ServerYearStats(booksAddedWithCovers: ["li-9", "li-9", "li-8"]))
        #expect(server.coverItemIDs == ["li-9", "li-8"])
        #expect(server.finishedItemIDs.isEmpty)
        let many = YearInReviewContent.user(UserYearStats(finishedBooksWithCovers: (1...8).map { "li-\($0)" }))
        #expect(many.finishedItemIDs.count == 5)
    }
}
