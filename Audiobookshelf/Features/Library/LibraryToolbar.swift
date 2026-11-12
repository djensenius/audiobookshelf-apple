import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Library screen's controls (legacy `BookshelfToolbar.vue`): view options (grid or list, and Collapse Series for
/// book libraries), the filter sheet, and the sort menu. Every change is saved for the library and account through
/// the model.
struct LibraryToolbar: ToolbarContent {
    let model: LibraryItemsModel
    /// The filter sheet's choices; without it there is no filter button.
    let filterModel: LibraryFilterModel?
    @Binding var showsFilter: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            LibraryViewOptionsMenu(model: model)
            if let filterModel {
                filterButton(choices: filterModel.choices)
            }
            LibrarySortMenu(
                mediaType: model.mediaType, preferences: model.preferences,
                select: { LibraryPresentation.selectSort($0, in: model) },
                setDescending: { descending in model.update { $0.descending = descending } })
        }
    }

    private func filterButton(choices: LibraryFilterModel.Choices?) -> some View {
        let title = L10n.string("HeaderLibraryFilter")
        let filter = model.preferences.filter
        return Button {
            showsFilter = true
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(
                    systemName: filter == nil
                        ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        // A screen pinned to one filter (a narrator's, say) can't change it.
        .disabled(model.pinnedFilter != nil)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: LibraryPresentation.filterSummary(filter, choices: choices)))
    }
}

/// Grid or list, and Collapse Series for book libraries.
private struct LibraryViewOptionsMenu: View {
    let model: LibraryItemsModel

    var body: some View {
        let preferences = model.preferences
        let title = L10n.string("LabelLibraryViewOptions")
        let showsCollapse = LibraryPresentation.showsCollapseSeries(for: model.mediaType)
        let collapseTitle = L10n.string("LabelCollapseSeries")
        let viewTitle = L10n.string(LibraryPresentation.titleKey(for: preferences.viewMode))
        Menu {
            Picker(
                selection: Binding(
                    get: { preferences.viewMode },
                    set: { mode in model.update { $0.viewMode = mode } })
            ) {
                ForEach(LibraryPresentation.viewModes, id: \.self) { mode in
                    Label {
                        Text(verbatim: L10n.string(LibraryPresentation.titleKey(for: mode)))
                    } icon: {
                        Image(systemName: LibraryPresentation.symbol(for: mode))
                    }
                    .tag(mode)
                }
            } label: {
                Text(verbatim: title)
            }
            .pickerStyle(.inline)
            if showsCollapse {
                Toggle(
                    isOn: Binding(
                        get: { preferences.collapseSeries },
                        set: { collapse in model.update { $0.collapseSeries = collapse } })
                ) {
                    Label {
                        Text(verbatim: collapseTitle)
                    } icon: {
                        Image(systemName: "square.stack")
                    }
                }
            }
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: LibraryPresentation.symbol(for: preferences.viewMode))
            }
        }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(
            Text(
                verbatim: ([viewTitle] + (showsCollapse && preferences.collapseSeries ? [collapseTitle] : []))
                    .joined(separator: ", ")))
    }
}
