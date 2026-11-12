import Foundation

/// An item of the Go menu (ADR 0004), which the app runs on the focused scene's ``Router``: ⌘1 to ⌘5
/// select the tabs every library has, and ⌘[ goes back. The rules live here, so they are testable.
///
/// The library's sections (Series, Latest and the rest) aren't listed: ADR 0004's Go menu has only
/// the five tabs and Back, and compact width shows sections inside Library rather than as tabs.
public enum GoCommand: Hashable, CaseIterable, Sendable {
    case home, library, search, downloads, account
    /// Pops the selected tab's top screen (``Router/goBack()``).
    case back

    /// The tab commands in menu order, which is also the order of their shortcuts (⌘1 to ⌘5).
    public static let tabs: [GoCommand] = [.home, .library, .search, .downloads, .account]

    /// The tab the command selects; `nil` for ``back``.
    public var tab: AppTab? {
        switch self {
        case .home: .home
        case .library: .library
        case .search: .search
        case .downloads: .downloads
        case .account: .account
        case .back: nil
        }
    }

    /// Whether the command is enabled for `router`, the focused scene's router. That is `nil` when
    /// no signed-in scene is focused (signed out, or no window), and then no command is enabled.
    /// A scene can always select a tab; Back needs a screen to pop (``Router/canGoBack``).
    @MainActor
    public func isEnabled(in router: Router?) -> Bool {
        guard let router else { return false }
        return tab != nil || router.canGoBack
    }

    /// Runs the command in `router`; does nothing without one or when it isn't enabled there.
    @MainActor
    public func perform(in router: Router?) {
        guard let router else { return }
        if let tab {
            router.select(tab: tab)
        } else {
            router.goBack()
        }
    }
}

extension Router {
    /// Selects `tab` for the Go menu, keeping its path, as the sidebar and tab bar do. Like
    /// ``open(_:)``, it dismisses the full player, which would cover the tab.
    ///
    /// Only the tabs every library has can be selected this way. A section is ignored: compact width
    /// has no section tabs (``normalize(isCompact:)``), and the library may not have it.
    public func select(tab: AppTab) {
        guard !tab.isSection else { return }
        isFullPlayerPresented = false
        selectedTab = tab
    }

    /// Whether Back has a screen to pop: the selected tab's stack isn't at its root.
    public var canGoBack: Bool {
        !self[path: selectedTab].isEmpty
    }

    /// Pops the top screen of the selected tab's stack, like the stack's back button, and dismisses
    /// the full player, which would cover the screen it goes back to. Does nothing at the root.
    public func goBack() {
        guard canGoBack else { return }
        isFullPlayerPresented = false
        self[path: selectedTab].removeLast()
    }
}
