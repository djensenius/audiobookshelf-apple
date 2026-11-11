import SwiftUI

/// An item (legacy `pages/item/_id/index.vue`). A stub until the book detail feature (#66)
/// replaces this file. #66 owns this view and will route podcast items to a separate
/// `PodcastDetailView` stub, which the podcast detail feature (#68) fills; episodes have their
/// own file, ``EpisodeDetailView`` (#69).
struct ItemDetailView: View {
    let itemID: String

    var body: some View {
        FeatureStub(titleKey: "HeaderDetails", systemImage: "book", details: [itemID])
    }
}

#Preview {
    NavigationStack { ItemDetailView(itemID: "li_1") }
}
