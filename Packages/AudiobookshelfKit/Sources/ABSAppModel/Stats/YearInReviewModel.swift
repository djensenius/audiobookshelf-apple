import ABSAPI
import ABSCore
import Foundation
import Observation

/// Whose year a ``YearInReviewModel`` shows.
public enum YearInReviewVariant: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// The signed-in user's listening (`GET /api/me/stats/year/:year`).
    case user
    /// The whole server's additions and listening (`GET /api/stats/year/:year`), admins only.
    case server

    public var id: Self { self }
}

/// The loaded stats of one year and variant.
public enum YearInReviewContent: Sendable, Hashable {
    case user(UserYearStats)
    case server(ServerYearStats)

    /// The library item IDs whose covers the card shows, in the legacy order: for the user,
    /// finished books first, then the other books listened to; for the server, the books added.
    /// Duplicates are dropped.
    public var coverItemIDs: [String] {
        let ids: [String]
        switch self {
        case .user(let stats): ids = stats.finishedBooksWithCovers + stats.booksWithCovers
        case .server(let stats): ids = stats.booksAddedWithCovers
        }
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The covers of the books finished in the year, at most five, as the legacy card shows
    /// them; empty for the server.
    public var finishedItemIDs: [String] {
        guard case .user(let stats) = self else { return [] }
        var seen = Set<String>()
        return Array(stats.finishedBooksWithCovers.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(5))
    }
}

/// The year in review (`components/stats/YearInReviewBanner.vue`, `YearInReview.vue` and
/// `YearInReviewServer.vue`): the stats of one year for the user, or for the whole server when
/// the user is an admin.
///
/// The server variant is offered only once `GET /api/me` says the user is admin or root; until
/// then, and when that check fails, only the user's year is shown.
///
/// A model belongs to one client and account; views recreate it when the account changes.
@MainActor
@Observable
public final class YearInReviewModel {
    /// How many years the picker offers, the current year included.
    public static let pickerYearCount = 5

    /// The year shown.
    public private(set) var year: Int
    /// The years the picker offers, newest first.
    public let availableYears: [Int]
    /// Whose year is shown; always ``YearInReviewVariant/user`` for non-admins.
    public private(set) var variant: YearInReviewVariant = .user
    /// The stats of ``year`` and ``variant``; `nil` until they load, and cleared when either
    /// changes so another year's stats are never shown under this one.
    public private(set) var content: YearInReviewContent?
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?
    /// Whether the user is admin or root, from `GET /api/me`; `false` until known.
    public private(set) var isAdminOrUp = false

    @ObservationIgnored private let service: any StatsService
    @ObservationIgnored private var hasCheckedUserType = false
    /// The user-type check in flight, or the one that succeeded.
    @ObservationIgnored private var userTypeCheck: Task<UserTypeResponse, any Error>?
    @ObservationIgnored private var sequence = 0

    /// - Parameters:
    ///   - calendar: supplies the time zone that decides the current year and month. The years
    ///     themselves are always Gregorian, as the stats endpoints expect, whatever the
    ///     calendar's identifier (Japanese, Buddhist, …).
    ///   - now: the current time.
    public init(
        service: any StatsService, calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        let date = now()
        let current = Self.gregorian(in: calendar).component(.year, from: date)
        year = Self.defaultYear(for: date, in: calendar)
        availableYears = (0..<Self.pickerYearCount).map { current - $0 }
    }

    /// The variants the user may pick: the server's only for admins.
    public var availableVariants: [YearInReviewVariant] {
        isAdminOrUp ? [.user, .server] : [.user]
    }

    /// The year legacy opens on: the previous year, except in December, when the current year
    /// is nearly done. Gregorian, in `calendar`'s time zone.
    nonisolated static func defaultYear(for date: Date, in calendar: Calendar) -> Int {
        let components = gregorian(in: calendar).dateComponents([.year, .month], from: date)
        let year = components.year ?? 2000
        return components.month == 12 ? year : year - 1
    }

    /// A Gregorian calendar in `calendar`'s time zone: the stats endpoints take Gregorian years.
    nonisolated static func gregorian(in calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// Loads unless stats for the current selection have loaded. Views call it each time they
    /// appear, so a load cancelled before it finished runs again.
    public func loadIfNeeded() async {
        guard content == nil else { return }
        await load()
    }

    /// Shows `year`, loading its stats. Years the picker doesn't offer are ignored.
    public func select(year: Int) async {
        guard year != self.year, availableYears.contains(year) else { return }
        self.year = year
        content = nil
        await load()
    }

    /// Shows `variant`, loading its stats. The server variant is ignored for non-admins.
    public func select(variant: YearInReviewVariant) async {
        guard variant != self.variant, availableVariants.contains(variant) else { return }
        self.variant = variant
        content = nil
        await load()
    }

    /// Loads the selected year and variant, checking the user's type first on the first load.
    /// When loads overlap, only the last one started is applied.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        if !hasCheckedUserType {
            // Overlapping loads share one `GET /api/me`.
            let check = userTypeCheck ?? Task { [service] in try await service.userType() }
            userTypeCheck = check
            if let type = try? await check.value {
                hasCheckedUserType = true
                isAdminOrUp = type.isAdminOrUp
            } else if userTypeCheck == check {
                // A failed check leaves the user's year only; the next load asks again.
                userTypeCheck = nil
            }
            guard sequence == self.sequence else { return }
        }
        // Never ask for the server's year unless the user may see it.
        if variant == .server, !isAdminOrUp { variant = .user }
        let year = year
        let variant = variant
        let result: Result<YearInReviewContent, any Error>
        do {
            switch variant {
            case .user: result = .success(.user(try await service.userYearStats(year: year)))
            case .server: result = .success(.server(try await service.serverYearStats(year: year)))
            }
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let loaded):
            content = loaded
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }
}
