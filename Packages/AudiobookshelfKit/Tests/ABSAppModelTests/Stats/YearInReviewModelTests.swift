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

    /// `type` `nil` fails the user-type check.
    init(type: UserType?) {
        self.type = type
    }

    func listeningStats() async throws -> ListeningStatsResponse { ListeningStatsResponse(stats: ListeningStats()) }
    func finishedItemCount() async throws -> Int { 0 }

    func userType() async throws -> UserTypeResponse {
        calls.withLock { $0.append("me") }
        guard let type else { throw Offline() }
        return UserTypeResponse(type: type)
    }

    func userYearStats(year: Int) async throws -> UserYearStats {
        calls.withLock { $0.append("user/\(year)") }
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

    @Test func changingTheYearClearsTheOldStatsWhileLoading() async throws {
        let service = FakeYearService(type: .user)
        let model = try model(service)
        await model.load()
        service.failsYearStats.withLock { $0 = true }
        await model.select(year: 2023)
        #expect(model.content == nil)
        #expect(model.error != nil)
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
