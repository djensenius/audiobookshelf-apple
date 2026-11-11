import ABSAppModel
import ABSCore
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Every `Route` case, with a sample route. ``init(_:)`` switches over `Route` exhaustively, so a
/// new route doesn't compile until it has a case and a sample here, and the test below checks
/// that it opens a screen.
enum RouteCase: CaseIterable {
    case item, episode, series, author, narrator, libraryFilter, collection, playlist, history, episodeHistory
    case localFolder, localItem, downloadQueue, stats, logs, servers, settings

    init(_ route: Route) {
        switch route {
        case .item: self = .item
        case .episode: self = .episode
        case .series: self = .series
        case .author: self = .author
        case .narrator: self = .narrator
        case .libraryFilter: self = .libraryFilter
        case .collection: self = .collection
        case .playlist: self = .playlist
        case .history(_, nil): self = .history
        case .history(_, .some): self = .episodeHistory
        case .localFolder: self = .localFolder
        case .localItem: self = .localItem
        case .downloadQueue: self = .downloadQueue
        case .stats: self = .stats
        case .logs: self = .logs
        case .servers: self = .servers
        case .settings: self = .settings
        }
    }

    var sample: Route {
        switch self {
        case .item: .item(id: "li_1")
        case .episode: .episode(itemID: "li_1", episodeID: "ep_1")
        case .series: .series(id: "se_1")
        case .author: .author(id: "aut_1")
        case .narrator: .narrator(name: "Ned")
        case .libraryFilter: .libraryFilter(kind: .genres, value: "Fantasy")
        case .collection: .collection(id: "col_1")
        case .playlist: .playlist(id: "pl_1")
        case .history: .history(itemID: "li_1")
        case .episodeHistory: .history(itemID: "li_1", episodeID: "ep_1")
        case .localFolder: .localFolder(id: "lf_1")
        case .localItem: .localItem(id: "local_1")
        case .downloadQueue: .downloadQueue
        case .stats: .stats
        case .logs: .logs
        case .servers: .servers
        case .settings: .settings
        }
    }
}

@MainActor
@Suite struct RouteDestinationTests {
    @Test(arguments: RouteCase.allCases)
    func everyRouteOpensAScreen(routeCase: RouteCase) throws {
        #expect(RouteCase(routeCase.sample) == routeCase)

        let suiteName = "RouteDestinationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let view = RouteDestination(route: routeCase.sample).environment(AppSettings(defaults: defaults))

        // A route without a screen renders `EmptyView`, which has no size.
        let proposal = CGSize(width: 400, height: 800)
        #if canImport(AppKit)
            let size = NSHostingController(rootView: view).sizeThatFits(in: proposal)
        #else
            let size = UIHostingController(rootView: view).sizeThatFits(in: proposal)
        #endif
        #expect(size.width > 0 && size.height > 0)
    }

    @Test(arguments: AppTab.allCases)
    func everyTabHasARootScreen(tab: AppTab) {
        let proposal = CGSize(width: 400, height: 800)
        #if canImport(AppKit)
            let size = NSHostingController(rootView: TabRoot(tab: tab)).sizeThatFits(in: proposal)
        #else
            let size = UIHostingController(rootView: TabRoot(tab: tab)).sizeThatFits(in: proposal)
        #endif
        #expect(size.width > 0 && size.height > 0)
    }
}
