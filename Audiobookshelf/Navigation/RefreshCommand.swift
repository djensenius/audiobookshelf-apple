import ABSAppModel
import ABSUI
import SwiftUI

/// Where a screen with a Refresh command sits in the scene's navigation. Only a visible screen on
/// top of the selected tab's stack gets ⌘R: visibility rules out copies of a placement in a covered
/// stack screen or a hidden tab, so a window has one ⌘R unless two visible screens share one.
enum RefreshCommandPlacement: Hashable {
    /// The root screen of a tab.
    case root(AppTab)
    /// A screen pushed for the route.
    case pushed(Route)

    /// Whether the screen is visible and tops the selected tab's stack; without a router (previews), if visible.
    @MainActor
    func isFrontmost(in router: Router?, isVisible: Bool) -> Bool {
        guard isVisible else { return false }
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
    /// On macOS (no pull to refresh), a Refresh toolbar button (⌘R) while the screen at `placement` is frontmost.
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
        /// Between `onAppear` and `onDisappear`, which a covered stack screen or hidden tab isn't.
        @State private var isVisible = false

        func body(content: Content) -> some View {
            content
                .onAppear { isVisible = true }
                .onDisappear { isVisible = false }
                .toolbar {
                    if placement.isFrontmost(in: router, isVisible: isVisible) {
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
