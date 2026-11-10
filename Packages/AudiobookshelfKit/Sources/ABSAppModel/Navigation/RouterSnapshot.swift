import Foundation

extension Router {
    /// A scene's restorable navigation state, stored as JSON in `@SceneStorage` under an
    /// identity-scoped key (`nav.snapshot.<serverID>.<userID>`).
    ///
    /// It holds stable IDs only. ``Router/isFullPlayerPresented`` is deliberately left out.
    public struct Snapshot: Hashable, Codable, Sendable {
        public var serverID: String?
        public var userID: String?
        public var selectedTab: AppTab
        public var libraryID: String?
        /// The kind of `libraryID`, used to validate `librarySection` on restore.
        public var libraryKind: LibraryKind?
        public var librarySection: AppTab?
        public var paths: [AppTab: [Route]]
        public var isQueueInspectorPresented: Bool

        public init(
            serverID: String?, userID: String?, selectedTab: AppTab = .home, libraryID: String? = nil,
            libraryKind: LibraryKind? = nil, librarySection: AppTab? = nil, paths: [AppTab: [Route]] = [:],
            isQueueInspectorPresented: Bool = false
        ) {
            self.serverID = serverID
            self.userID = userID
            self.selectedTab = selectedTab
            self.libraryID = libraryID
            self.libraryKind = libraryKind
            self.librarySection = librarySection
            self.paths = paths
            self.isQueueInspectorPresented = isQueueInspectorPresented
        }
    }

    /// The scene's navigation state, for `@SceneStorage`.
    ///
    /// Setting it restores a snapshot of this router's server and user. A snapshot of another
    /// server or user is discarded and the scene starts from the defaults. `librarySection`
    /// is restored before the paths and validated against the library's kind, as a library
    /// switch would; unsupported sections fall back to Library and the default grid, and
    /// their paths are dropped. The full player's presentation is never changed.
    public var snapshot: Snapshot {
        get {
            Snapshot(
                serverID: serverID, userID: userID, selectedTab: selectedTab, libraryID: libraryID,
                libraryKind: libraryKind, librarySection: librarySection, paths: paths,
                isQueueInspectorPresented: isQueueInspectorPresented
            )
        }
        set {
            resetNavigation()
            guard newValue.serverID == serverID, newValue.userID == userID else {
                isQueueInspectorPresented = false
                return
            }
            let supported = AppTab.sections(for: newValue.libraryKind)
            restoreLibrary(id: newValue.libraryID, kind: newValue.libraryKind)
            selectedTab = newValue.selectedTab
            librarySection = newValue.librarySection
            repairSections(supported: supported)
            for (tab, path) in newValue.paths where !tab.isSection || supported.contains(tab) {
                self[path: tab] = path
            }
            isQueueInspectorPresented = newValue.isQueueInspectorPresented
        }
    }
}
