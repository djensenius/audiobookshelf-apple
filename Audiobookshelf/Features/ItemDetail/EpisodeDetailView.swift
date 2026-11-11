import SwiftUI

/// A podcast episode (legacy `pages/item/_id/_episode`). A stub until the episode detail feature
/// (#69) replaces this file.
struct EpisodeDetailView: View {
    let itemID: String
    let episodeID: String

    var body: some View {
        FeatureStub(titleKey: "LabelEpisode", systemImage: "waveform", details: [itemID, episodeID])
    }
}

#Preview {
    NavigationStack { EpisodeDetailView(itemID: "li_1", episodeID: "ep_1") }
}
