import ABSAppModel
import ABSUI
import SwiftUI

/// Where a screen with a Refresh command sits in the scene's navigation. Only the screen the
/// window shows, the top of the selected tab's stack, gets ⌘R, so a window has one.
enum RefreshCommandPlacement: Hashable {
    /// The root screen of a tab.
    case root(AppTab)
    /// A screen pushed for the route.
    case pushed(Route)

    /// Whether the screen is on top of the selected tab's stack; `true` without a router
    /// (previews).
    @MainActor
    func isFrontmost(in router: Router?) -> Bool {
        guard let router else { return true }
        let selected = router.selectedTab
        let path = router[path: selected]
        switch self {
        case .root(let tab):
            // The Library tab shows a selected section as its root (`TabRoot`).
            return path.isEmpty && (tab == selected || selected == .library && router.librarySection == tab)
        case .pushed(let route):
            return path.last == route
        }
    }
}

extension View {
    /// On macOS, a Refresh toolbar button (⌘R) while the screen at `placement` is frontmost, for
    /// screens without pull to refresh.
    func refreshCommand(
        _ placement: RefreshCommandPlacement, isDisabled: Bool, refresh: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
            modifier(RefreshCommand(placement: placement, isDisabled: isDisabled, refresh: refresh))
        #else
            self
        #endif
    }
}

#if os(macOS)
    private struct RefreshCommand: ViewModifier {
        let placement: RefreshCommandPlacement
        let isDisabled: Bool
        let refresh: () -> Void
        @Environment(Router.self) private var router: Router?

        func body(content: Content) -> some View {
            content.toolbar {
                if placement.isFrontmost(in: router) {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: refresh) {
                            Label {
                                Text(verbatim: L10n.string("ButtonRefresh"))
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(isDisabled)
                    }
                }
            }
        }
    }
#endif
