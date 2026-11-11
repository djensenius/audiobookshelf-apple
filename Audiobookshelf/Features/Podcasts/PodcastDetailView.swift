import ABSAppModel
import ABSCore
import SwiftUI

/// A podcast item (legacy `pages/item/_id/index.vue` with a podcast): ``ItemDetailView`` shows
/// it once the item has loaded as a podcast, passing its loaded model so the item isn't fetched
/// twice. A stub until the podcast detail feature (#68) replaces this file.
struct PodcastDetailView: View {
    let model: ItemDetailModel

    var body: some View {
        FeatureStub(titleKey: "LabelPodcast", systemImage: "mic", details: [model.itemID])
    }
}

#Preview {
    ItemDetailPreview(item: SampleLibrary.podcast)
}
