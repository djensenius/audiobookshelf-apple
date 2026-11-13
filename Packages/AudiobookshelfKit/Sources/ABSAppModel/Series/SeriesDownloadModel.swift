import ABSAPI
import ABSCore
import ABSDownloads
import Foundation
import Observation

/// Queues downloads the user starts; ``DownloadsController`` conforms. Tests use fakes.
@MainActor
public protocol DownloadRequesting: Sendable {
    /// See ``DownloadsController/request(item:episodeID:connectionID:)``.
    func request(item: LibraryItem, episodeID: String?, connectionID: UUID) async -> DownloadRequestOutcome
    /// See ``DownloadsController/confirmMeteredDownload(item:episodeID:ticket:)``.
    func confirmMeteredDownload(item: LibraryItem, episodeID: String?, ticket: DownloadRequestTicket) async
        -> DownloadRequestOutcome
    /// See ``DownloadsController/canRequest(connectionID:)``.
    func canRequest(connectionID: UUID) -> Bool
}

/// What a screen needs to queue downloads for the signed-in account: the download queue and the
/// stored download status. Where downloads aren't supported (no download stack), there is none.
public struct DownloadAccess: Sendable {
    public let requester: any DownloadRequesting
    public let status: any DownloadStatusReading

    public init(requester: any DownloadRequesting, status: any DownloadStatusReading) {
        self.requester = requester
        self.status = status
    }
}

/// Whether the series screen offers Download Series: only with a download stack and a signed-in
/// account whose user may download (`permissions.download`, legacy `userCanDownload`).
public enum SeriesDownloadAvailability: Sendable, Hashable {
    case available(connectionID: UUID)
    /// No account is signed in, so there is no connection to download from.
    case signedOut
    /// The app has no download stack (for example, its store couldn't open).
    case unsupported
    /// The signed-in user may not download.
    case notPermitted

    public init(connectionID: UUID?, hasDownloads: Bool, canDownload: Bool) {
        if !hasDownloads {
            self = .unsupported
        } else if let connectionID {
            self = canDownload ? .available(connectionID: connectionID) : .notPermitted
        } else {
            self = .signedOut
        }
    }

    /// The connection to download from, or `nil` when the action is hidden.
    public var connectionID: UUID? {
        if case .available(let connectionID) = self { connectionID } else { nil }
    }
}

/// The books a Download Series would queue, with their file count and size as the server lists
/// them, for the legacy confirmation (`MessageSeriesDownloadConfirmIos`).
public struct SeriesDownloadPlan: Sendable, Hashable {
    /// In the server's order.
    public let itemIDs: [String]
    public let fileCount: Int
    public let size: Int64

    public init(itemIDs: [String], fileCount: Int, size: Int64) {
        self.itemIDs = itemIDs
        self.fileCount = fileCount
        self.size = size
    }

    /// The series' books that are neither downloaded nor have a download record (`skipping`). The
    /// server's counts and sizes are clamped at 0 and summed saturating, as `DownloadManager` does.
    public init(books: [LibraryItem], skipping: Set<String>) {
        var seen = skipping
        let missing = books.filter { seen.insert($0.id).inserted }
        func adding<T: FixedWidthInteger>(_ total: T, _ value: T?) -> T {
            let (sum, overflow) = total.addingReportingOverflow(max(value ?? 0, 0))
            return overflow ? .max : sum
        }
        self.init(
            itemIDs: missing.map(\.id), fileCount: missing.reduce(0) { adding($0, $1.numFiles) },
            size: missing.reduce(0) { adding($0, $1.size.map(Int64.init)) })
    }
}

/// Download Series on the series screen; a port of `downloadSeriesClick` in the legacy
/// `pages/bookshelf/series/_id.vue`.
///
/// - ``start(libraryID:)`` fetches every book of the series from the library items endpoint with
///   the `series.<id>` filter, page by page and without collapsing sub-series, as legacy does,
///   and skips the books already downloaded or with a download record (queued, downloading,
///   paused or failed; the user resumes those from Downloads). With nothing left it prompts
///   ``Prompt/alreadyDownloaded``, else ``Prompt/confirm(_:)`` with the plan.
/// - ``confirm()`` fetches each planned book expanded and queues it through ``DownloadRequesting``,
///   which applies the download cellular policy. Asked on a metered path, it stops and prompts
///   ``Prompt/meteredConfirmation`` once; ``confirmMetered()`` queues the rest. Denied, it stops
///   with ``Prompt/meteredDenied``. Books that couldn't be fetched or queued are counted in
///   ``Prompt/queueFailed(count:)``.
/// - A `CancellationError` (the account signed out or switched), or cancelling the task that runs a
///   step, ends it without a prompt. Without the user's download permission
///   (``DownloadRequesting/canRequest(connectionID:)``), nothing is listed or queued, and losing it
///   or the session while queueing (``DownloadRequestOutcome/rejected(_:)``) drops the rest of the
///   plan.
/// - Listing stops at a page that adds no new book, and fails past ``maxBooks``, or at a page with
///   rows that didn't decode, rather than offering part of the series.
///
/// A model belongs to one series and connection: views recreate it when either changes.
@MainActor
@Observable
public final class SeriesDownloadModel {
    /// What the view asks or tells the user.
    public enum Prompt: Sendable, Hashable {
        /// Every book is downloaded or queued already (`MessageSeriesAlreadyDownloaded`).
        case alreadyDownloaded
        /// Download the plan's books?
        case confirm(SeriesDownloadPlan)
        /// Download using cellular data? (`MessageConfirmDownloadUsingCellular`)
        case meteredConfirmation
        /// The download cellular policy doesn't allow it (`ToastDownloadNotAllowedOnCellular`).
        case meteredDenied
        /// The series' books couldn't be listed, or there were more than ``maxBooks``.
        case loadFailed
        /// This many books couldn't be queued.
        case queueFailed(count: Int)
    }

