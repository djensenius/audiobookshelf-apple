import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The form for a new bookmark or an existing one's title (legacy `BookmarksModal.vue`'s title
/// input), pushed onto the bookmarks sheet: the bookmark's time at the rate, a note field and
/// Create or Update. For a new bookmark the placeholder is the title an empty field gets (D9); for
/// an existing one it's the current title, which an empty field keeps.
struct BookmarkEditor: View {
    let target: BookmarkEditorTarget
    let rate: Double
    let placeholder: String
    /// Saves the field's text; the sheet pops the form and reports any failure.
    let submit: (String) -> Void
    @Environment(\.locale) private var locale
    @State private var title: String
    @FocusState private var isFocused: Bool

    init(target: BookmarkEditorTarget, rate: Double, placeholder: String, submit: @escaping (String) -> Void) {
        self.target = target
        self.rate = rate
        self.placeholder = placeholder
        self.submit = submit
        _title = State(initialValue: BookmarkEditorPresentation(target: target).initialTitle)
    }

    var body: some View {
        let presentation = BookmarkEditorPresentation(target: target)
        Form {
            Section {
                LabeledContent {
                    Text(verbatim: BookmarkTimePresentation.text(presentation.time, rate: rate, locale: locale))
                        .monospacedDigit()
                } label: {
                    Text(verbatim: L10n.string("LabelBookmarkTime"))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: L10n.string("LabelBookmarkTime")))
                .accessibilityValue(
                    Text(
                        verbatim: BookmarkTimePresentation.accessibilityText(
                            presentation.time, rate: rate, locale: locale)))
                TextField(text: $title, prompt: Text(verbatim: placeholder)) {
                    Text(verbatim: L10n.string("LabelBookmarkNote"))
                }
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit { submit(title) }
                .accessibilityLabel(Text(verbatim: L10n.string("LabelBookmarkNote")))
            } header: {
                Text(verbatim: L10n.string("LabelBookmarkNote"))
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(presentation.titleKey)))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    submit(title)
                } label: {
                    Text(verbatim: L10n.string(presentation.submitKey))
                }
            }
        }
        .onAppear { isFocused = true }
    }
}

/// The editor's text for its target.
struct BookmarkEditorPresentation: Equatable {
    /// The navigation title's key: New Bookmark or Edit Bookmark.
    let titleKey: String
    /// The submit button's key: Create or Update.
    let submitKey: String
    /// What the field starts with: empty for a new bookmark, the title for an existing one.
    let initialTitle: String
    /// The bookmark's time, in media seconds.
    let time: Double

    init(target: BookmarkEditorTarget) {
        switch target {
        case .create(let time):
            titleKey = "HeaderNewBookmark"
            submitKey = "ButtonCreate"
            initialTitle = ""
            self.time = time
        case .edit(let bookmark):
            titleKey = "HeaderEditBookmark"
            submitKey = "ButtonUpdate"
            initialTitle = bookmark.title
            time = bookmark.time
        }
    }
}

#Preview("New") {
    NavigationStack {
        BookmarkEditor(target: .create(time: 4_000), rate: 1, placeholder: "Nov 12, 2026 at 9:41 AM") { _ in }
    }
}

#Preview("Edit, accessibility size") {
    NavigationStack {
        BookmarkEditor(
            target: .edit(AudioBookmark(libraryItemId: "li_preview", title: "The spice must flow", time: 4_000)),
            rate: 1.5, placeholder: "The spice must flow"
        ) { _ in }
    }
    .dynamicTypeSize(.accessibility3)
}
