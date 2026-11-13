import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

private let address = "https://abs.example.com/audiobookshelf"
private let connectionA = UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
private let connectionB = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

/// The activity the full player publishes (ADR 0004, "Handoff"), read back by the receiver.
@Suite struct PlayerHandoffTests {
    private let active = ServerConnectionDTO(
        id: connectionA, address: address, userId: "usr_1", username: "usr_1", authMethod: .local,
        createdAt: Date(timeIntervalSinceReferenceDate: 0))

    @Test func aBookRoundTripsAsAPlayLinkAtItsPosition() throws {
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(playing: key, position: 5025.75, active: active))
        #expect(userInfo["item"] as? String == "li_1")
        #expect(userInfo["episode"] == nil)
        #expect(userInfo["position"] as? Double == 5025)
        #expect(userInfo["serverAddress"] as? String == address)
        #expect(userInfo["userID"] as? String == "usr_1")

        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.link == DeepLink(.play(PlayLink(itemID: "li_1", startTime: 5025))))
        #expect(activity.account == HandoffAccount(serverAddress: address, userID: "usr_1"))
    }

    @Test func anEpisodeRoundTripsAsAPlayLinkAtItsPosition() throws {
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_pod", episodeId: "ep_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(playing: key, position: 12, active: active))
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.link == DeepLink(.play(PlayLink(itemID: "li_pod", episodeID: "ep_1", startTime: 12))))
    }

    @Test func theLocalConnectionIDIsNeverPublished() throws {
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(playing: key, position: 1, active: active))
        #expect(userInfo["server"] == nil)
        #expect(!userInfo.values.contains { ($0 as? String) == connectionA.uuidString })
    }

    @Test func mediaOnAnotherConnectionPublishesNothing() {
        // Control: the same key on the active connection publishes.
        let mine = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1")
        #expect(DeepLink.handoffUserInfo(playing: mine, position: 1, active: active) != nil)
        // The outgoing account's item during a switch.
        let theirs = MediaKey(serverConnectionID: connectionB, libraryItemId: "li_1")
        #expect(DeepLink.handoffUserInfo(playing: theirs, position: 1, active: active) == nil)
        #expect(DeepLink.handoffUserInfo(playing: mine, position: 1, active: nil) == nil)
    }

    @Test func anAccountOrIDsTheReceiverWouldRejectPublishNothing() {
        var unnormalized = active
        unnormalized.address = "abs.example.com/audiobookshelf/"
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1")
        #expect(DeepLink.handoffUserInfo(playing: key, position: 1, active: unnormalized) == nil)
        let badItem = MediaKey(serverConnectionID: connectionA, libraryItemId: "a\nb")
        #expect(DeepLink.handoffUserInfo(playing: badItem, position: 1, active: active) == nil)
        let badEpisode = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1", episodeId: "..")
        #expect(DeepLink.handoffUserInfo(playing: badEpisode, position: 1, active: active) == nil)
    }

    @Test(arguments: [nil, Double.nan, .infinity, -.infinity, 10_000_000.5])
    func aPositionTheReceiverWouldIgnoreIsLeftOut(position: Double?) throws {
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(playing: key, position: position, active: active))
        #expect(userInfo["position"] == nil)
        // It still opens the item.
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.link == DeepLink(.item(id: "li_1", episodeID: nil)))
    }

    @Test(arguments: [(-3.0, 0.0), (0, 0), (0.9, 0), (10_000_000, 10_000_000)])
    func aPositionIsWholeSecondsInRange(position: Double, published: Double) throws {
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(playing: key, position: position, active: active))
        #expect(userInfo["position"] as? Double == published)
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.link == DeepLink(.play(PlayLink(itemID: "li_1", startTime: published))))
    }

    /// The receive side: the position reaches the router as the pending play link, for the item
    /// screen's confirmation, and opens the screen without starting anything.
    @MainActor
    @Test func theRouterKeepsThePositionForTheConfirmation() throws {
        let key = MediaKey(serverConnectionID: connectionA, libraryItemId: "li_pod", episodeId: "ep_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(playing: key, position: 640.2, active: active))
        let link = try #require(DeepLink(handoff: userInfo))
        let router = Router(serverID: connectionA.uuidString, userID: "usr_1")
        router.isFullPlayerPresented = true
        router.open(link)
        #expect(router.pendingPlayLink == PlayLink(itemID: "li_pod", episodeID: "ep_1", startTime: 640))
        #expect(router[path: .library] == [.item(id: "li_pod"), .episode(itemID: "li_pod", episodeID: "ep_1")])
        #expect(!router.isFullPlayerPresented)

        // Control: an item screen's activity, without a position, opens with nothing pending.
        let account = try #require(HandoffAccount(connection: active))
        let item = try #require(DeepLink.handoffUserInfo(itemID: "li_1", account: account))
        router.open(try #require(DeepLink(handoff: item)))
        #expect(router.pendingPlayLink == nil)
    }
}

/// What the player model hands the Handoff publisher.
@MainActor
@Suite struct PlayerViewModelHandoffTests {
    private let active = ServerConnectionDTO(
        id: FakePlaybackControl.serverID, address: address, userId: "usr_1", username: "usr_1", authMethod: .local,
        createdAt: Date(timeIntervalSinceReferenceDate: 0))

    @Test func withoutASessionNothingIsPublished() throws {
        try withModel { model, playback in
            playback.mediaKey = MediaKey(serverConnectionID: FakePlaybackControl.serverID, libraryItemId: "li_1")
            playback.currentTime = 30
            // Idle: the key left over doesn't publish.
            #expect(model.mediaKey == nil)
            #expect(model.handoffPosition == nil)
            #expect(model.handoffUserInfo(active: active) == nil)
        }
    }

    @Test func thePlayingItemPublishesWithTheCurrentPosition() throws {
        try withModel { model, playback in
            playback.phase = .loaded
            playback.mediaKey = MediaKey(
                serverConnectionID: FakePlaybackControl.serverID, libraryItemId: "li_pod", episodeId: "ep_1")
            playback.currentTime = 30.4
            var userInfo = try #require(model.handoffUserInfo(active: active))
            #expect(userInfo["item"] as? String == "li_pod")
            #expect(userInfo["episode"] as? String == "ep_1")
            #expect(userInfo["position"] as? Double == 30)
            // Read when saved, so a later read has the later position.
            playback.currentTime = 95
            userInfo = try #require(model.handoffUserInfo(active: active))
            #expect(userInfo["position"] as? Double == 95)
            // Another account's connection publishes nothing.
            var other = active
            other.id = UUID()
            #expect(model.handoffUserInfo(active: other) == nil)
        }
    }

    private func withModel(_ body: (PlayerViewModel, FakePlaybackControl) throws -> Void) throws {
        let suiteName = "ABSAppModelTests.PlayerHandoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playback = FakePlaybackControl()
        try body(PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults)), playback)
    }
}
