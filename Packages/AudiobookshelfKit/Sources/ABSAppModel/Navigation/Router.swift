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
    /// A library a deep link asked for, until the scene resolves it. A link carries only the
    /// ID, so the scene (S7a) looks up the library's kind and sections and calls
    /// ``selectLibrary(id:kind:supportedSections:)``, which clears this.
    ///
    /// Other pending requests, such as ``pendingPlayLink``, must also be stored properties
    /// declared here: extensions can't add stored properties.
    public private(set) var pendingLibraryID: String?
    /// A `play/` link opened in this scene, until the item screen shows its confirmation
    /// (``PlayLinkDecision``) and clears it. Every link ``open(_:)`` navigates to replaces it;
    /// a link for another server doesn't. A library switch that resets paths, a snapshot
    /// restore and an identity change clear it, because the item is no longer on screen.
    public var pendingPlayLink: PlayLink?
    /// A `search?q=` query opened in this scene, until the Search tab shows it and clears it.
    /// Cleared like ``pendingPlayLink``, except that a library switch keeps it.
    public var pendingSearchQuery: String?
    /// A link for another server connection, waiting for the user to confirm the switch. The
    /// UI that asks (S6) clears it, and must keep its own copy to reopen after the switch,
    /// because ``resetForIdentityChange(serverID:userID:)`` clears it too.
    public var pendingServerSwitch: DeepLink?
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
    /// `horizontalSizeClass == .compact` when it appears, after restoring a snapshot and
    /// whenever the size class changes: a snapshot saved in regular width can select a
    /// section tab that compact width doesn't show.
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

    /// Asks the scene to switch to library `id`, for a deep link that knows only the ID.
    /// Sets ``pendingLibraryID``; nothing else changes until the scene resolves it.
    public func requestLibrary(id: String) {
        pendingLibraryID = id
    }

    /// Shows library `id` in this scene.
    ///
    /// Switching from another library resets the library-scoped paths (Home, Library, Search
    /// and the sections) and keeps Downloads and Account. The first library a scene gets
    /// (when ``libraryID`` is `nil`) keeps them. Either way, a selected tab or Library section
    /// that isn't in `supportedSections` falls back to Library or the default grid, and the
    /// paths of unsupported sections are cleared, which repairs the selection after a book ↔
    /// podcast switch or a permission change. Clears a matching ``pendingLibraryID``, and
    /// clears ``pendingPlayLink`` when the paths are reset: `open(_:)` pushes the item only
    /// onto Library, which the reset empties.
    ///
    /// - Parameter supportedSections: the sections the library shows for this user, usually
    ///   ``AppTab/sections(for:canAddPodcast:hasPlaylists:)``.
    public func selectLibrary(id: String, kind: LibraryKind?, supportedSections: Set<AppTab>) {
        if let current = libraryID, id != current {
            for tab in AppTab.allCases where tab.isLibraryScoped {
                self[path: tab] = []
            }
            pendingPlayLink = nil
        }
        libraryID = id
        libraryKind = kind
        if pendingLibraryID == id { pendingLibraryID = nil }
        repairSections(supported: supportedSections)
    }

    /// Starts over for another server or user: every path, the library and the presentation
    /// state go back to their defaults, and any pending request is dropped.
    ///
    /// It takes the new server and user IDs because the router's identity decides which
    /// snapshots it accepts; without them, every later snapshot would be discarded.
    public func resetForIdentityChange(serverID: String?, userID: String?) {
        self.serverID = serverID
        self.userID = userID
        resetNavigation()
        pendingLibraryID = nil
        pendingServerSwitch = nil
        isFullPlayerPresented = false
        isQueueInspectorPresented = false
    }

    /// Drops a library request, because a later link navigated elsewhere.
    func cancelLibraryRequest() {
        pendingLibraryID = nil
    }

    /// Returns the tab, library, section and paths to their defaults, and drops the pending
    /// play link and search query, which belonged to the old paths. Snapshot restore uses it
    /// too, so a link opened before the restore leaves nothing stale behind.
    func resetNavigation() {
        pendingPlayLink = nil
        pendingSearchQuery = nil
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

    /// Falls back from unsupported sections: the selected tab to Library, the Library section
    /// to the default grid (dropping the Library path, which came from that section), and
    /// clears the paths of unsupported section tabs.
    func repairSections(supported: Set<AppTab>) {
        if selectedTab.isSection, !supported.contains(selectedTab) {
            selectedTab = .library
        }
        if let section = librarySection, !section.isSection || !supported.contains(section) {
            librarySection = nil
            self[path: .library] = []
        }
        for tab in AppTab.sections where !supported.contains(tab) {
            self[path: tab] = []
        }
    }
}
