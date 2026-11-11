import ABSAppModel
import SwiftUI

/// The Collections section of a book library (legacy `pages/bookshelf/collections.vue`). A stub
/// until the Collections feature replaces this file.
struct CollectionsView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.collections.titleKey, systemImage: AppTab.collections.systemImage)
    }
}

/// One collection (legacy `pages/collection/_id.vue`). A stub until the Collections feature
/// replaces this file.
struct CollectionDetailView: View {
    let collectionID: String

    var body: some View {
        FeatureStub(
            titleKey: "HeaderCollection", systemImage: AppTab.collections.systemImage, details: [collectionID])
    }
}

#Preview("Collections") {
    NavigationStack { CollectionsView() }
}

#Preview("Detail") {
    NavigationStack { CollectionDetailView(collectionID: "col_1") }
}
