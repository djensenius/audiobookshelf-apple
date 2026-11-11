import SwiftUI

/// A podcast item (legacy `pages/item/_id/index.vue` with a podcast): ``ItemDetailView`` shows
/// it once the item has loaded as a podcast. A stub until the podcast detail feature (#68)
/// replaces this file.
struct PodcastDetailView: View {
    let itemID: String

    var body: some View {
        FeatureStub(titleKey: "LabelPodcast", systemImage: "mic", details: [itemID])
    }
}

#Preview {
    NavigationStack { PodcastDetailView(itemID: "li_podcast") }
}
