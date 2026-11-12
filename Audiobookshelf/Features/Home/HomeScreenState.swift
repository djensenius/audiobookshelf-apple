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
    /// The first load failed, or a reload failed with nothing to show; Retry reloads the shelves.
    case failed
    /// The libraries loaded but none is selected, or the library has no shelves.
    case empty
    /// The sections; `refreshFailed` when the last reload failed and older shelves are shown.
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
    }

    static func resolve(_ inputs: Inputs) -> HomeScreenState {
        guard inputs.isSignedIn else { return .signedOut }
        guard inputs.libraryID != nil else {
            // The shell selects a library once the libraries have loaded.
            if inputs.librariesFailed, !inputs.librariesLoading { return .librariesFailed }
            return inputs.librariesLoaded ? .empty : .loading
        }
        guard inputs.hasLoaded else { return inputs.hasError && !inputs.isLoading ? .failed : .loading }
        if inputs.isEmpty { return inputs.hasError ? .failed : .empty }
        return .shelves(refreshFailed: inputs.hasError)
    }

    /// The state for `store` and `model` while the router shows `libraryID`.
    ///
    /// Until `model` adopts a new `libraryID` (in the view's task), its shelves, loaded flag and
    /// error belong to the previous library, so they count as not loaded yet.
    ///
    /// - Parameter sections: `model.sections`, read once by the caller.
    @MainActor
    static func resolve(
        store: LibraryStore?, model: HomeModel?, libraryID: String?, sections: [HomeSection]
    ) -> HomeScreenState {
        guard let store, let model else { return .signedOut }
        let isCurrent = model.libraryID == libraryID
        return resolve(
            Inputs(
                isSignedIn: store.connectionKey != nil, librariesLoaded: store.hasLoaded,
                librariesLoading: store.isLoading, librariesFailed: store.error != nil, libraryID: libraryID,
                hasLoaded: isCurrent && model.hasLoaded, isLoading: isCurrent && model.isLoading,
                hasError: isCurrent && model.error != nil, isEmpty: !isCurrent || sections.isEmpty))
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

    /// The request to make for `libraryID` at `now`; `nil` when the shelves are fresh.
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
}