    public let seriesID: String
    public let connectionID: UUID
    /// Listing or queueing is under way; the view disables the action.
    public private(set) var isWorking = false
    /// Set the view's alert from it; the view clears it when the alert closes.
    public var prompt: Prompt?

    @ObservationIgnored private let service: any SeriesAuthorsService & ItemDetailService
    @ObservationIgnored private let access: DownloadAccess
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let maxBooks: Int
    /// The books still to queue once the user confirms.
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var failures = 0
    /// The request that asked for ``Prompt/meteredConfirmation``: the rest is queued in its session.
    @ObservationIgnored private var meteredTicket: DownloadRequestTicket?

    public init(
        seriesID: String, connectionID: UUID, service: any SeriesAuthorsService & ItemDetailService,
        access: DownloadAccess, pageSize: Int = 50,
        maxBooks: Int = 10_000
    ) {
        self.seriesID = seriesID
        self.connectionID = connectionID
        self.service = service
        self.access = access
        self.pageSize = max(pageSize, 1)
        self.maxBooks = max(maxBooks, 1)
    }

    /// Lists the series' books in `libraryID` that aren't downloaded or queued, and prompts.
    public func start(libraryID: String) async {
        guard !isWorking, access.requester.canRequest(connectionID: connectionID) else { return }
        isWorking = true
        defer { isWorking = false }
        pending = []
        do {
            let books = try await allBooks(libraryID: libraryID)
            let skipping = try await access.status.downloadedOrQueuedItemIDs(connectionID: connectionID)
            let plan = SeriesDownloadPlan(books: books, skipping: skipping)
            pending = plan.itemIDs
            prompt = plan.itemIDs.isEmpty ? .alreadyDownloaded : .confirm(plan)
        } catch is CancellationError {
        } catch  where Task.isCancelled {
        } catch {
            Log.downloads.error(
                "Couldn't list a series' books to download: \(RealtimeBridge.logSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
            )
            prompt = .loadFailed
        }
    }

    /// Queues the confirmed plan's books.
    public func confirm() async {
        failures = 0
        await queue(metered: false)
    }

    /// Queues the remaining books after the user agreed to download on a metered path.
    public func confirmMetered() async {
        await queue(metered: true)
    }

    /// Drops the plan, for a cancelled confirmation.
    public func cancel() {
        pending = []
        failures = 0
        meteredTicket = nil
    }

    private struct TooManyBooks: Error {}
    private struct UndecodablePage: Error {}

    private func allBooks(libraryID: String) async throws -> [LibraryItem] {
        var books: [LibraryItem] = []
        var ids: Set<String> = []
        var page = 0
        while true {
            try Task.checkCancellation()
            let query = LibraryQuery(filter: .series(id: seriesID), page: page, limit: pageSize)
            let results = try await service.filteredBooksPage(libraryID: libraryID, query: query)
            // Rows decode lossily: a page with rows that didn't decode would leave books out of the
            // plan (or call the series downloaded), so the listing fails rather than offer part of it.
            if results.results.count < results.rawCount { throw UndecodablePage() }
            let new = results.results.filter { ids.insert($0.id).inserted }
            if new.isEmpty { return books }
            books += new
            if books.count > maxBooks { throw TooManyBooks() }
            page += 1
            let listed = page * pageSize
            if results.rawCount < pageSize || listed >= (results.total ?? listed) { return books }
        }
    }

    private func queue(metered: Bool) async {
        guard !isWorking else { return }
        guard access.requester.canRequest(connectionID: connectionID) else { return cancel() }
        isWorking = true
        defer { isWorking = false }
        while let id = pending.first {
            let item: LibraryItem
            do {
                item = try await service.item(id: id)
            } catch is CancellationError {
                cancel()
                return
            } catch {
                failures += 1
                pending.removeFirst()
                continue
            }
            // The account may have reconnected without download permission during the fetch; the
            // requester checks again, and rejects the request if the session ended meanwhile.
            guard access.requester.canRequest(connectionID: connectionID) else { return cancel() }
            let outcome: DownloadRequestOutcome
            if metered {
                guard let meteredTicket else { return cancel() }
                outcome = await access.requester.confirmMeteredDownload(
                    item: item, episodeID: nil, ticket: meteredTicket)
            } else {
                outcome = await access.requester.request(item: item, episodeID: nil, connectionID: connectionID)
            }
            switch outcome {
            case .started:
                pending.removeFirst()
            case .needsConfirmation(_, let ticket):
                meteredTicket = ticket
                prompt = .meteredConfirmation
                return
            case .denied:
                cancel()
                prompt = .meteredDenied
                return
            case .rejected:
                return cancel()
            case .failed(let error):
                Log.downloads.error(
                    "Couldn't queue a series book: \(RealtimeBridge.logSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
                )
                failures += 1
                pending.removeFirst()
            }
        }
        if failures > 0 { prompt = .queueFailed(count: failures) }
        failures = 0
    }
}
