import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the episode screen's More menu ("…") to the toolbar, with its confirmation and
    /// failure alerts and, with `playlists`, the add-to-playlist sheet.
    func episodeDetailMoreMenu(
        model: EpisodeDetailModel, serverURL: URL?, playlists: (any PlaylistEditingService)? = nil
    ) -> some View {
        modifier(EpisodeDetailMoreMenu(model: model, serverURL: serverURL, playlists: playlists))
    }
}

/// The episode screen's More menu (legacy `moreMenuItems`): Mark as finished or not finished,
/// Discard progress, Add to playlist and Share, as ``EpisodeDetailModel/menuActions(canEditPlaylists:canShare:isGone:)``
/// offers them, through ``DetailMoreMenu``, which runs the progress actions for the episode with
/// the book screen's titles, confirmations and failure messages and remembers a 404. Share links
/// to the podcast in the web client, so it needs the server's address. Add to playlist opens
/// ``AddToPlaylistSheet`` for the episode, so it needs the account's playlist writes (`playlists`).
private struct EpisodeDetailMoreMenu: ViewModifier {
    let model: EpisodeDetailModel
    let serverURL: URL?
    let playlists: (any PlaylistEditingService)?
    @State private var addToPlaylist: AddToPlaylistModel?

    func body(content: Content) -> some View {
        let canShare = serverURL != nil
        let canEditPlaylists = playlists != nil
        content
            .modifier(
                DetailMoreMenu(model: model) { [model] isGone in
                    model.menuActions(canEditPlaylists: canEditPlaylists, canShare: canShare, isGone: isGone)
                } entry: { action in
                    entry(action)
                }
            )
            .addToPlaylistSheet($addToPlaylist)
    }

    /// The episode's own entries; ``DetailMoreMenu`` shows the progress actions.
    @ViewBuilder private func entry(_ action: ItemDetailMenuAction) -> some View {
        switch action {
        case .share:
            if let serverURL {
                ShareLink(item: EpisodeDetailPresentation.shareURL(serverURL: serverURL, itemID: model.itemID)) {
                    DetailMoreMenuLabel(action: action)
                }
            }
        case .addToPlaylist:
            Button {
                guard let playlists, let libraryID = model.detail.item?.libraryId else { return }
                addToPlaylist = AddToPlaylistModel(
                    entries: [PlaylistEntryKey(itemID: model.itemID, episodeID: model.episodeID)],
                    libraryID: libraryID, service: playlists)
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .markFinished, .markNotFinished, .discardProgress:
            // Shown by ``DetailMoreMenu``.
            EmptyView()
        case .hideFromContinueListening, .details, .history:
            // Not offered for episodes.
            EmptyView()
        }
    }
}
