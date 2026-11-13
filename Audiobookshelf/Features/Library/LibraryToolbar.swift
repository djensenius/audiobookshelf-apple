import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Library screen's controls (legacy `BookshelfToolbar.vue`): view options (grid or list, and Collapse Series for
/// book libraries), the filter sheet, and the sort menu. Every change is saved for the library and account through
/// the model.
///
/// Filter and sort have high visibility priority, so a crowded bar keeps them longest (#85). In a vertical bar (an
/// iPhone Duo's outer display, from iOS 27.1) they prefer the bar and the view options move to the overflow menu,
/// as the player's rarely used actions do (#84); elsewhere the bar is as before.
struct LibraryToolbar: ToolbarContent {
    let model: LibraryItemsModel
    /// The filter sheet's choices; without it there is no filter button.
    let filterModel: LibraryFilterModel?
    @Binding var showsFilter: Bool
    /// The screen is visible and tops the selected tab's stack (``RefreshCommandPlacement/isFrontmost(in:isVisible:)``),
    /// so a hidden tab or covered screen never takes ⌥⌘F.
    let isFrontmost: Bool

    var body: some ToolbarContent {
        let viewOptions = LibraryViewOptionsMenu(model: model)
        #if os(iOS)
            if #available(iOS 27.1, *) {
                LibraryVerticalBarToolbar(viewOptions: viewOptions, controls: controls)
            } else {
                LibraryToolbarItems(viewOptions: viewOptions, controls: controls)
            }
        #else
            LibraryToolbarItems(viewOptions: viewOptions, controls: controls)
        #endif
    }

    /// The filter button and the sort menu.
    @ViewBuilder private var controls: some View {
        if let filterModel {
            filterButton(choices: filterModel.choices)
        }
        LibrarySortMenu(
            mediaType: model.mediaType, preferences: model.preferences,
            select: { LibraryPresentation.selectSort($0, in: model) },
            setDescending: { descending in model.update { $0.descending = descending } })
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
        .keyboardShortcut(isFrontmost ? KeyboardShortcut("f", modifiers: [.command, .option]) : nil)
        // A screen pinned to one filter (a narrator's, say) can't change it.
        .disabled(model.pinnedFilter != nil)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: LibraryPresentation.filterSummary(filter, choices: choices)))
    }
}

/// The Library toolbar's items in a horizontal bar, in their usual order: the view options, then the filter and
/// sort, which a crowded bar keeps longest.
private struct LibraryToolbarItems<Controls: View>: ToolbarContent {
    let viewOptions: LibraryViewOptionsMenu
    let controls: Controls

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            viewOptions
        }
        ToolbarItemGroup(placement: .primaryAction) {
            controls
        }
        .visibilityPriority(.high)
    }
}

#if os(iOS)
    /// The Library toolbar from iOS 27.1: in a vertical bar, the filter and sort prefer the bar (the sort is a menu,
    /// which would otherwise stay horizontal) and the view options sit in the overflow menu; otherwise the usual
    /// items (``LibraryToolbarItems``).
    @available(iOS 27.1, *)
    private struct LibraryVerticalBarToolbar<Controls: View>: ToolbarContent {
        let viewOptions: LibraryViewOptionsMenu
        let controls: Controls
        @Environment(\.toolbarVerticalEdge) private var verticalEdge

        var body: some ToolbarContent {
            if verticalEdge != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    controls
                }
                .visibilityPriority(.high)
                .axisBehavior(.verticalPreferred)
                ToolbarOverflowMenu {
                    viewOptions
                }
            } else {
                LibraryToolbarItems(viewOptions: viewOptions, controls: controls)
            }
        }
    }
#endif

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
                // The server ignores collapsing while filtering by series.
                .disabled(LibraryPresentation.isCollapseSeriesDisabled(preferences))
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
