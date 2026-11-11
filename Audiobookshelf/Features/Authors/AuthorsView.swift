import ABSAppModel
import SwiftUI

/// The Authors section of a book library (legacy `pages/bookshelf/authors.vue`). A stub until
/// the Authors feature replaces this file.
struct AuthorsView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.authors.titleKey, systemImage: AppTab.authors.systemImage)
    }
}

/// One author. A stub until the Authors feature replaces this file.
struct AuthorDetailView: View {
    let authorID: String

    var body: some View {
        FeatureStub(titleKey: "LabelAuthor", systemImage: "person", details: [authorID])
    }
}

#Preview("Authors") {
    NavigationStack { AuthorsView() }
}

#Preview("Detail") {
    NavigationStack { AuthorDetailView(authorID: "aut_1") }
}
