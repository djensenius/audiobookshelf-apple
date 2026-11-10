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

        /// Decodes leniently, so a snapshot from a newer build still restores. Tabs this build
        /// doesn't know are skipped in `paths`, and each path is cut at its first route that
        /// doesn't decode, keeping the screens before it. An unknown `selectedTab` becomes Home
        /// and an unknown `libraryKind` becomes `nil`. An unknown `librarySection` becomes the
        /// default grid, and the Library path, which belonged to that section, is dropped.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            serverID = try container.decodeIfPresent(String.self, forKey: .serverID)
            userID = try container.decodeIfPresent(String.self, forKey: .userID)
            selectedTab = AppTab(rawValue: try container.decode(String.self, forKey: .selectedTab)) ?? .home
            libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
            libraryKind = try container.decodeIfPresent(String.self, forKey: .libraryKind).flatMap {
                LibraryKind(rawValue: $0)
            }
            let sectionName = try container.decodeIfPresent(String.self, forKey: .librarySection)
            librarySection = sectionName.flatMap { AppTab(rawValue: $0) }
            isQueueInspectorPresented = try container.decode(Bool.self, forKey: .isQueueInspectorPresented)

            paths = [:]
            let pathsContainer = try container.nestedContainer(keyedBy: TabKey.self, forKey: .paths)
            for key in pathsContainer.allKeys {
                guard let tab = AppTab(rawValue: key.stringValue),
                    var routes = try? pathsContainer.nestedUnkeyedContainer(forKey: key)
                else { continue }
                var path: [Route] = []
                while !routes.isAtEnd, let route = try? routes.decode(Route.self) {
                    path.append(route)
                }
                if !path.isEmpty { paths[tab] = path }
            }
            if sectionName != nil, librarySection == nil {
                paths[.library] = nil
            }
        }

        private struct TabKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// ``snapshot`` as JSON, for `@SceneStorage`; `nil` only if encoding fails.
    public var snapshotData: Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Restores ``snapshot`` from `@SceneStorage` JSON. Missing or unreadable data starts the
    /// scene from the defaults, like a snapshot of another server or user.
    public func restore(from data: Data?) {
        guard let data, let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            resetNavigation()
            isQueueInspectorPresented = false
            return
        }
        self.snapshot = snapshot
    }

    /// The scene's navigation state, for `@SceneStorage`.
    ///
    /// Setting it restores a snapshot of this router's server and user. A snapshot of another
    /// server or user is discarded and the scene starts from the defaults. `librarySection`
    /// is restored before the paths and validated against the library's kind, as a library
    /// switch would; unsupported sections fall back to Library and the default grid, and
    /// their paths are dropped, as is a Library path that belonged to a dropped section. The
    /// full player's presentation is never changed. Call ``normalize(isCompact:)`` afterwards.
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
            let droppedSection = newValue.librarySection != nil && librarySection == nil
            for (tab, path) in newValue.paths where !tab.isSection || supported.contains(tab) {
                if tab == .library, droppedSection { continue }
                self[path: tab] = path
            }
            isQueueInspectorPresented = newValue.isQueueInspectorPresented
        }
    }
}
