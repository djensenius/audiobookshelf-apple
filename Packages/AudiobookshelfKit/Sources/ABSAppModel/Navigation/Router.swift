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
    /// The sections ``libraryID`` shows for this user, as the scene last confirmed them in
    /// ``selectLibrary(id:kind:supportedSections:)``. A restored scene assumes every section of
    /// the library's kind until then, or every section when its kind is unknown.
    public private(set) var supportedSections: Set<AppTab> = []
    /// Sections hidden on top of ``supportedSections`` before the library is checked, such as
    /// Add podcast from a user known not to be allowed it; see ``withholdSections(_:)``.
    public private(set) var withheldSections: Set<AppTab> = []
    /// Whether ``libraryID``, or having none, was checked against the account's loaded
    /// libraries. A restored or guessed library isn't, even with a kind: until it is, the
    /// scene may replace it without resetting the paths opened meanwhile.
    public internal(set) var isLibraryChecked = false
    /// A library a deep link asked for, until the scene resolves it. A link carries only the
    /// ID, so the scene (S7a) looks up the library's kind and sections and calls
    /// ``selectLibrary(id:kind:supportedSections:)``, which clears this.
    ///
    /// Other pending requests, such as ``pendingPlayLink``, must also be stored properties
    /// declared here: extensions can't add stored properties.
    public private(set) var pendingLibraryID: String?
    /// A `play/` link opened in this scene, until the item screen shows its confirmation
    /// (``PlayLinkDecision``) and calls ``clearPendingPlayLink()``. Every link ``open(_:)``
    /// navigates to replaces it; a link for another server doesn't. Any change to the Library
    /// path that drops the exact screen the link opened clears it: a library switch, section
    /// repair, ``normalize(isCompact:)``, popping the screen, snapshot restore or an identity
    /// change. An older screen for the same item lower in the path doesn't keep it.
    public internal(set) var pendingPlayLink: PlayLink?
    /// The Library path up to and including the screen ``pendingPlayLink`` opened. The link
    /// stays pending only while the Library path starts with exactly this.
    private(set) var pendingPlayLinkPath: [Route] = []
    /// A `search?q=` query opened in this scene, until the Search tab shows it and clears it.
    /// Cleared like ``pendingPlayLink``, except that a library switch keeps it.
    public var pendingSearchQuery: String?
    /// A link for another server connection, waiting for the user to confirm the switch. The
    /// UI that asks (S6) clears it, and must keep its own copy to reopen after the switch,
    /// because ``resetForIdentityChange(serverID:userID:)`` clears it too.
    public var pendingServerSwitch: DeepLink?
    /// Search should focus its field (Cmd+F, ``requestSearchFocus()``), until the Search screen
    /// does and calls ``clearSearchFocusRequest()``. A flag rather than a counter, so a Search
    /// screen that appears after the request (the tab was just selected) can tell it is unhandled.
    /// Never stored in a ``Snapshot``.
    public private(set) var isSearchFocusRequested = false
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
    /// It stores exactly what it's given: a stack's top entry must stay the route SwiftUI pushed.
    public subscript(path tab: AppTab) -> [Route] {
        get { paths[tab] ?? [] }
        set {
            paths[tab] = newValue.isEmpty ? nil : newValue
            if tab == .library { dropPendingPlayLinkIfOffPath() }
        }
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

    /// The sections the sidebar shows, in sidebar order: ``supportedSections`` once a library is
    /// selected, and every section before that, so the sidebar is never empty while the scene
    /// has no library yet; either way without ``withheldSections``. A user confirmed to have no
    /// libraries (``isLibraryChecked`` without a library) gets none.
    public var visibleSections: [AppTab] {
        let base =
            libraryID == nil && !isLibraryChecked ? AppTab.sections : AppTab.sections.filter(supportedSections.contains)
        return withheldSections.isEmpty ? base : base.filter { !withheldSections.contains($0) }
    }

    /// Asks the scene to switch to library `id`, for a deep link that knows only the ID.
    /// Sets ``pendingLibraryID``; nothing else changes until the scene resolves it.
    public func requestLibrary(id: String) {
        pendingLibraryID = id
    }

    /// Asks for the search field (Cmd+F): selects Search at its root, where the field is, and
    /// sets ``isSearchFocusRequested`` so the Search screen focuses it, even if it is already shown.
    /// Like ``open(_:)``, it dismisses the full player, which would cover the field.
    public func requestSearchFocus() {
        isFullPlayerPresented = false
        selectedTab = .search
        self[path: .search] = []
        isSearchFocusRequested = true
    }

    /// Drops ``isSearchFocusRequested`` once the Search screen has focused its field.
    public func clearSearchFocusRequest() {
        isSearchFocusRequested = false
    }

    /// Shows library `id` in this scene.
    ///
    /// Switching from another library resets the library-scoped paths (Home, Library, Search
    /// and the sections) and keeps Downloads and Account. The first library a scene gets
    /// (when ``libraryID`` is `nil`) keeps them. Either way, a selected tab or Library section
    /// that isn't in `supportedSections` falls back to Library or the default grid, and the
    /// paths of unsupported sections are cleared, which repairs the selection after a book ↔
    /// podcast switch or a permission change. Clears a matching ``pendingLibraryID``.
    ///
    /// - Parameter supportedSections: the sections the library shows for this user, usually
    ///   ``AppTab/sections(for:canAddPodcast:hasPlaylists:)``.
    public func selectLibrary(id: String, kind: LibraryKind?, supportedSections: Set<AppTab>) {
        if let current = libraryID, id != current {
            for tab in AppTab.allCases where tab.isLibraryScoped {
                self[path: tab] = []
            }
        }
        libraryID = id
        libraryKind = kind
        self.supportedSections = supportedSections
        withheldSections = []
        isLibraryChecked = true
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

    /// Drops ``pendingPlayLink``, for example once the item screen has shown its confirmation.
    public func clearPendingPlayLink() {
        pendingPlayLink = nil
        pendingPlayLinkPath = []
    }

    /// Makes `link` pending for the screen on top of the Library path.
    func setPendingPlayLink(_ link: PlayLink) {
        pendingPlayLink = link
        pendingPlayLinkPath = self[path: .library]
    }

    /// Drops a library request, because a later link navigated elsewhere.
    func cancelLibraryRequest() {
        pendingLibraryID = nil
    }

    /// Returns the tab, library, section and paths to their defaults, and drops the pending
    /// play link and search query, which belonged to the old paths. Snapshot restore uses it
    /// too, so a link opened before the restore leaves nothing stale behind.
    func resetNavigation() {
        clearPendingPlayLink()
        pendingSearchQuery = nil
        isSearchFocusRequested = false
        selectedTab = .home
        libraryID = nil
        libraryKind = nil
        supportedSections = []
        withheldSections = []
        isLibraryChecked = false
        librarySection = nil
        paths = [:]
    }

    /// Restores the library and its kind without resetting paths; used by snapshot restore.
    /// Until the scene confirms the library, it shows `supportedSections`, by default every
    /// section of its kind, or every section when the kind is unknown.
    func restoreLibrary(id: String?, kind: LibraryKind?, supportedSections: Set<AppTab>? = nil) {
        libraryID = id
        libraryKind = kind
        self.supportedSections =
            supportedSections ?? (kind == nil ? Set(AppTab.sections) : AppTab.sections(for: kind))
        isLibraryChecked = false
    }

    /// Hides exactly `sections` (``withheldSections``), such as Add podcast from a user known not
    /// to be allowed it before the libraries load, showing again any withheld before; `[]` hides
    /// none. Doesn't check or change the library. Newly hidden sections are repaired as
    /// ``repairSections(supported:keepsLibraryPath:)`` does; an unchecked library keeps its
    /// Library path, which may hold a launch link's screens.
    func withholdSections(_ sections: Set<AppTab>) {
        guard sections != withheldSections else { return }
        let hidesMore = !sections.isSubset(of: withheldSections)
        withheldSections = sections
        if hidesMore { repairSections(supported: Set(visibleSections), keepsLibraryPath: !isLibraryChecked) }
    }

    /// Shows no library, for a user confirmed to have none: resets the library-scoped paths and
    /// the sections, and keeps Downloads and Account.
    func clearLibrary() {
        for tab in AppTab.allCases where tab.isLibraryScoped {
            self[path: tab] = []
        }
        libraryID = nil
        libraryKind = nil
        supportedSections = []
        withheldSections = []
        isLibraryChecked = true
        repairSections(supported: [])
    }

    /// Falls back from unsupported sections: the selected tab to Library, the Library section
    /// to the default grid (dropping the Library path, which came from that section), and
    /// clears the paths of unsupported section tabs.
    ///
    /// - Parameter keepsLibraryPath: keeps the Library path when its section falls back, for a
    ///   library replacing one that was never checked: the path may hold a launch or deep link's
    ///   screens, opened since, which keep their pending play link.
    func repairSections(supported: Set<AppTab>, keepsLibraryPath: Bool = false) {
        if selectedTab.isSection, !supported.contains(selectedTab) {
            selectedTab = .library
        }
        if let section = librarySection, !section.isSection || !supported.contains(section) {
            librarySection = nil
            if !keepsLibraryPath { self[path: .library] = [] }
        }
        for tab in AppTab.sections where !supported.contains(tab) {
            self[path: tab] = []
        }
    }
}
