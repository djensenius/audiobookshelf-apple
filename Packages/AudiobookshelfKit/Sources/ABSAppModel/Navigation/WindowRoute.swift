import Foundation

/// A screen opened in a window of its own with Open in New Window (ADR 0004, #83): the value the
/// app's `WindowGroup` opens a window for. The new window has its own ``Router``, which starts at
/// this screen (``Router/restoreScene(from:window:isCompact:opening:)``), and shares the app's one
/// player with every other window.
///
/// It carries the opening scene's server, user and library with the route, so the screen opens
/// in the same library, and a window that starts for another account ignores it, as a router
/// ignores another account's snapshot. Like ``Route``, it holds stable IDs only.
public struct WindowRoute: Hashable, Codable, Sendable {
    public let serverID: String?
    public let userID: String?
    public let libraryID: String?
    public let libraryKind: LibraryKind?
    public let route: Route

    public init(
        route: Route, serverID: String?, userID: String?, libraryID: String? = nil, libraryKind: LibraryKind? = nil
    ) {
        self.route = route
        self.serverID = serverID
        self.userID = userID
        self.libraryID = libraryID
        self.libraryKind = libraryKind
    }

    /// `route` opened from the scene of `router`, in its account and library; `nil` when the route
    /// doesn't open in a window of its own (``opensInNewWindow(_:)``).
    @MainActor
    public init?(_ route: Route, from router: Router) {
        guard Self.opensInNewWindow(route) else { return nil }
        self.init(
            route: route, serverID: router.serverID, userID: router.userID, libraryID: router.libraryID,
            libraryKind: router.libraryKind)
    }

    /// Whether `route` opens in a window of its own: items, episodes, series, authors, collections
    /// and playlists, the screens a deep link opens. The others belong where they were pushed from.
    public static func opensInNewWindow(_ route: Route) -> Bool {
        switch route {
        case .item, .episode, .series, .author, .collection, .playlist:
            true
        case .narrator, .libraryFilter, .history, .localFolder, .localItem, .downloadQueue, .stats, .logs, .servers,
            .settings:
            false
        }
    }

    /// What the new window starts with: the Library tab of the opening scene's library, with the
    /// screen pushed as a deep link pushes it, an episode above its podcast.
    public var snapshot: Router.Snapshot {
        let path: [Route] =
            if case .episode(let itemID, _) = route { [.item(id: itemID), route] } else { [route] }
        return Router.Snapshot(
            serverID: serverID, userID: userID, selectedTab: .library, libraryID: libraryID, libraryKind: libraryKind,
            paths: [.library: path])
    }
}
