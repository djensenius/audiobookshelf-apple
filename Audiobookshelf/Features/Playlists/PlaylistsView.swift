import ABSAppModel
import SwiftUI

/// The Playlists section, shown when the user has playlists (legacy
/// `pages/bookshelf/playlists.vue`). A stub until the Playlists feature replaces this file.
struct PlaylistsView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.playlists.titleKey, systemImage: AppTab.playlists.systemImage)
    }
}

/// One playlist (legacy `pages/playlist/_id.vue`). A stub until the Playlists feature replaces
/// this file.
struct PlaylistDetailView: View {
    let playlistID: String

    var body: some View {
        FeatureStub(titleKey: "HeaderPlaylist", systemImage: AppTab.playlists.systemImage, details: [playlistID])
    }
}

#Preview("Playlists") {
    NavigationStack { PlaylistsView() }
}

#Preview("Detail") {
    NavigationStack { PlaylistDetailView(playlistID: "pl_1") }
}
