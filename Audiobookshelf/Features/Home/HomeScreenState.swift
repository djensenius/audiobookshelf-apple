import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What Home shows, decided from the environment and its ``HomeModel`` without SwiftUI.
enum HomeScreenState: Equatable {
    /// No library data: nobody is signed in, or the store was cleared.
    case signedOut
    /// The libraries or the first load of the current library are loading or about to.
    case loading
    /// Loading the libraries list failed before a library was selected; Retry refreshes the store.
    case librariesFailed
    /// The first load failed, or a reload failed with nothing to show, or the downloads couldn't
    /// be read with nothing else to show; Retry loads again.
    case failed
    /// The libraries loaded but none is selected, or the library has no shelves, and nothing is
    /// downloaded.
    case empty
    /// The network or the server is unavailable and nothing is downloaded: why, with Retry while
    /// the server is unreachable (legacy `pages/bookshelf/index.vue`).
    case disconnected(ConnectionBannerStatus)
    /// The sections; `refreshFailed` when the last reload failed and older shelves are shown, or
    /// the downloads couldn't be read. Disconnected, only the downloaded shelves (ADR 0004).
    case shelves(refreshFailed: Bool)

    /// What ``resolve(_:)`` decides from.
    struct Inputs: Equatable {
        /// The environment has a `LibraryStore` that serves an account (its `connectionKey` is set).
        var isSignedIn = true
        /// The store's libraries request succeeded once for this account.
        var librariesLoaded = true
        var librariesLoading = false
        /// The store's last libraries request failed.
        var librariesFailed = false
        /// The router's current library.
        var libraryID: String? = "lib"
        /// The model has loaded shelves for ``libraryID`` (not for an earlier library).
        var hasLoaded = false
        var isLoading = false
        /// The model's last load of ``libraryID`` failed.
        var hasError = false
        /// The model has no sections.
        var isEmpty = true
        /// Why the server can't be used (the connection banner's status), or `nil` online.
        var connection: ConnectionBannerStatus?
        /// Home has downloaded shelves to show.
        var hasDownloads = false
        /// The downloaded items have been read, so ``hasDownloads`` can be trusted.
        var downloadsLoaded = true
        /// The downloaded items couldn't be read (``DownloadedShelfModel/loadError``).
        var downloadsFailed = false
    }

    static func resolve(_ inputs: Inputs) -> HomeScreenState {
        guard inputs.isSignedIn else { return .signedOut }
        // Without the server, Home shows only what's downloaded, or why there's nothing.
        if let connection = inputs.connection { return downloadsOr(.disconnected(connection), inputs) }
        guard inputs.libraryID != nil else {
            // The shell selects a library once the libraries have loaded.
            if inputs.librariesFailed, !inputs.librariesLoading { return .librariesFailed }
            return inputs.librariesLoaded ? downloadsOr(.empty, inputs) : .loading
        }
        guard inputs.hasLoaded else { return inputs.hasError && !inputs.isLoading ? .failed : .loading }
        if inputs.isEmpty { return inputs.hasError ? .failed : downloadsOr(.empty, inputs) }
        return .shelves(refreshFailed: inputs.hasError || inputs.downloadsFailed)
    }

    /// The downloaded shelves when there are some, otherwise `state`; loading until the downloads
    /// have been read, so `state` doesn't flash first, and failed when they couldn't be, so Home
    /// doesn't say there are none and Retry reads them again.
    private static func downloadsOr(_ state: HomeScreenState, _ inputs: Inputs) -> HomeScreenState {
        guard inputs.downloadsLoaded else { return .loading }
        if inputs.hasDownloads { return .shelves(refreshFailed: inputs.downloadsFailed) }
        return inputs.downloadsFailed ? .failed : state
    }

