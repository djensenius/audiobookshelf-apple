import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the episode screen's More menu ("…") to the toolbar, with its confirmation and
    /// failure alerts.
    func episodeDetailMoreMenu(model: EpisodeDetailModel, serverURL: URL?) -> some View {
        modifier(EpisodeDetailMoreMenu(model: model, serverURL: serverURL))
    }
}

/// The episode screen's More menu (legacy `moreMenuItems`): Mark as finished or not finished,
/// Discard progress and Share, as ``EpisodeDetailModel/menuActions(canEditPlaylists:canShare:isGone:)``
/// offers them, through ``DetailMoreMenu``, which runs the progress actions for the episode with
/// the book screen's titles, confirmations and failure messages and remembers a 404. Share links
/// to the podcast in the web client, so it needs the server's address. Add to playlist stays
/// hidden until the playlist editor exists.
private struct EpisodeDetailMoreMenu: ViewModifier {
    let model: EpisodeDetailModel
    let serverURL: URL?

    /// The playlist editor doesn't exist yet.
    private static let canEditPlaylists = false

    func body(content: Content) -> some View {
        let canShare = serverURL != nil
        content.modifier(
            DetailMoreMenu(model: model) { [model] isGone in
                model.menuActions(canEditPlaylists: Self.canEditPlaylists, canShare: canShare, isGone: isGone)
            } entry: { action in
                entry(action)
            }
        )
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
            // Not offered while `canEditPlaylists` is false (#93).
            EmptyView()
        case .markFinished, .markNotFinished, .discardProgress:
            // Shown by ``DetailMoreMenu``.
            EmptyView()
        case .hideFromContinueListening, .details, .history:
            // Not offered for episodes.
            EmptyView()
        }
    }
}
