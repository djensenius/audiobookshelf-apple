import ABSAPI
import ABSData
import Foundation
import Observation
import Testing

@testable import ABSAppModel

private let address = "https://abs.example.com/audiobookshelf"
private let otherAddress = "https://books.example.org"
private let connectionA = UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
private let connectionB = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

/// Parsing the account a Handoff activity names (ADR 0004, "Handoff").
@Suite struct HandoffAccountParsingTests {
    @Test func bothKeysNameTheAccount() throws {
        let activity = try #require(HandoffActivity(userInfo: payload(address, "usr_1")))
        #expect(activity.account == HandoffAccount(serverAddress: address, userID: "usr_1"))
        #expect(activity.link == DeepLink(.item(id: "li_1", episodeID: nil)))
    }

    @Test func publishedEntriesReadBack() throws {
        let account = try #require(HandoffAccount(serverAddress: address, userID: "usr_1"))
        var userInfo: [AnyHashable: Any] = ["item": "li_1", "position": 12]
        userInfo.merge(account.userInfo) { $1 }
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.account == account)
        #expect(activity.link == DeepLink(.play(PlayLink(itemID: "li_1", startTime: 12))))
    }

    @Test func noAccountKeysOpenOnTheActiveAccount() throws {
        // A payload from before the keys were added still opens.
        let activity = try #require(HandoffActivity(userInfo: ["item": "li_1"]))
        #expect(activity.account == nil)
    }

    @Test func oneKeyMissingRejectsTheActivity() {
        #expect(HandoffActivity(userInfo: ["item": "li_1", "serverAddress": address]) == nil)
        #expect(HandoffActivity(userInfo: ["item": "li_1", "userID": "usr_1"]) == nil)
        #expect(DeepLink(handoff: ["item": "li_1", "serverAddress": address]) == nil)
        #expect(DeepLink(handoff: ["item": "li_1", "userID": "usr_1"]) == nil)
    }

    @Test func emptyValuesRejectTheActivity() {
        #expect(HandoffActivity(userInfo: payload("", "usr_1")) == nil)
        #expect(HandoffActivity(userInfo: payload(address, "")) == nil)
        #expect(HandoffActivity(userInfo: payload("", "")) == nil)
        #expect(DeepLink(handoff: payload(address, "")) == nil)
    }

    @Test func valuesThatAreNotStringsRejectTheActivity() {
        let wrong: [Any] = [5, true, ["x"], NSNull(), URL(string: address)!]
        for value in wrong {
            #expect(HandoffActivity(userInfo: payload(value, "usr_1")) == nil, "\(value)")
            #expect(HandoffActivity(userInfo: payload(address, value)) == nil, "\(value)")
            #expect(DeepLink(handoff: payload(value, "usr_1")) == nil, "\(value)")
        }
    }

    @Test(arguments: [
        "abs.example.com/audiobookshelf", "HTTPS://ABS.example.com/audiobookshelf",
        "https://abs.example.com/audiobookshelf/", "https://abs.example.com:443/audiobookshelf",
        " https://abs.example.com/audiobookshelf", "https://abs.example.com/audiobookshelf?x=1",
        "ftp://abs.example.com", "not a url",
    ])
    func unnormalizedAddressRejectsTheActivity(address: String) {
        #expect(HandoffActivity(userInfo: payload(address, "usr_1")) == nil)
        #expect(DeepLink(handoff: payload(address, "usr_1")) == nil)
    }

    @Test(arguments: [" ", ".", "a\nb", String(repeating: "x", count: 257)])
    func invalidUserIDRejectsTheActivity(userID: String) {
        #expect(HandoffActivity(userInfo: payload(address, userID)) == nil)
    }

    @Test func unknownExtraKeysAreIgnored() throws {
        var userInfo = payload(address, "usr_1")
        userInfo["server"] = connectionA.uuidString
        userInfo["library"] = "lib_1"
        userInfo["theme"] = ["dark"]
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.account == HandoffAccount(serverAddress: address, userID: "usr_1"))
        #expect(activity.link == DeepLink(.item(id: "li_1", episodeID: nil)))
    }

    @Test func anInvalidItemStillRejectsAnActivityWithAnAccount() {
        #expect(HandoffActivity(userInfo: ["item": "", "serverAddress": address, "userID": "usr_1"]) == nil)
        #expect(HandoffActivity(userInfo: nil) == nil)
    }
}

