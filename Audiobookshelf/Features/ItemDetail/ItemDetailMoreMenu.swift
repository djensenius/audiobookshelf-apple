import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the book screen's More menu ("…") to the toolbar, with its confirmations, failure
    /// alert, details sheet and, with `playlists`, the add-to-playlist sheet.
    func itemDetailMoreMenu(
        model: ItemDetailModel, serverURL: URL?, playlists: (any PlaylistEditingService)? = nil
    ) -> some View {
        modifier(ItemDetailMoreMenu(model: model, serverURL: serverURL, playlists: playlists))
    }
}

/// The book screen's More menu (legacy `ItemMoreMenuModal.vue`): the entries
/// ``ItemDetailMenuPresentation/actions(for:isGone:canEditPlaylists:canShare:canRoute:)`` offers,
/// through ``DetailMoreMenu``, which also runs the progress actions with their confirmations and
/// failure alert and remembers a 404. Share links to the web client, so it needs the server's
/// address; History pushes its route on the scene's ``Router`` (ADR 0004), so it is hidden
/// without one (previews); Add to playlist opens ``AddToPlaylistSheet`` for the book, so it needs the account's
/// playlist writes (`playlists`).
private struct ItemDetailMoreMenu: ViewModifier {
    let model: ItemDetailModel
    let serverURL: URL?
    let playlists: (any PlaylistEditingService)?
    @Environment(Router.self) private var router: Router?
    @State private var showsDetails = false
    @State private var addToPlaylist: AddToPlaylistModel?

    func body(content: Content) -> some View {
        let canShare = serverURL != nil
        let canRoute = router != nil
        let canEditPlaylists = playlists != nil
        content
            .modifier(
                DetailMoreMenu(model: model) { [model] isGone in
                    ItemDetailMenuPresentation.actions(
                        for: model, isGone: isGone, canEditPlaylists: canEditPlaylists, canShare: canShare,
                        canRoute: canRoute)
                } entry: { action in
                    entry(action)
                }
            )
            .sheet(isPresented: $showsDetails) {
                ItemDetailInfoSheet(model: model)
            }
            .addToPlaylistSheet($addToPlaylist)
    }

    /// The book's own entries; ``DetailMoreMenu`` shows the progress actions.
    @ViewBuilder private func entry(_ action: ItemDetailMenuAction) -> some View {
        switch action {
        case .share:
            if let serverURL {
                ShareLink(item: ItemDetailModel.webURL(serverURL: serverURL, itemID: model.itemID)) {
                    DetailMoreMenuLabel(action: action)
                }
            }
        case .details:
            Button {
                showsDetails = true
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .history:
            // A button rather than a `NavigationLink` in the menu, which doesn't push everywhere.
            Button {
                BrowsePresentation.open(.history(itemID: model.itemID), in: router)
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .addToPlaylist:
            Button {
                guard let playlists, let libraryID = model.item?.libraryId else { return }
                addToPlaylist = AddToPlaylistModel(
                    entries: [PlaylistEntryKey(itemID: model.itemID)], libraryID: libraryID, service: playlists)
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening:
            // Shown by ``DetailMoreMenu``.
            EmptyView()
        }
    }
}
