import ABSAPI
import ABSCore
import ABSData
import CoreSpotlight
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// Records the index writes, in order, failing those of the kinds in ``failing``.
@MainActor
private final class FakeRecentItemsIndex: RecentItemsIndexing {
    enum Write: Equatable {
        case index(String)
        case delete([String])
        case deleteDomain(UUID)
    }

    enum Kind { case index, delete, deleteDomain }

    struct Failure: Error {}

    private(set) var writes: [Write] = []
    private(set) var indexed: [PlayableEntityRecord] = []
    /// The kinds of write that throw (each is still recorded).
    var failing: Set<Kind> = []

    func index(_ record: PlayableEntityRecord) async throws {
        writes.append(.index(record.id))
        if failing.contains(.index) { throw Failure() }
        indexed.append(record)
    }

    func delete(identifiers: [String]) async throws {
        writes.append(.delete(identifiers))
        if failing.contains(.delete) { throw Failure() }
    }

    func deleteDomain(of connectionID: UUID) async throws {
        writes.append(.deleteDomain(connectionID))
        if failing.contains(.deleteDomain) { throw Failure() }
    }

    func clearWrites() {
        writes = []
    }
}

/// The connections a callback was called with.
@MainActor
private final class Calls {
    var ids: [UUID] = []
}

@MainActor
@Observable
private final class FakeSavedConnections {
    var saved: Set<UUID> = []
}

@MainActor
@Observable
private final class FakeRejections {
    var count = 0
    var connectionID: UUID?
}

private let serverA = UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000001")!
private let serverB = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000002")!

private func record(
    _ item: String = "li_1", episode: String? = nil, server: UUID = serverA, title: String = "Dune"
) -> PlayableEntityRecord {
    PlayableEntityRecord(
        key: MediaKey(serverConnectionID: server, libraryItemId: item, episodeId: episode), title: title,
        subtitle: "Frank Herbert", duration: 400)
}

private func context(_ server: UUID) -> SessionContext {
    SessionContext(
        identity: SessionIdentity(connectionID: server, userID: "u1"), client: nil, isOffline: false, sessionID: 1)
}

