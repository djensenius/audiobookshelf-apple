import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Testing

@testable import ABSAppModel

private let accountA = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)
private let accountB = LibraryConnectionKey(connectionID: identityB.connectionID, userID: identityB.userID)

/// A service without a feed; routing never asks it anything.
private struct NoFeedService: RssFeedService {
    func serverURL() async -> URL { URL(string: "https://abs.example")! }
    func currentFeed(for target: RssFeedTarget) async throws -> RssFeed? { nil }
    func openFeed(for target: RssFeedTarget, _ request: RssFeedOpenRequest) async throws -> RssFeed {
        throw APIError.notFound
    }
    func closeFeed(id: String) async throws {}
}

/// Stands in for an RSS sheet, which owns its model's observation while it shows.
private final class SheetLifetime {}

/// A bridge with fake sockets, routed as the app routes it into a store serving `account`.
@MainActor
private final class RoutedFeeds {
    let harness = BridgeHarness()
    let store: LibraryStore
    let playback = FakePlaybackControl()

    init(settings: AppSettings, serving account: LibraryConnectionKey = accountA) {
        store = LibraryStore(settings: settings)
        store.attach(client: nil, connectionKey: account, isOffline: true)
        harness.bridge.route(
            library: store, accounts: nil, bookmarks: { nil }, playback: playback, localProgress: nil)
    }

    /// A sheet's model for `target`, following `account`'s live changes while `owner` (by default
    /// the model) lives.
    func follow(_ target: RssFeedTarget, account: LibraryConnectionKey = accountA, owner: AnyObject? = nil)
        -> RssFeedModel
    {
        let model = RssFeedModel(target: target, service: NoFeedService())
        store.observeRssFeedChanges(connectionKey: account, owner: owner ?? model) { [weak model] in
            model?.apply($0)
        }
        return model
    }

    func send(_ change: RssFeedChange, on socket: FakeSocket) async {
        await harness.send(.rssFeedChanged(change), on: socket)
    }
}

private func itemFeed(_ itemID: String) -> RssFeed {
    RssFeed(id: "feed-\(itemID)", entityType: "libraryItem", entityId: itemID, feedUrl: "/feed/\(itemID)")
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RssFeedRoutingTests {
    private let item = RssFeedTarget(.item, id: "li-1")

    @Test func anOpenSheetFollowsItsEntitysOpenAndClose() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings)
            let model = routed.follow(item)
            let socket = try await routed.harness.start()
            let opened = itemFeed("li-1")

            await routed.send(.opened(opened), on: socket)
            #expect(model.feed == opened)
            #expect(model.hasKnownState)

            await routed.send(.closed(opened), on: socket)
            #expect(model.feed == nil)
        }
    }

    @Test func otherEntitiesChangesAreIgnored() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings)
            let model = routed.follow(item)
            let socket = try await routed.harness.start()
            // Another item; then the same ID as another kind of entity.
            let sameID = RssFeed(id: "feed-col", entityType: "collection", entityId: "li-1", feedUrl: "/feed/c")

            await routed.send(.opened(itemFeed("li-2")), on: socket)
            await routed.send(.opened(sameID), on: socket)

            #expect(model.feed == nil)
            #expect(!model.hasKnownState)
        }
    }

    @Test func twoSheetsEachFollowTheirOwnEntity() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings)
            let itemModel = routed.follow(item)
            let collectionModel = routed.follow(RssFeedTarget(.collection, id: "col-1"))
            let socket = try await routed.harness.start()
            let itemOpened = itemFeed("li-1")
            let collectionOpened = RssFeed(
                id: "feed-col-1", entityType: "collection", entityId: "col-1", feedUrl: "/feed/col-1")

            await routed.send(.opened(itemOpened), on: socket)
            #expect(itemModel.feed == itemOpened)
            #expect(collectionModel.feed == nil)

            await routed.send(.opened(collectionOpened), on: socket)
            await routed.send(.closed(itemOpened), on: socket)
            #expect(itemModel.feed == nil)
            #expect(collectionModel.feed == collectionOpened)
        }
    }

    /// The entry keeps the last sheet's model, but the sheet owned its observation.
    @Test func aClosedSheetsModelGetsNoMoreChanges() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings)
            var sheet: SheetLifetime? = SheetLifetime()
            let model = routed.follow(item, owner: try #require(sheet))
            let socket = try await routed.harness.start()
            let opened = itemFeed("li-1")

            await routed.send(.opened(opened), on: socket)
            #expect(model.feed == opened)

            sheet = nil
            await routed.send(.closed(opened), on: socket)
            #expect(model.feed == opened)
        }
    }

    @Test func theStoreDoesntKeepAModelAlive() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings)
            weak var released: RssFeedModel?
            do {
                let model = routed.follow(item)
                released = model
            }
            let survivor = routed.follow(item)
            let socket = try await routed.harness.start()
            let opened = itemFeed("li-1")

            await routed.send(.opened(opened), on: socket)

            #expect(released == nil)
            #expect(survivor.feed == opened)
        }
    }

    @Test func anotherAccountsSheetGetsNothing() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings)
            let own = routed.follow(item)
            let other = routed.follow(item, account: accountB)
            let socket = try await routed.harness.start()
            let opened = itemFeed("li-1")

            await routed.send(.opened(opened), on: socket)

            #expect(own.feed == opened)
            #expect(other.feed == nil)
            #expect(!other.hasKnownState)
        }
    }

    /// The socket's session is account A's, but the store already serves account B.
    @Test func changesForAnAccountTheStoreNoLongerServesAreDropped() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedFeeds(settings: settings, serving: accountB)
            let models = [routed.follow(item), routed.follow(item, account: accountB)]
            let socket = try await routed.harness.start()

            await routed.send(.opened(itemFeed("li-1")), on: socket)

            #expect(models.allSatisfy { $0.feed == nil && !$0.hasKnownState })
        }
    }
}
