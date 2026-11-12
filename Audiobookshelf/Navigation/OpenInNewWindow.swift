import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The screen this scene's window was opened for (``WindowRoute``), or `nil` for an ordinary
    /// window. ``SceneRouterHost`` starts a new window there, then clears it, so the window is an
    /// ordinary one from then on and its own saved state restores it.
    @Entry var windowRoute: Binding<WindowRoute?> = .constant(nil)
}

/// Open in New Window (ADR 0004, #83): opens an item, series, author, collection or playlist in a
/// new window of the app's `WindowGroup`, with its own router and the shared player. Offered only
/// where the device has windows (`supportsMultipleWindows`: iPad and Mac, not iPhone).
enum OpenInNewWindow {
    /// Opens `route` in a new window, in the account and library of `router`'s scene; does nothing
    /// without a router or for a route that doesn't open in one (``WindowRoute/opensInNewWindow(_:)``).
    @MainActor
    static func open(_ route: Route, from router: Router?, with openWindow: OpenWindowAction) {
        guard let router, let window = WindowRoute(route, from: router) else { return }
        openWindow(value: window)
    }
}

extension View {
    /// Adds Open in New Window for `route` as a context menu and a VoiceOver action, for the cards
    /// and rows that have no other menu. Adds nothing on iPhone, or for a route that doesn't open in
    /// a window of its own.
    func openInNewWindowMenu(_ route: Route) -> some View {
        modifier(OpenInNewWindowMenu(route: route))
    }
}

private struct OpenInNewWindowMenu: ViewModifier {
    let route: Route
    @Environment(Router.self) private var router: Router?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        if supportsMultipleWindows, router != nil, WindowRoute.opensInNewWindow(route) {
            content.itemActions([ItemAction(.openInNewWindow)]) { _ in
                OpenInNewWindow.open(route, from: router, with: openWindow)
            }
        } else {
            content
        }
    }
}
