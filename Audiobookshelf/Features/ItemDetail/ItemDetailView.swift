import SwiftUI

/// An item (legacy `pages/item/_id/index.vue`). A stub until the item detail feature replaces
/// this file.
struct ItemDetailView: View {
    let itemID: String

    var body: some View {
        FeatureStub(titleKey: "HeaderDetails", systemImage: "book", details: [itemID])
    }
}

/// A podcast episode (legacy `pages/item/_id/_episode`). A stub until the item detail feature
/// replaces this file.
struct EpisodeDetailView: View {
    let itemID: String
    let episodeID: String

    var body: some View {
        FeatureStub(titleKey: "LabelEpisode", systemImage: "waveform", details: [itemID, episodeID])
    }
}

#Preview("Item") {
    NavigationStack { ItemDetailView(itemID: "li_1") }
}

#Preview("Episode") {
    NavigationStack { EpisodeDetailView(itemID: "li_1", episodeID: "ep_1") }
}