    /// The state for `store` and `model` while the router shows `libraryID`.
    ///
    /// Until `model` adopts a new `libraryID` (in the view's task), its shelves, loaded flag and
    /// error belong to the previous library, so they count as not loaded yet.
    ///
    /// - Parameters:
    ///   - sections: `model.sections`, read once by the caller.
    ///   - connection: Why the server can't be used, or `nil` online.
    ///   - downloads: The downloaded shelves Home would show
    ///     (``HomePresentation/downloadedSections(of:libraryKind:isConnected:)``).
    ///   - downloadsLoaded: The downloaded items have been read; `true` without a download stack.
    ///   - downloadsFailed: The downloaded items couldn't be read.
    @MainActor
    static func resolve(
        store: LibraryStore?, model: HomeModel?, libraryID: String?, sections: [HomeSection],
        connection: ConnectionBannerStatus? = nil, downloads: [HomeSection] = [], downloadsLoaded: Bool = true,
        downloadsFailed: Bool = false
    ) -> HomeScreenState {
        guard let store, let model else { return .signedOut }
        let isCurrent = model.libraryID == libraryID
        return resolve(
            Inputs(
                isSignedIn: store.connectionKey != nil, librariesLoaded: store.hasLoaded,
                librariesLoading: store.isLoading, librariesFailed: store.error != nil, libraryID: libraryID,
                hasLoaded: isCurrent && model.hasLoaded, isLoading: isCurrent && model.isLoading,
                hasError: isCurrent && model.error != nil, isEmpty: !isCurrent || sections.isEmpty,
                connection: connection, hasDownloads: !downloads.isEmpty, downloadsLoaded: downloadsLoaded,
                downloadsFailed: downloadsFailed))
    }
}

/// When Home reloads shelves it already has: on appear and when the scene becomes active, once
/// they are older than ``maxAge``, like the legacy page refetching on every visit.
struct HomeRefreshSchedule {
    /// What to do with the current library's shelves.
    enum Request: Equatable {
        /// Load the shelves the model doesn't have yet.
        case load
        /// Reload the shelves the model has.
        case refresh
    }

    /// How old shelves may get before they are reloaded on appear.
    static let maxAge: TimeInterval = 5 * 60

    /// The library whose shelves last loaded successfully, and when.
    private(set) var loaded: (libraryID: String, date: Date)?

    /// The request to make for `libraryID` at `now`; `nil` when the shelves are fresh. It doesn't
    /// consider the connection: Home asks ``request(for:libraryID:hasLoaded:hasError:isConnected:now:)``.
    ///
    /// - Parameters:
    ///   - hasLoaded: The model has shelves for `libraryID`.
    ///   - force: The user asked to refresh (pull to refresh, the Refresh command).
    func request(libraryID: String, hasLoaded: Bool, now: Date, force: Bool = false) -> Request? {
        guard hasLoaded else { return .load }
        if force { return .refresh }
        guard let loaded, loaded.libraryID == libraryID else { return .refresh }
        return now.timeIntervalSince(loaded.date) >= Self.maxAge ? .refresh : nil
    }

    /// What asks Home for its shelves.
    enum Trigger: CaseIterable {
        /// Home appeared, or its library, client, online revision or connection changed.
        case loadTrigger
        /// The scene became active.
        case sceneActivation
        /// Pull to refresh, the Refresh command or Retry.
        case userRefresh
    }

    /// The request `trigger` makes for `libraryID` at `now`, or `nil`.
    ///
    /// None without the server, whatever the trigger, so losing the connection never starts a
    /// server request. Otherwise ``request(libraryID:hasLoaded:now:force:)``, forced for the
    /// user's refresh, and for the load trigger after a failed load or refresh, so a reconnect
    /// retries it at once rather than leaving its error up until the shelves are older than
    /// ``maxAge``. Fresh shelves without an error aren't fetched again.
    ///
    /// - Parameters:
    ///   - hasError: The model's last load or refresh failed.
    ///   - isConnected: The server can be used (no connection banner).
    func request(
        for trigger: Trigger, libraryID: String, hasLoaded: Bool, hasError: Bool, isConnected: Bool, now: Date
    ) -> Request? {
        guard isConnected else { return nil }
        let force =
            switch trigger {
            case .loadTrigger: hasError
            case .sceneActivation: false
            case .userRefresh: true
            }
        return request(libraryID: libraryID, hasLoaded: hasLoaded, now: now, force: force)
    }

    /// Whether `trigger` reloads the libraries list while no library is selected, so the shell
    /// selects one and Home loads its shelves. Always on the user's refresh, as before. On the load
    /// trigger only after the list failed and while it isn't loading: when the server answers
    /// again (the disconnected state's Retry, or the banner's own check), the list loads at once
    /// instead of Home showing the libraries' failure and waiting for another Retry. Not on scene
    /// activation, and never without the server.
    ///
    /// - Parameters:
    ///   - librariesFailed: The store's last libraries request failed.
    ///   - librariesLoading: The store is loading the libraries.
    ///   - isConnected: The server can be used (no connection banner).
    static func refreshesLibraries(
        for trigger: Trigger, librariesFailed: Bool, librariesLoading: Bool, isConnected: Bool
    ) -> Bool {
        guard isConnected else { return false }
        return switch trigger {
        case .loadTrigger: librariesFailed && !librariesLoading
        case .sceneActivation: false
        case .userRefresh: true
        }
    }

