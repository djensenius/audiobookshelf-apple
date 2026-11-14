import ABSAppModel
import ABSUI
import SwiftUI

/// The Library root's section menu in a compact tab's toolbar, where the sidebar's Browse
/// section isn't shown (ADR 0004): the grid, then ``Router/visibleSections`` in sidebar order,
/// as legacy `BookshelfNavBar.vue` lists them. Choosing one sets ``Router/librarySection``,
/// which the Library root (``TabRoot``) shows. It's on the root only, where the Library path is
/// empty, so nothing else changes.
///
/// It has the bar's default priority, below the Library screen's filter and sort (#85), so a
/// crowded bar (a vertical one on an iPhone Duo's outer display) moves it, titled with the section
/// shown, into the overflow menu, as it does the library picker.
struct LibrarySectionToolbar: ToolbarContent {
    let router: Router

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            LibrarySectionPicker(router: router)
        }
    }
}

/// A menu of the Library root's sections, labelled with the one shown. SwiftUI doesn't give its
/// entries accessibility identifiers, so UI tests find them by symbol (``AppTab/systemImage``).
private struct LibrarySectionPicker: View {
    @Bindable var router: Router

    var body: some View {
        let current = router.librarySection ?? .library
        Menu {
            Picker(selection: $router.librarySection) {
                LibrarySectionLabel.label(.library).tag(AppTab?.none)
                ForEach(router.visibleSections, id: \.self) { section in
                    LibrarySectionLabel.label(section).tag(Optional(section))
                }
            } label: {
                Text(verbatim: L10n.string("HeaderBrowse"))
            }
            .pickerStyle(.inline)
        } label: {
            LibrarySectionLabel(section: current)
        }
        .accessibilityShowsLargeContentViewer {
            LibrarySectionLabel.label(current)
        }
        .accessibilityLabel(Text(verbatim: L10n.string("HeaderBrowse")))
        .accessibilityValue(Text(verbatim: L10n.string(current.titleKey)))
        // For UI tests.
        .accessibilityIdentifier("library.sectionPicker")
    }
}

/// The menu's label: the section's symbol and title. A bar shows a `Label` as its symbol alone
/// and drops the menu's accessibility value, so a horizontal bar gets a stack instead; a vertical
/// bar has room for the symbol only, and titles the entry itself in its overflow menu.
private struct LibrarySectionLabel: View {
    let section: AppTab

    var body: some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                VerticalBarAware(section: section)
            } else {
                Self.titled(section)
            }
        #else
            Self.titled(section)
        #endif
    }

    /// The section's title and symbol, as its tab and sidebar row show them.
    static func label(_ section: AppTab) -> some View {
        Label {
            Text(verbatim: L10n.string(section.titleKey))
        } icon: {
            Image(systemName: section.systemImage)
        }
    }

    static func titled(_ section: AppTab) -> some View {
        HStack(spacing: 6) {
            Image(systemName: section.systemImage)
            Text(verbatim: L10n.string(section.titleKey))
        }
    }

    #if os(iOS)
        @available(iOS 27.1, *)
        private struct VerticalBarAware: View {
            let section: AppTab
            @Environment(\.toolbarVerticalEdge) private var verticalEdge

            var body: some View {
                if verticalEdge != nil {
                    LibrarySectionLabel.label(section)
                } else {
                    LibrarySectionLabel.titled(section)
                }
            }
        }
    #endif
}