/// The activity an item or episode screen publishes, read back by the receiver.
@Suite struct HandoffPublishingTests {
    @Test func anItemRoundTrips() throws {
        let account = try account(address, "usr_1")
        let userInfo = try #require(DeepLink.handoffUserInfo(itemID: "li_1", account: account))
        #expect(userInfo == ["item": "li_1", "serverAddress": address, "userID": "usr_1"])
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.link == DeepLink(.item(id: "li_1", episodeID: nil)))
        #expect(activity.account == account)
    }

    @Test func anEpisodeRoundTrips() throws {
        let account = try account(otherAddress, "usr_2")
        let userInfo = try #require(DeepLink.handoffUserInfo(itemID: "li_1", episodeID: "ep_1", account: account))
        let activity = try #require(HandoffActivity(userInfo: userInfo))
        #expect(activity.link == DeepLink(.item(id: "li_1", episodeID: "ep_1")))
        #expect(activity.account == account)
    }

    @Test func anEmptyEpisodeIsLeftOut() throws {
        let userInfo = DeepLink.handoffUserInfo(itemID: "li_1", episodeID: "", account: try account(address, "usr_1"))
        #expect(userInfo?["episode"] == nil)
        #expect(userInfo?["item"] == "li_1")
    }

    @Test func invalidIDsPublishNothing() throws {
        let account = try account(address, "usr_1")
        #expect(DeepLink.handoffUserInfo(itemID: "", account: account) == nil)
        #expect(DeepLink.handoffUserInfo(itemID: "a\nb", account: account) == nil)
        #expect(DeepLink.handoffUserInfo(itemID: "li_1", episodeID: " ", account: account) == nil)
    }

    @Test func aConnectionNamesItsAccountButNotItsID() throws {
        let saved = connection(connectionA, address: address, userID: "usr_1")
        let account = try #require(HandoffAccount(connection: saved))
        #expect(account == HandoffAccount(serverAddress: address, userID: "usr_1"))
        let userInfo = try #require(DeepLink.handoffUserInfo(itemID: "li_1", account: account))
        #expect(!userInfo.values.contains(connectionA.uuidString))
        #expect(HandoffAccount(connection: connection(connectionA, address: "not a url", userID: "usr_1")) == nil)
    }
}

/// Matching the account to a saved connection, and what the router does with the result.
@MainActor
@Suite struct HandoffAccountResolutionTests {
    @Test func twoServersResolveToTheirOwnConnections() throws {
        let connections = [
            connection(connectionA, address: address, userID: "usr_1"),
            connection(connectionB, address: otherAddress, userID: "usr_1"),
        ]
        #expect(try account(address, "usr_1").connectionID(in: connections) == connectionA)
        #expect(try account(otherAddress, "usr_1").connectionID(in: connections) == connectionB)
    }

    @Test func twoUsersOnOneServerResolveToTheirOwnConnections() throws {
        let connections = [
            connection(connectionA, address: address, userID: "usr_1"),
            connection(connectionB, address: address, userID: "usr_2"),
        ]
        #expect(try account(address, "usr_1").connectionID(in: connections) == connectionA)
        #expect(try account(address, "usr_2").connectionID(in: connections) == connectionB)
        #expect(try account(address, "usr_3").connectionID(in: connections) == nil)
    }

    @Test func userIDsAreCaseSensitive() throws {
        let connections = [connection(connectionA, address: address, userID: "usr_1")]
        #expect(try account(address, "USR_1").connectionID(in: connections) == nil)
    }

    @Test func aSavedAddressIsComparedNormalized() throws {
        // Saved addresses are normalized already; one saved before a normalization change still matches.
        let connections = [
            connection(connectionA, address: "https://ABS.example.com:443/audiobookshelf/", userID: "usr_1")
        ]
        #expect(try account(address, "usr_1").connectionID(in: connections) == connectionA)
    }

    @Test func signedOutAndDisconnectedConnectionsDoNotMatch() throws {
        var signedOut = connection(connectionA, address: address, userID: "usr_1")
        signedOut.signedOutAt = Date(timeIntervalSinceReferenceDate: 1)
        var disconnected = connection(connectionB, address: address, userID: "usr_1")
        disconnected.isDisconnected = true
        #expect(try account(address, "usr_1").connectionID(in: [signedOut, disconnected]) == nil)
    }

    @Test func noMatchDoesNotNavigate() async throws {
        let accounts = MatchingAccounts(connections: [connection(connectionA, address: otherAddress, userID: "usr_1")])
        let activity = try #require(HandoffActivity(userInfo: payload(address, "usr_1")))
        let resolution = await activity.resolve(using: accounts)
        #expect(resolution == .accountNotSignedIn(try account(address, "usr_1")))
    }

