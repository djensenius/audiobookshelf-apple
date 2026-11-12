import ABSAppModel
import ABSCore
import SwiftUI

/// What an item card does on the library screens (Home, series, authors): the screen it opens and its context-menu
/// actions. App code rather than ABSUI, which can't see `Route` or the actions' types.
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

    /// The actions a card offers: Play only while there is a player to call, Open in New Window only where the
    /// device has windows (``OpenInNewWindow``), Add to playlist only while the account can edit playlists
    /// (`\.addToPlaylist`); no sharing yet.
    static func actionContext(
        canPlay: Bool, canOpenInNewWindow: Bool = false, canEditPlaylists: Bool = false
    ) -> ItemActionContext {
        ItemActionContext(
            canEditPlaylists: canEditPlaylists, canPlay: canPlay, canShare: false,
            canOpenInNewWindow: canOpenInNewWindow
        )
    }

    /// What Add to playlist adds for `item`, as the More menus do: the book, or this exact episode. `nil` for a
    /// podcast, a collapsed series, an episode without its ID or a missing item, which the cards don't offer it for.
    static func playlistEntry(for item: ItemSummary) -> PlaylistEntryKey? {
        guard !item.isMissing else { return nil }
        switch item.kind {
        case .book: return PlaylistEntryKey(itemID: item.itemID)
        case .episode: return item.episodeID.map { PlaylistEntryKey(itemID: item.itemID, episodeID: $0) }
        case .podcast, .series: return nil
        }
    }

    /// The add-to-playlist sheet's model for `item` in the library `libraryID`; `nil` without a library or for an
    /// item that has no ``playlistEntry(for:)``.
    @MainActor
    static func addToPlaylistModel(
        for item: ItemSummary, libraryID: String?, playlists: any PlaylistEditingService
    ) -> AddToPlaylistModel? {
        guard let libraryID, let entry = playlistEntry(for: item) else { return nil }
        return AddToPlaylistModel(entries: [entry], libraryID: libraryID, service: playlists)
    }

    /// Performs a context-menu action on `item`: Play through `play`, the progress actions through `actions`.
    /// Opening is navigation and isn't handled here, nor is Add to playlist, which the hosts open through
    /// `\.addToPlaylist`; neither are actions the cards don't offer.
    ///
    /// - Returns: The failure message's key; `nil` when the action succeeded, was cancelled or did nothing.
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
            case .addToPlaylist, .share, .openDetails, .openInNewWindow: return nil
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
        case .addToPlaylist, .share, .openDetails, .openInNewWindow: nil
        }
    }
}

extension EnvironmentValues {
    /// Opens ``AddToPlaylistSheet`` for an item card's or episode row's book or episode; `nil` while the account
    /// can't edit playlists (signed out, previews), so the cards don't offer Add to playlist. Set by
    /// ``ItemCardPlaylists``.
    @Entry var addToPlaylist: AddToPlaylistAction?
}

/// Add to playlist from an item card or episode row, as the book and episode More menus offer it: opens
/// ``AddToPlaylistSheet`` for the item (``ItemCardActions/playlistEntry(for:)``) in its library.
struct AddToPlaylistAction: Sendable {
    let open: @MainActor @Sendable (_ item: ItemSummary, _ libraryID: String?) -> Void

    /// Opens the sheet for `item` in `libraryID`, or the scene's library when `nil`.
    @MainActor
    func callAsFunction(_ item: ItemSummary, libraryID: String? = nil) {
        open(item, libraryID)
    }
}

/// Puts ``AddToPlaylistAction`` in the environment of the scene's screens while the environment's `libraryStore` has
/// an account, and presents the sheet it opens; ``MainTabView`` applies it once, so every card host shares it.
struct ItemCardPlaylists: ViewModifier {
    let router: Router
    @Environment(\.libraryStore) private var store
    @State private var model: AddToPlaylistModel?

    func body(content: Content) -> some View {
        content
            .environment(\.addToPlaylist, action)
            .addToPlaylistSheet($model)
    }

    private var action: AddToPlaylistAction? {
        guard let playlists = store?.makeServices() else { return nil }
        let sceneLibraryID = router.libraryID
        let model = $model
        return AddToPlaylistAction { item, libraryID in
            model.wrappedValue = ItemCardActions.addToPlaylistModel(
                for: item, libraryID: libraryID ?? sceneLibraryID, playlists: playlists)
        }
    }
}
