import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What Home shows, decided from the environment and its ``HomeModel`` without SwiftUI.
enum HomeScreenState: Equatable {
    /// No library data: nobody is signed in.
    case signedOut
    /// The first load of the current library is running or about to start.
    case loading
    /// The first load failed, or a reload failed with nothing to show.
    case failed
    /// No library is selected, or the library has no shelves.
    case empty
    /// The sections; `refreshFailed` when the last reload failed and older shelves are shown.
    case shelves(refreshFailed: Bool)

    /// - Parameters:
    ///   - hasStore: Whether the environment has a `LibraryStore` (signed in).
    ///   - libraryID: The router's current library.
    ///   - isEmpty: Whether ``HomeModel/sections`` is empty.
    static func resolve(
        hasStore: Bool, libraryID: String?, hasLoaded: Bool, isLoading: Bool, hasError: Bool, isEmpty: Bool
    ) -> HomeScreenState {
        guard hasStore else { return .signedOut }
        guard libraryID != nil else { return .empty }
        guard hasLoaded else { return hasError && !isLoading ? .failed : .loading }
        if isEmpty { return hasError ? .failed : .empty }
        return .shelves(refreshFailed: hasError)
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
        case .item(let item): route(for: item)
        case .series(let series): .series(id: series.id)
        case .author(let author): .author(id: author.id)
        }
    }

    /// The screen an item card opens: its episode, its collapsed series, or the item.
    static func route(for item: ItemSummary) -> Route {
        switch item.kind {
        case .episode:
            if let episodeID = item.episodeID { return .episode(itemID: item.itemID, episodeID: episodeID) }
        case .series:
            if let seriesID = item.seriesID { return .series(id: seriesID) }
        case .book, .podcast:
            break
        }
        return .item(id: item.itemID)
    }

    /// The actions Home can perform: Play only while there is a player to call; no sharing or
    /// playlists yet.
    static func actionContext(canPlay: Bool) -> ItemActionContext {
        ItemActionContext(canEditPlaylists: false, canPlay: canPlay, canShare: false)
    }

    /// The width of one card at the default text size.
    static func cardWidth(for kind: HomeSectionKind) -> CGFloat {
        switch kind {
        case .book, .podcast, .episode: 140
        case .series: 180
        case .authors: 120
        }
    }

    /// Performs a context-menu action on `item`: Play through `play`, the progress actions
    /// through `actions`. Opening is navigation and isn't handled here; neither are actions Home
    /// doesn't offer.
    ///
    /// - Returns: The key of the message to show when the action failed; `nil` when it succeeded,
    ///   was cancelled or did nothing.
    @MainActor
    static func perform(
        _ kind: ItemActionKind, on item: ItemSummary, actions: any ItemActionPerforming, play: PlayItemAction?
    ) async -> String? {
        let target = ItemActionTarget(libraryItemID: item.itemID, episodeID: item.episodeID, duration: item.duration)
        do {
            switch kind {
            case .play:
                guard let play else { return nil }
                try await play(itemID: item.itemID, episodeID: item.episodeID)
            case .markFinished: try await actions.markFinished(target)
            case .markNotFinished: try await actions.markNotFinished(target)
            case .hideFromContinueListening: try await actions.hideFromContinueListening(target)
            case .addToPlaylist, .share, .openDetails: return nil
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return failureMessageKey(for: kind)
        }
    }

    /// The key of the message shown when an action on an item fails.
    static func failureMessageKey(for kind: ItemActionKind) -> String? {
        switch kind {
        case .play: "MessagePlaybackStartFailed"
        case .markFinished: "ToastItemMarkedAsFinishedFailed"
        case .markNotFinished: "ToastItemMarkedAsNotFinishedFailed"
        case .hideFromContinueListening: "MessageHideFromContinueListeningFailed"
        case .addToPlaylist, .share, .openDetails: nil
        }
    }
}
