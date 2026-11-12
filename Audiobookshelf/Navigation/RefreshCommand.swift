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
    ///
    /// - Parameter owner: The tab whose stack shows the screen (``EnvironmentValues/navigationTab``); it must be
    ///   the selected one, so the same route or section open in a hidden tab's stack never counts. `nil` outside a
    ///   tab's stack.
    @MainActor
    func isFrontmost(in router: Router?, owner: AppTab?, isVisible: Bool) -> Bool {
        guard isVisible else { return false }
        guard let router else { return true }
        let selected = router.selectedTab
        if let owner, owner != selected { return false }
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

/// The frontmost screen's refresh, which View ▸ Refresh (⌘R) runs.
struct RefreshAction {
    /// The screen is loading.
    var isDisabled: Bool
    var perform: @MainActor () -> Void
}

extension EnvironmentValues {
    /// The tab whose `NavigationStack` shows the view (set by `MainTabView`); `nil` outside a tab's stack.
    @Entry var navigationTab: AppTab?
}

extension FocusedValues {
    /// The focused scene's frontmost refresh (``RefreshCommandRegistry/frontmost(in:)``), if any.
    @Entry var refreshAction: RefreshAction?
}

/// One scene's screens with a Refresh command, registered while visible (`onAppear` to `onDisappear`, which a
/// covered stack screen or, on iPad, a hidden tab never reaches). ``frontmost(in:)`` picks the one whose placement
/// tops the selected tab's stack, so a hidden tab that stays registered (macOS keeps it appeared) never gets ⌘R.
@MainActor
@Observable
final class RefreshCommandRegistry {
    struct Entry {
        var placement: RefreshCommandPlacement
        /// The tab whose stack shows the screen (``EnvironmentValues/navigationTab``).
        var owner: AppTab?
        var isDisabled: Bool
        var perform: @MainActor () -> Void
    }

    /// In registration order; the last of several frontmost entries wins.
    private(set) var entries: [(id: UUID, entry: Entry)] = []

    /// Adds the screen `id`, or updates it in place.
    func register(_ id: UUID, _ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].entry = entry
        } else {
            entries.append((id, entry))
        }
    }

    func unregister(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// The refresh of the last registered screen that is frontmost in `router`, or `nil` when none is.
    func frontmost(in router: Router?) -> RefreshAction? {
        entries.last { $0.entry.placement.isFrontmost(in: router, owner: $0.entry.owner, isVisible: true) }
            .map { RefreshAction(isDisabled: $0.entry.isDisabled, perform: $0.entry.perform) }
    }
}

/// View ▸ Refresh (⌘R), on a Mac and in the iPad hardware keyboard's ⌘ overlay: runs the focused scene's frontmost
/// screen's refresh (``FocusedValues/refreshAction``). Disabled while that screen loads, or when no screen has one.
struct RefreshCommands: Commands {
    @FocusedValue(\.refreshAction) private var action: RefreshAction?

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button {
                action?.perform()
            } label: {
                Text(verbatim: L10n.string("ButtonRefresh"))
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(action?.isDisabled ?? true)
        }
    }
}

extension View {
    /// Registers the screen at `placement` for View ▸ Refresh (⌘R) while it is visible and, on macOS (no pull to
    /// refresh), shows a Refresh toolbar button while it is frontmost.
    func refreshCommand(
        _ placement: RefreshCommandPlacement, isDisabled: Bool, refresh: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(RefreshCommand(placement: placement, isDisabled: isDisabled, refresh: refresh))
    }

    /// Publishes the scene's frontmost refresh from `registry` for ``RefreshCommands``, and gives `registry` to
    /// the screens.
    func refreshCommands(_ registry: RefreshCommandRegistry, router: Router) -> some View {
        modifier(RefreshCommandPublisher(registry: registry, router: router))
    }
}

private struct RefreshCommandPublisher: ViewModifier {
    let registry: RefreshCommandRegistry
    let router: Router

    func body(content: Content) -> some View {
        content
            .environment(registry)
            .focusedSceneValue(\.refreshAction, registry.frontmost(in: router))
    }
}

private struct RefreshCommand: ViewModifier {
    let placement: RefreshCommandPlacement
    let isDisabled: Bool
    let refresh: @MainActor () -> Void
    @Environment(Router.self) private var router: Router?
    @Environment(\.navigationTab) private var owner
    @Environment(RefreshCommandRegistry.self) private var registry: RefreshCommandRegistry?
    @State private var id = UUID()
    /// The latest `refresh`, so the registered action never runs an older screen's closure.
    @State private var latest = LatestRefresh()
    /// Between `onAppear` and `onDisappear`, which a covered stack screen or hidden tab isn't.
    @State private var isVisible = false

    func body(content: Content) -> some View {
        latest.perform = refresh
        return
            content
            .onAppear {
                isVisible = true
                register()
            }
            .onDisappear {
                isVisible = false
                registry?.unregister(id)
            }
            .onChange(of: placement) { if isVisible { register() } }
            .onChange(of: isDisabled) { if isVisible { register() } }
            .onChange(of: owner) { if isVisible { register() } }
            #if os(macOS)
                .toolbar {
                    if placement.isFrontmost(in: router, owner: owner, isVisible: isVisible) {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: refresh) {
                                Label {
                                    Text(verbatim: L10n.string("ButtonRefresh"))
                                } icon: {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(isDisabled)
                        }
                    }
                }
            #endif
    }

    private func register() {
        let latest = latest
        registry?.register(
            id, .init(placement: placement, owner: owner, isDisabled: isDisabled, perform: { latest.perform() }))
    }
}

/// Holds a screen's newest refresh closure; not observed.
@MainActor
private final class LatestRefresh {
    var perform: @MainActor () -> Void = {}
}
