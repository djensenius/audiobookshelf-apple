import ABSAppModel
import ABSUI
import SwiftUI

/// The toolbar's bookmarks button; disabled until the bookmarks sheet (P2-57d) replaces this file.
struct BookmarksSlot: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?

    var body: some View {
        Button {
            sheet = .bookmarks
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelYourBookmarks"))
            } icon: {
                Image(systemName: "bookmark")
            }
        }
        .disabled(true)
    }
}

/// The bookmarks sheet; a placeholder until P2-57d.
struct BookmarksSheet: View {
    let model: PlayerViewModel
    let close: () -> Void

    var body: some View {
        PlayerSheetPlaceholder(titleKey: "LabelYourBookmarks", systemImage: "bookmark", close: close)
    }
}

#Preview("Sheet") {
    BookmarksSheet(model: .preview(), close: {})
}

#Preview("Sheet, accessibility size") {
    BookmarksSheet(model: .preview(), close: {})
        .dynamicTypeSize(.accessibility3)
}