    @Test func aSourceWithoutConnectionsMatchesNothing() async throws {
        // The protocol's default: a source that can't list connections opens no named account.
        let accounts = FakeAccountSource(log: CallLog())
        let activity = try #require(HandoffActivity(userInfo: payload(address, "usr_1")))
        let resolution = await activity.resolve(using: accounts)
        #expect(resolution == .accountNotSignedIn(try account(address, "usr_1")))
    }

    @Test func noAccountOpensTheLinkUnchanged() async throws {
        let accounts = MatchingAccounts(connections: [])
        let activity = try #require(HandoffActivity(userInfo: ["item": "li_1"]))
        let resolution = await activity.resolve(using: accounts)
        #expect(resolution == .open(DeepLink(.item(id: "li_1", episodeID: nil))))
    }

    @Test func theActiveConnectionOpensTheItem() async throws {
        let accounts = MatchingAccounts(connections: [connection(connectionA, address: address, userID: "usr_1")])
        let activity = try #require(HandoffActivity(userInfo: payload(address, "usr_1")))
        let resolution = await activity.resolve(using: accounts)
        #expect(resolution == .open(DeepLink(.item(id: "li_1", episodeID: nil), serverID: connectionA.uuidString)))

        let router = Router(serverID: connectionA.uuidString, userID: "usr_1")
        guard case .open(let link) = resolution else { return }
        router.open(link)
        #expect(router.pendingServerSwitch == nil)
        #expect(router[path: .library] == [.item(id: "li_1")])
    }

    @Test func anInactiveConnectionAsksBeforeSwitching() async throws {
        let accounts = MatchingAccounts(connections: [
            connection(connectionA, address: address, userID: "usr_1"),
            connection(connectionB, address: address, userID: "usr_2"),
        ])
        let activity = try #require(HandoffActivity(userInfo: payload(address, "usr_2")))
        let resolution = await activity.resolve(using: accounts)
        let expected = DeepLink(.item(id: "li_1", episodeID: nil), serverID: connectionB.uuidString)
        #expect(resolution == .open(expected))

        let router = Router(serverID: connectionA.uuidString, userID: "usr_1")
        guard case .open(let link) = resolution else { return }
        router.open(link)
        #expect(router.pendingServerSwitch == expected)
        #expect(router[path: .library].isEmpty)
    }

    /// The scene resolves through the lifecycle, which asks its own account source.
    @Test func theLifecycleResolvesThroughItsAccountSource() async throws {
        let accounts = MatchingAccounts(connections: [connection(connectionB, address: address, userID: "usr_2")])
        let lifecycle = SessionLifecycle(source: accounts)
        let known = try #require(HandoffActivity(userInfo: payload(address, "usr_2")))
        #expect(
            await lifecycle.resolve(known)
                == .open(DeepLink(.item(id: "li_1", episodeID: nil), serverID: connectionB.uuidString)))

        let stranger = try #require(HandoffActivity(userInfo: payload(address, "usr_3")))
        #expect(await lifecycle.resolve(stranger) == .accountNotSignedIn(try account(address, "usr_3")))
    }
}

/// An accounts source with saved connections, matched as `AccountManager` matches them.
@MainActor @Observable
private final class MatchingAccounts: AccountSessionSource {
    var phase: AccountSessionPhase = .signedOut
    var client: APIClient?
    let connections: [ServerConnectionDTO]

    init(connections: [ServerConnectionDTO]) {
        self.connections = connections
    }

    func restore() async throws {}
    func logout() async -> URL? { nil }
    func `switch`(to connectionID: UUID) async throws {}
    func remove(_ connectionID: UUID) async throws -> URL? { nil }
    func connectionID(for account: HandoffAccount) async -> UUID? { account.connectionID(in: connections) }
}

private func payload(_ address: Any, _ userID: Any) -> [AnyHashable: Any] {
    ["item": "li_1", "serverAddress": address, "userID": userID]
}

private func account(_ address: String, _ userID: String) throws -> HandoffAccount {
    try #require(HandoffAccount(serverAddress: address, userID: userID))
}

private func connection(_ id: UUID, address: String, userID: String) -> ServerConnectionDTO {
    ServerConnectionDTO(
        id: id, address: address, userId: userID, username: userID, authMethod: .local,
        createdAt: Date(timeIntervalSinceReferenceDate: 0))
}
