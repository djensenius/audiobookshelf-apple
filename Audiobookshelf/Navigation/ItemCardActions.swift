import ABSAppModel
import ABSCore
import Foundation

/// What an item card does on the library screens (Home, series, authors): the screen it opens
/// and its context-menu actions. App code rather than ABSUI, which can't see `Route` or the
/// actions' types.
enum ItemCardActions {
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

    /// The actions a card offers: Play only while there is a player to call; no sharing or
    /// playlists yet.
    static func actionContext(canPlay: Bool) -> ItemActionContext {
        ItemActionContext(canEditPlaylists: false, canPlay: canPlay, canShare: false)
    }

    /// Performs a context-menu action on `item`: Play through `play`, the progress actions
    /// through `actions`. Opening is navigation and isn't handled here; neither are actions the
    /// cards don't offer.
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
