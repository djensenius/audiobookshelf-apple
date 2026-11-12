import ABSAppModel
import SwiftUI

/// The library filtered to one narrator, tag or genre (``Route/libraryFilter(kind:value:)``).
/// A stub until the Library feature replaces this file.
struct LibraryFilterView: View {
    let kind: LibraryFilterKind
    let value: String

    var body: some View {
        FeatureStub(titleKey: titleKey, systemImage: "line.3.horizontal.decrease.circle", details: [value])
    }

    private var titleKey: String {
        switch kind {
        case .narrators: "LabelNarrator"
        case .tags: "LabelTag"
        case .genres: "LabelGenre"
        }
    }
}

#Preview("Filter") {
    NavigationStack { LibraryFilterView(kind: .genres, value: "Science Fiction") }
}
