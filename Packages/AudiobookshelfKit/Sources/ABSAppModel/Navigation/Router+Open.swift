import Foundation

extension Router {
    /// Navigates this scene to `link`; the only entry point for external navigation (URLs,
    /// Handoff and later App Intents). It changes navigation state only and never starts
    /// playback.
    ///
    /// - A link for another server (`server=` that isn't ``serverID``) changes nothing but
    ///   ``pendingServerSwitch``, so the scene can ask before switching.
    /// - Items, series, authors, collections and playlists open in the Library tab, pushed
    ///   onto its path (unless that path already ends there). An episode pushes the item and
    ///   then the episode.
    /// - `play` opens the item like `item` and sets ``pendingPlayLink`` for the item screen's
    ///   confirmation (``PlayLinkDecision``).
    /// - `library` selects the Library tab and calls ``requestLibrary(id:)``.
    /// - `search` selects Search at its root and sets ``pendingSearchQuery``.
    /// - `downloads` selects Downloads.
    ///
    /// Every link that navigates also dismisses the full player, which would cover the
    /// destination, and replaces any earlier pending play link, search query or server switch.
    public func open(_ link: DeepLink) {
        if let linkServer = link.serverID, !Self.isSameServer(linkServer, serverID) {
            pendingServerSwitch = link
            return
        }
        pendingServerSwitch = nil
        pendingPlayLink = nil
        pendingSearchQuery = nil
        isFullPlayerPresented = false

        switch link.target {
        case .item(let id, let episodeID):
            push(Self.itemRoutes(id: id, episodeID: episodeID), on: .library)
        case .play(let playLink):
            push(Self.itemRoutes(id: playLink.itemID, episodeID: playLink.episodeID), on: .library)
            pendingPlayLink = playLink
        case .series(let id):
            push([.series(id: id)], on: .library)
        case .author(let id):
            push([.author(id: id)], on: .library)
        case .collection(let id):
            push([.collection(id: id)], on: .library)
        case .playlist(let id):
            push([.playlist(id: id)], on: .library)
        case .library(let id):
            selectedTab = .library
            requestLibrary(id: id)
        case .search(let query):
            selectedTab = .search
            self[path: .search] = []
            pendingSearchQuery = query
        case .downloads:
            selectedTab = .downloads
        }
    }

    /// Selects `tab` and appends `routes`, unless its path already ends with them.
    private func push(_ routes: [Route], on tab: AppTab) {
        selectedTab = tab
        let path = self[path: tab]
        guard !path.suffix(routes.count).elementsEqual(routes) else { return }
        // An episode link opened on its item's screen only needs the episode.
        if routes.count == 2, path.last == routes.first {
            self[path: tab] = path + routes.dropFirst()
        } else {
            self[path: tab] = path + routes
        }
    }

    private static func itemRoutes(id: String, episodeID: String?) -> [Route] {
        guard let episodeID else { return [.item(id: id)] }
        return [.item(id: id), .episode(itemID: id, episodeID: episodeID)]
    }

    /// Connection IDs are UUIDs, which links may spell in either case.
    private static func isSameServer(_ linkServer: String, _ current: String?) -> Bool {
        guard let current else { return false }
        if let lhs = UUID(uuidString: linkServer), let rhs = UUID(uuidString: current) { return lhs == rhs }
        return linkServer == current
    }
}
