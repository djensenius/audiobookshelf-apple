import ABSAPI
import ABSCore
import Foundation
import Observation

/// The stats endpoints ``StatsModel`` uses. `APIClient` conforms; tests use fakes.
public protocol StatsService: Sendable {
    /// `GET /api/me/listening-stats`.
    func listeningStats() async throws -> ListeningStats
    /// The number of finished items in the user's progress (`GET /api/me`), counted like the
    /// legacy stats page, so finished podcast episodes count too.
    func finishedItemCount() async throws -> Int
}

extension APIClient: StatsService {
    public func listeningStats() async throws -> ListeningStats {
        try await send(StatsEndpoints.listeningStats())
    }

    public func finishedItemCount() async throws -> Int {
        try await send(StatsEndpoints.currentUser()).mediaProgress.count(where: \.isFinished)
    }
}

/// One day of the last-7-days chart.
public struct StatsDay: Sendable, Hashable, Identifiable {
    /// The server's `YYYY-MM-DD` key, in the server's time zone.
    public let key: String
    /// Midnight UTC of the day the key names. Format it only through ``formatted(_:)``, which
    /// keeps the key's calendar day in every time zone.
    let date: Date
    /// Seconds listened that day; 0 when the server has no entry.
    public let seconds: Double

    public var id: String { key }

    /// Whole minutes, rounded like the legacy chart.
    public var minutes: Int {
        seconds.isFinite && seconds > 0 ? Int((seconds / 60).rounded()) : 0
    }

    /// The key's day formatted with `style`. The time zone is replaced with UTC, the zone the
    /// day's ``date`` is anchored in, so the label shows the key as is, without converting it
    /// from the server's time zone.
    public func formatted(_ style: Date.FormatStyle) -> String {
        var style = style
        style.timeZone = .gmt
        return date.formatted(style)
    }
}

/// A recent listening session in ``StatsModel``.
public struct StatsSession: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    /// Seconds listened in the session.
    public let timeListening: Double
    /// When the session was last updated.
    public let updatedAt: Date?
    /// The item's screen, or `nil` when the session has no library item, so it isn't tappable.
    public let route: Route?

    init(_ session: PlaybackSession) {
        id = session.id
        title = session.mediaMetadata?.title ?? session.displayTitle
        timeListening = session.timeListening
        updatedAt = session.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        route = session.libraryItemId.isEmpty ? nil : .item(id: session.libraryItemId)
    }
}

/// The listening stats page (`GET /api/me/listening-stats`), a port of the legacy
/// `pages/stats.vue` and `components/stats/DailyListeningChart.vue`.
///
/// A model belongs to one client and account; views recreate it when the account changes.
@MainActor
@Observable
public final class StatsModel {
    /// The last loaded stats; kept while reloading and after a failed reload.
    public private(set) var stats: ListeningStats?
    public private(set) var itemsFinished = 0
    /// The last 7 days ending today, oldest first, computed when the stats load.
    public private(set) var lastSevenDays: [StatsDay] = []
    public private(set) var recentSessions: [StatsSession] = []
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?

    @ObservationIgnored private let service: any StatsService
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var sequence = 0

    /// - Parameters:
    ///   - calendar: decides which day is today. Its time zone is the device's, which may differ
    ///     from the server's; the series still looks days up by the server's keys.
    ///   - now: the current time.
    public init(
        service: any StatsService, calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.calendar = calendar
        self.now = now
    }

    /// Stats have been loaded at least once.
    public var hasLoaded: Bool { stats != nil }

    /// Total listening time in seconds.
    public var totalTime: Double { stats?.totalTime ?? 0 }

    /// The number of days with listening.
    public var daysListened: Int { stats?.days.values.count(where: { $0 > 0 }) ?? 0 }

    /// Loaded, with no listening and no finished items.
    public var isEmpty: Bool {
        hasLoaded && totalTime <= 0 && daysListened == 0 && recentSessions.isEmpty && itemsFinished == 0
    }

    /// Loads the stats and the finished count. When loads overlap, only the last one started
    /// is applied.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<(ListeningStats, Int), any Error>
        do {
            async let stats = service.listeningStats()
            async let finished = service.finishedItemCount()
            result = .success(try await (stats, finished))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let (stats, finished)):
            self.stats = stats
            itemsFinished = finished
            lastSevenDays = Self.lastSevenDays(of: stats.days, endingAt: now(), in: calendar)
            recentSessions = stats.recentSessions.map(StatsSession.init)
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }

    /// The 7 days ending on `date`'s day in `calendar`'s time zone, oldest first, looked up in
    /// `days` by `YYYY-MM-DD` key; days without an entry are 0.
    static func lastSevenDays(of days: [String: Double], endingAt date: Date, in calendar: Calendar) -> [StatsDay] {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let today = local.startOfDay(for: date)
        return (0..<7).reversed().compactMap { offset in
            guard let day = local.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let components = local.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let dayOfMonth = components.day,
                let anchor = utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
            else { return nil }
            let key = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
            return StatsDay(key: key, date: anchor, seconds: days[key] ?? 0)
        }
    }
}