    /// The model's state when a request it made finished.
    struct ModelState {
        var libraryID: String?
        var hasLoaded: Bool
        var isLoading: Bool
        var hasError: Bool
    }

    /// Records the end of a load or refresh of `libraryID` as fresh shelves at `date`, only when it
    /// actually completed with new data. A cancelled request (Home disappeared) leaves the earlier
    /// shelves without an error, so it must not count, or returning to Home would skip the
    /// refresh. Neither does one superseded by a load still running (that load records itself),
    /// a failed one, or one for a library the model no longer shows.
    ///
    /// - Returns: Whether it was recorded.
    @discardableResult
    mutating func recordCompletion(of libraryID: String, model: ModelState, isCancelled: Bool, at date: Date) -> Bool {
        guard !isCancelled, model.libraryID == libraryID, model.hasLoaded, !model.isLoading, !model.hasError
        else { return false }
        markLoaded(libraryID: libraryID, at: date)
        return true
    }

    /// Records a successful load or refresh of `libraryID`.
    mutating func markLoaded(libraryID: String, at date: Date) {
        loaded = (libraryID, date)
    }
}

/// How Home presents its sections and entries.
enum HomePresentation {
    /// The section's localized title; the server's label when the key is missing or unknown, as
    /// the legacy `getShelfLabel` does.
    static func title(of section: HomeSection, locale: Locale? = nil) -> String {
        guard let key = section.titleKey, !key.isEmpty else { return section.label }
        let title = L10n.string(key, locale: locale)
        return title == key ? section.label : title
    }

    /// The screen an entry opens.
    static func route(for entry: HomeEntry) -> Route {
        switch entry {
        case .item(let item): ItemCardActions.route(for: item)
        case .series(let series): .series(id: series.id)
        case .author(let author): .author(id: author.id)
        }
    }

    /// The width of one card at the default text size.
    static func cardWidth(for kind: HomeSectionKind) -> CGFloat {
        switch kind {
        case .book, .podcast, .episode: 140
        case .series: 180
        case .authors: 120
        }
    }

    /// The downloaded shelves Home shows (legacy `pages/bookshelf/index.vue`): online, only the
    /// shelf of the current library's kind; disconnected, Local Books and Local Podcasts.
    @MainActor
    static func downloadedSections(
        of shelf: DownloadedShelfModel?, libraryKind: LibraryKind?, isConnected: Bool
    ) -> [HomeSection] {
        shelf?.sections(for: isConnected ? libraryKind : nil) ?? []
    }

    /// Whether `section` is one of the downloaded shelves (``DownloadedShelfModel/sections(for:)``),
    /// whose items can be from any of the account's libraries rather than the selected one.
    static func isDownloaded(_ section: HomeSection) -> Bool {
        [DownloadedShelfModel.booksSectionID, DownloadedShelfModel.podcastsSectionID].contains(section.id)
    }

    /// The library Add to playlist lists and creates playlists in for `item` on `section`, for
    /// ``AddToPlaylistAction``: `nil`, the scene's library, on the server's shelves, which are that
    /// library's. A downloaded item can be from another of the account's libraries and the download
    /// doesn't record which, so its own is read from the server, which Add to playlist needs anyway.
    static func playlistLibraryID(
        for item: ItemSummary, in section: HomeSection, items: any ItemDetailService
    ) async throws -> String? {
        guard isDownloaded(section) else { return nil }
        return try await items.item(id: item.itemID).libraryId
    }

    /// The sections Home shows: online, the server's and then the downloaded ones; disconnected,
    /// only the downloaded ones, as legacy and ADR 0004 do.
    static func sections(server: [HomeSection], downloaded: [HomeSection], isConnected: Bool) -> [HomeSection] {
        isConnected ? server + downloaded : downloaded
    }

    /// The disconnected state's Retry: only while the server is unreachable. Without a network
    /// there's nothing to retry, and while checking a check is already running.
    static func connectionRetry(
        for status: ConnectionBannerStatus, retry: @escaping () -> Void
    ) -> (() -> Void)? {
        status.offersRetry ? retry : nil
    }
}
