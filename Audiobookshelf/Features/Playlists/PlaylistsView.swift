import ABSAppModel
import SwiftUI

/// The Playlists section, shown when the user has playlists (legacy `pages/bookshelf/playlists.vue`).
struct PlaylistsView: View {
    var body: some View {
        GroupListView(kind: .playlist)
    }
}

/// One playlist (legacy `pages/playlist/_id.vue`): its books and podcast episodes with their progress, and Play.
struct PlaylistDetailView: View {
    let playlistID: String

    var body: some View {
        GroupDetailView<PlaylistGroupKind>(groupID: playlistID)
    }
}

#Preview("Playlists, signed out") {
    NavigationStack { PlaylistsView() }
}

#Preview("Detail, signed out") {
    NavigationStack { PlaylistDetailView(playlistID: "pl_1") }
}
