import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Library screen's sort menu (legacy `OrderModal.vue`): the library type's sorts, the selected one checked with
/// its direction arrow, and the direction. Choosing the selected sort flips the direction; another sort sets it.
struct LibrarySortMenu: View {
    let mediaType: MediaType
    let preferences: LibraryViewPreferences
    let select: (LibrarySortKey) -> Void
    let setDescending: (Bool) -> Void

    var body: some View {
        let options = LibraryPresentation.sortOptions(for: mediaType, preferences: preferences)
        let title = L10n.string("HeaderLibrarySort")
        let sortTitle = L10n.string(LibraryPresentation.titleKey(for: preferences.sort))
        let direction = L10n.string(LibraryPresentation.directionKey(descending: preferences.descending))
        Menu {
            Section {
                ForEach(options) { option in
                    // A toggle shows the checkmark and tells VoiceOver which sort is selected; turning the selected
                    // one "off" chooses it again, which flips the direction.
                    Toggle(isOn: Binding(get: { option.isSelected }, set: { _ in select(option.key) })) {
                        Label {
                            Text(verbatim: L10n.string(option.titleKey))
                        } icon: {
                            if let arrow = option.arrowSymbol { Image(systemName: arrow) }
                        }
                    }
                }
            } header: {
                Text(verbatim: title)
            }
            Picker(selection: Binding(get: { preferences.descending }, set: setDescending)) {
                ForEach([false, true], id: \.self) { descending in
                    Label {
                        Text(verbatim: L10n.string(LibraryPresentation.directionKey(descending: descending)))
                    } icon: {
                        Image(systemName: LibraryPresentation.arrowSymbol(descending: descending))
                    }
                    .tag(descending)
                }
            } label: {
                Text(verbatim: title)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: [sortTitle, direction].joined(separator: ", ")))
    }
}

#Preview("Books") {
    @Previewable @State var preferences = LibraryViewPreferences()
    NavigationStack {
        Text(verbatim: L10n.string(LibraryPresentation.titleKey(for: preferences.sort)))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySortMenu(
                        mediaType: .book, preferences: preferences, select: { preferences.selectSort($0) },
                        setDescending: { preferences.descending = $0 })
                }
            }
    }
}

#Preview("Podcasts") {
    @Previewable @State var preferences = LibraryViewPreferences(sort: .title, descending: false)
    NavigationStack {
        Text(verbatim: L10n.string(LibraryPresentation.titleKey(for: preferences.sort)))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySortMenu(
                        mediaType: .podcast, preferences: preferences, select: { preferences.selectSort($0) },
                        setDescending: { preferences.descending = $0 })
                }
            }
    }
}