@MainActor
@Suite final class RecentItemsDonorTests {
    private nonisolated let suite = "RecentItemsDonorTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    fileprivate let index = FakeRecentItemsIndex()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeDonor(running server: UUID? = serverA) async -> RecentItemsDonor {
        let donor = RecentItemsDonor(index: index, defaults: defaults)
        if let server { await donor.sessionDidStart(context(server)) }
        return donor
    }

    // MARK: Mapping

    @Test func aBookIsSearchableByItsTitleAuthorAndDuration() {
        let item = record().spotlightItem()

        #expect(item.uniqueIdentifier == "\(serverA.uuidString)|li_1|")
        #expect(item.domainIdentifier == serverA.uuidString)
        #expect(item.attributeSet.title == "Dune")
        #expect(item.attributeSet.displayName == "Dune")
        #expect(item.attributeSet.contentDescription == "Frank Herbert")
        #expect(item.attributeSet.authorNames == ["Frank Herbert"])
        #expect(item.attributeSet.album == nil)
        #expect(item.attributeSet.duration == 400)
        #expect(item.attributeSet.contentType == UTType.audio.identifier)
    }

    @Test func anEpisodeIsSearchableByItsPodcast() {
        let episode = PlayableEntityRecord(
            key: MediaKey(serverConnectionID: serverB, libraryItemId: "li_pod", episodeId: "ep_1"),
            title: "Episode 1", subtitle: "The Show", duration: nil)

        #expect(episode.kind == .episode)
        let item = episode.spotlightItem()
        #expect(item.uniqueIdentifier == "\(serverB.uuidString)|li_pod|ep_1")
        #expect(item.domainIdentifier == serverB.uuidString)
        #expect(item.attributeSet.album == "The Show")
        #expect(item.attributeSet.authorNames == nil)
        #expect(item.attributeSet.duration == nil)
    }

    @Test func aTappedResultOpensTheItemOnItsAccount() {
        #expect(
            DeepLink(spotlightIdentifier: record().id)
                == DeepLink(.item(id: "li_1", episodeID: nil), serverID: serverA.uuidString))
        #expect(
            DeepLink(spotlightIdentifier: record("li_pod", episode: "ep_1", server: serverB).id)
                == DeepLink(.item(id: "li_pod", episodeID: "ep_1"), serverID: serverB.uuidString))
    }

    @Test func aResultThatIsntAnItemOpensNothing() {
        #expect(DeepLink(spotlightIdentifier: "li_1") == nil)
        #expect(DeepLink(spotlightIdentifier: "not-a-uuid|li_1|") == nil)
        // IDs a link couldn't carry either (``DeepLink/isValidID(_:)``).
        #expect(DeepLink(spotlightIdentifier: "\(serverA.uuidString)| |") == nil)
        #expect(DeepLink(spotlightIdentifier: "\(serverA.uuidString)|..|") == nil)
        #expect(DeepLink(spotlightIdentifier: "\(serverA.uuidString)|li_1|ep\u{7}1") == nil)
        #expect(
            DeepLink(spotlightIdentifier: "\(serverA.uuidString)|li_1|\(String(repeating: "e", count: 257))") == nil)
    }

    // MARK: Donating

    @Test func aPlayedItemIsIndexedInItsAccountsDomain() async {
        let donor = await makeDonor()

        donor.donate(record())
        await donor.settle()

        #expect(index.writes == [.index(record().id)])
        #expect(index.indexed.map { $0.spotlightItem().domainIdentifier } == [serverA.uuidString])
        #expect(donor.indexedIdentifiers(of: serverA) == [record().id])
        #expect(donor.indexedIdentifiers(of: serverB).isEmpty)
    }

    @Test func anotherAccountsItemIsntIndexed() async {
        let donor = await makeDonor()

        donor.donate(record(server: serverB))
        await donor.settle()

        #expect(index.writes.isEmpty)
        #expect(donor.indexedIdentifiers(of: serverB).isEmpty)
    }

    @Test func nothingIsIndexedWithoutASession() async {
        let donor = await makeDonor(running: nil)

        donor.donate(record())
        await donor.settle()

        #expect(index.writes.isEmpty)
    }

    @Test func playingAnItemAgainUpdatesItInsteadOfAddingIt() async {
        let donor = await makeDonor()

        donor.donate(record("li_1"))
        donor.donate(record("li_1"))  // The same record: not written again.
        donor.donate(record("li_2"))
        donor.donate(record("li_1", title: "Dune (Unabridged)"))
        await donor.settle()

        #expect(index.writes == [.index(record("li_1").id), .index(record("li_2").id), .index(record("li_1").id)])
        #expect(index.indexed.last?.title == "Dune (Unabridged)")
        #expect(donor.indexedIdentifiers(of: serverA) == [record("li_1").id, record("li_2").id])
    }

    @Test func onlyTheMostRecentItemsAreKept() async {
        let donor = await makeDonor()

        for number in 0...RecentItemsDonor.limit { donor.donate(record("li_\(number)")) }
        await donor.settle()

        let newest = (1...RecentItemsDonor.limit).reversed().map { record("li_\($0)").id }
        #expect(donor.indexedIdentifiers(of: serverA) == newest)
        #expect(index.writes.last == .delete([record("li_0").id]))
        #expect(index.writes.filter { if case .delete = $0 { true } else { false } }.count == 1)
    }

    @Test func theLimitHoldsAcrossLaunches() async {
        let first = await makeDonor()
        for number in 1...RecentItemsDonor.limit { first.donate(record("li_\(number)")) }
        await first.settle()

        let relaunched = await makeDonor()
        relaunched.donate(record("li_new"))
        await relaunched.settle()

        #expect(relaunched.indexedIdentifiers(of: serverA).count == RecentItemsDonor.limit)
        #expect(relaunched.indexedIdentifiers(of: serverA).first == record("li_new").id)
        #expect(index.writes.last == .delete([record("li_1").id]))
    }

    // MARK: Deleting

    @Test(arguments: [SessionEndReason.signOut, .removed, .expired])
    func signingOutDeletesTheAccountsItems(reason: SessionEndReason) async {
        let donor = await makeDonor()
        donor.donate(record())

        await donor.sessionWillEnd(reason)
        await donor.settle()

        #expect(index.writes == [.index(record().id), .deleteDomain(serverA)])
        #expect(donor.indexedIdentifiers(of: serverA).isEmpty)
    }

    @Test func aSwitchKeepsTheAccountsItems() async {
        let donor = await makeDonor()
        donor.donate(record())

        await donor.sessionWillEnd(.switch)
        await donor.sessionDidStart(context(serverB))
        donor.donate(record("li_9", server: serverB))
        await donor.settle()

        #expect(index.writes == [.index(record().id), .index(record("li_9", server: serverB).id)])
        #expect(donor.indexedIdentifiers(of: serverA) == [record().id])
    }

    @Test func aSwitchAfterTheCredentialsExpiredDeletesTheItems() async {
        let donor = await makeDonor()
        donor.donate(record())

        donor.connectionExpired(serverA)
        await donor.settle()
        #expect(index.writes == [.index(record().id)])

        await donor.sessionWillEnd(.switch)
        await donor.settle()
        #expect(index.writes == [.index(record().id), .deleteDomain(serverA)])
    }

    @Test func anotherAccountsExpiryDeletesItsItemsOnly() async {
        let donor = await makeDonor(running: serverB)
        donor.donate(record("li_9", server: serverB))

        donor.connectionExpired(serverA)
        await donor.settle()

        #expect(index.writes == [.index(record("li_9", server: serverB).id), .deleteDomain(serverA)])
        #expect(donor.indexedIdentifiers(of: serverB) == [record("li_9", server: serverB).id])
    }

    @Test func removingAnotherAccountDeletesItsItems() async {
        let connections = FakeSavedConnections()
        connections.saved = [serverA, serverB]
        let donor = await makeDonor(running: serverB)
        donor.followRemovals { connections.saved }

        connections.saved = [serverB]

        #expect(await eventually { index.writes == [.deleteDomain(serverA)] })
    }

    @Test func aRejectedSwitchDeletesThatAccountsItems() async {
        let rejections = FakeRejections()
        let donor = await makeDonor(running: serverB)
        donor.followRejectedSwitches { (rejections.count, rejections.connectionID) }

        rejections.connectionID = serverA
        rejections.count = 1

        #expect(await eventually { index.writes == [.deleteDomain(serverA)] })
    }

    // MARK: Failures

    @Test func aFailedDeletionStaysPendingUntilARelaunchRetriesIt() async {
        let donor = await makeDonor()
        donor.donate(record())
        index.failing = [.deleteDomain]

        await donor.sessionWillEnd(.signOut)
        await donor.settle()

        #expect(index.writes == [.index(record().id), .deleteDomain(serverA)])
        #expect(donor.pendingDomainDeletions == [serverA])
        let pending = defaults.dictionary(forKey: RecentItemsDonor.pendingDomainsKey) as? [String: [String]]
        #expect(pending == [serverA.uuidString: [record().id]])

        index.failing = []
        index.clearWrites()
        let relaunched = await makeDonor(running: nil)
        await relaunched.settle()

        #expect(index.writes == [.deleteDomain(serverA)])
        #expect(relaunched.pendingDomainDeletions.isEmpty)
    }

    @Test func aStartingSessionRetriesAFailedDeletion() async {
        let donor = await makeDonor(running: serverB)
        index.failing = [.deleteDomain]
        donor.connectionExpired(serverA)
        await donor.settle()

        index.failing = []
        await donor.sessionWillEnd(.switch)
        await donor.sessionDidStart(context(serverB))
        await donor.settle()

        #expect(index.writes == [.deleteDomain(serverA), .deleteDomain(serverA)])
        #expect(donor.pendingDomainDeletions.isEmpty)
    }

    @Test func itemsPastTheLimitAreDeletedEvenIfIndexingFails() async {
        let donor = await makeDonor()
        for number in 1...RecentItemsDonor.limit { donor.donate(record("li_\(number)")) }
        await donor.settle()
        index.failing = [.index]
        index.clearWrites()

        donor.donate(record("li_new"))
        await donor.settle()

        #expect(index.writes == [.index(record("li_new").id), .delete([record("li_1").id])])
        #expect(donor.pendingEvictions(of: serverA).isEmpty)
    }

    @Test func aFailedEvictionStaysPendingUntilARelaunchRetriesIt() async {
        let donor = await makeDonor()
        for number in 1...RecentItemsDonor.limit { donor.donate(record("li_\(number)")) }
        index.failing = [.delete]
        donor.donate(record("li_new"))
        await donor.settle()
        #expect(donor.pendingEvictions(of: serverA) == [record("li_1").id])

        index.failing = []
        index.clearWrites()
        let relaunched = await makeDonor(running: nil)
        await relaunched.settle()

        #expect(index.writes == [.delete([record("li_1").id])])
        #expect(relaunched.pendingEvictions(of: serverA).isEmpty)
    }

    @Test func anEvictedItemPlayedAgainIsntEvictedLater() async {
        let donor = await makeDonor()
        for number in 1...RecentItemsDonor.limit { donor.donate(record("li_\(number)")) }
        index.failing = [.delete]
        donor.donate(record("li_new"))
        donor.donate(record("li_1"))
        await donor.settle()

        #expect(donor.pendingEvictions(of: serverA) == [record("li_2").id])
        #expect(donor.indexedIdentifiers(of: serverA).first == record("li_1").id)
    }

    // MARK: Accounts

    @Test func followingTheAccountsDeletesAnItemsOnceItsCredentialsAreRemoved() async throws {
        let accounts = try makeAccounts()
        let earlier = Calls()
        accounts.credentialsRemoved = { earlier.ids.append($0) }
        let donor = await makeDonor(running: serverB)
        donor.follow(accounts: accounts)

        await accounts.credentialsRemoved?(serverA)
        await donor.settle()

        #expect(earlier.ids == [serverA])
        #expect(index.writes == [.deleteDomain(serverA)])
    }

    @Test func followingTheAccountsDeletesTheItemsOfARestoreThatEndedSignedOut() async throws {
        let accounts = try makeAccounts()
        let earlier = Calls()
        accounts.restoreSignedOut = { earlier.ids.append($0) }
        let donor = await makeDonor(running: nil)
        donor.follow(accounts: accounts)

        accounts.restoreSignedOut?(serverA)
        await donor.settle()

        #expect(earlier.ids == [serverA])
        #expect(index.writes == [.deleteDomain(serverA)])
    }

    @Test func followingTheAccountsKeepsTheirExpiryCallback() async throws {
        let accounts = try makeAccounts()
        let earlier = Calls()
        accounts.credentialsExpired = { earlier.ids.append($0) }
        let donor = await makeDonor(running: serverB)
        donor.follow(accounts: accounts)

        accounts.credentialsExpired?(serverA)
        await donor.settle()

        #expect(earlier.ids == [serverA])
        #expect(index.writes == [.deleteDomain(serverA)])
    }

    private func makeAccounts() throws -> AccountManager {
        AccountManager(
            store: ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container),
            keychain: InMemoryKeychain(),
            validator: ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() }),
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
    }

    // MARK: Player

    @Test func thePlayersItemIsDonatedOnceItPlays() throws {
        let playback = FakePlaybackControl()
        let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        #expect(player.spotlightRecord == nil)

        // Loading, or restored without playing: not donated.
        playback.start(FakePlaybackControl.bookSession(), at: 50)
        #expect(player.spotlightRecord == nil)
        playback.load(FakePlaybackControl.bookSession(), at: 150)
        #expect(player.spotlightRecord == nil)

        playback.load(FakePlaybackControl.bookSession(), at: 150, playing: true)
        let donated = try #require(player.spotlightRecord)
        #expect(donated.key == MediaKey(serverConnectionID: FakePlaybackControl.serverID, libraryItemId: "li_book"))
        #expect(donated.kind == .book)
        #expect(donated.title == "Dune")
        #expect(donated.subtitle == "Frank Herbert")
        #expect(donated.duration == 400)
    }

    @Test func aRequestForAnotherItemDoesntDonateTheRestoredOne() {
        let playback = FakePlaybackControl()
        let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        playback.load(FakePlaybackControl.bookSession(), at: 150)

        // Another item waits on its streaming-policy check: play is requested, but this one is paused.
        playback.isPlaybackRequested = true

        #expect(player.spotlightRecord == nil)
    }

    @Test func followingThePlayerDonatesWhatStartsPlaying() async {
        let playback = FakePlaybackControl()
        let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        let donor = await makeDonor(running: FakePlaybackControl.serverID)
        donor.follow(player)

        playback.load(FakePlaybackControl.bookSession(), at: 0, playing: true)

        let key = MediaKey(serverConnectionID: FakePlaybackControl.serverID, libraryItemId: "li_book")
        #expect(await eventually { index.writes == [.index(key.rawValue)] })
    }
}
