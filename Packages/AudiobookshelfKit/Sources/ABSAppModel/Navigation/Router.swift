import Foundation
import Observation

/// One window scene's navigation and presentation state (ADR 0004).
///
/// Each scene owns its own router: its tab, current library, per-tab paths and whether the
/// full player or queue inspector is shown there. Shared state (session, library data,
/// playback) lives in `AppEnvironment`, so one window or CarPlay never navigates or presents
/// in another. The router is plain data with no SwiftUI, so every rule is testable.
@MainActor
@Observable
public final class Router {
    /// The server connection this scene's navigation belongs to. Snapshots of another server
    /// are discarded.
    public private(set) var serverID: String?
    /// The user this scene's navigation belongs to. Snapshots of another user are discarded.
    public private(set) var userID: String?

    public var selectedTab: AppTab = .home
    /// The library this scene shows. Library-scoped paths reset when it changes.
    public private(set) var libraryID: String?
    /// The kind of ``libraryID``, which decides the sections a restored scene may show.
    public private(set) var libraryKind: LibraryKind?
    /// The Library root's selected section; `nil` is the default grid. In compact width this
    /// replaces the sidebar-only section tabs.
    public var librarySection: AppTab?
    /// One typed path per tab. Bind stacks through ``subscript(path:)``.
    public private(set) var paths: [AppTab: [Route]] = [:]

    /// Whether this scene shows the full player. Never stored in a ``Snapshot``: after a
    /// relaunch the player comes back as the mini player.
    public var isFullPlayerPresented = false
    /// Whether this scene shows the queue inspector.
    public var isQueueInspectorPresented = false

    public init(serverID: String? = nil, userID: String? = nil) {
        self.serverID = serverID
        self.userID = userID
    }

    /// A tab's path; empty when the tab is at its root. `NavigationStack(path:)` binds to
    /// `$router[path: tab]`, because `$router.paths[tab, default: []]` isn't a valid key path.
    public subscript(path tab: AppTab) -> [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue.isEmpty ? nil : newValue }
    }

    /// Adapts the selection to the size class. The view calls this with
    /// `horizontalSizeClass == .compact` whenever the size class changes.
    ///
    /// Compact width has no section tabs, so a selected section moves into Library: it
    /// becomes ``librarySection`` and its path replaces Library's (the old Library path wasn't
    /// visible), so the visible screen and Back stay the same. Nothing moves back when the
    /// width becomes regular again.
    public func normalize(isCompact: Bool) {
        guard isCompact, selectedTab.isSection else { return }
        let section = selectedTab
        librarySection = section
        self[path: .library] = self[path: section]
        self[path: section] = []
        selectedTab = .library
    }

    /// Shows library `id` in this scene.
    ///
    /// Switching to another library resets the library-scoped paths (Home, Library, Search
    /// and the sections) and keeps Downloads and Account. Either way, a selected tab or
    /// Library section that isn't in `supportedSections` falls back to Library or the default
    /// grid, which repairs the selection after a book ↔ podcast switch.
    ///
    /// - Parameter supportedSections: the sections the library shows for this user, usually
    ///   ``AppTab/sections(for:canAddPodcast:hasPlaylists:)``.
    public func selectLibrary(id: String, mediaType: LibraryKind?, supportedSections: Set<AppTab>) {
        if id != libraryID {
            for tab in AppTab.allCases where tab.isLibraryScoped {
                self[path: tab] = []
            }
        }
        libraryID = id
        libraryKind = mediaType
        repairSections(supported: supportedSections)
    }

    /// Starts over for another server or user: every path, the library and the presentation
    /// state go back to their defaults.
    public func resetForIdentityChange(serverID: String?, userID: String?) {
        self.serverID = serverID
        self.userID = userID
        resetNavigation()
        isFullPlayerPresented = false
        isQueueInspectorPresented = false
    }

    /// Returns the tab, library, section and paths to their defaults.
    func resetNavigation() {
        selectedTab = .home
        libraryID = nil
        libraryKind = nil
        librarySection = nil
        paths = [:]
    }

    /// Restores the library and its kind without resetting paths; used by snapshot restore.
    func restoreLibrary(id: String?, kind: LibraryKind?) {
        libraryID = id
        libraryKind = kind
    }

    func repairSections(supported: Set<AppTab>) {
        if selectedTab.isSection, !supported.contains(selectedTab) {
            selectedTab = .library
        }
        if let section = librarySection, !section.isSection || !supported.contains(section) {
            librarySection = nil
        }
    }
}
