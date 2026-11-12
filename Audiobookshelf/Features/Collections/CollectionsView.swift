import ABSAppModel
import SwiftUI

/// The Collections section of a book library (legacy `pages/bookshelf/collections.vue`).
struct CollectionsView: View {
    var body: some View {
        GroupListView(kind: .collection)
    }
}

/// One collection (legacy `pages/collection/_id.vue`): its books with their progress, and Play.
struct CollectionDetailView: View {
    let collectionID: String

    var body: some View {
        GroupDetailView<CollectionGroupKind>(groupID: collectionID)
    }
}

#Preview("Collections, signed out") {
    NavigationStack { CollectionsView() }
}

#Preview("Detail, signed out") {
    NavigationStack { CollectionDetailView(collectionID: "col_1") }
}
