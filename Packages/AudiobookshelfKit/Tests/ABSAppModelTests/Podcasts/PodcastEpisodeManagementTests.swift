import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A ``PodcastEpisodeManagementService`` whose responses come from closures, recording what it was
/// asked.
private struct FakeEpisodeManagementService: PodcastEpisodeManagementService {
    var feed: @Sendable (String) async throws -> [RSSFeedEpisode] = { _ in [] }
    var download: @Sendable (String, [RSSFeedEpisode]) async throws -> Void = { _, _ in }
    var clear: @Sendable (String) async throws -> Void = { _ in }
    var remove: @Sendable (String, String, Bool) async throws -> Void = { _, _, _ in }

    func feedEpisodes(rssFeed: String) async throws -> [RSSFeedEpisode] { try await feed(rssFeed) }
    func downloadEpisodes(podcastID: String, episodes: [RSSFeedEpisode]) async throws {
        try await download(podcastID, episodes)
    }
    func clearDownloadQueue(podcastID: String) async throws { try await clear(podcastID) }
    func removeEpisode(podcastID: String, episodeID: String, deleteFile: Bool) async throws {
        try await remove(podcastID, episodeID, deleteFile)
    }
}

private func feedEpisode(_ url: String, title: String = "", publishedAt: Int? = nil, extra: String = "")
    -> RSSFeedEpisode
{
    let date = publishedAt.map { #","publishedAt":\#($0)"# } ?? ""
    let json = #"{"enclosure":{"url":"\#(url)"},"title":"\#(title)"\#(date)\#(extra)}"#
    return try! JSONDecoder().decode(RSSFeedEpisode.self, from: Data(json.utf8))
}

private func podcast(feedURL: String? = "https://example.com/feed.xml") -> Podcast {
    Podcast(id: "pod-1", metadata: PodcastMetadata(title: "Show", feedUrl: feedURL))
}

private func user(
    _ type: UserType, update: Bool = true, delete: Bool = true, isActive: Bool = true
) -> User {
    User(
        id: "u", username: "u", type: type, isActive: isActive,
        permissions: UserPermissions(update: update, delete: delete))
}

private let everything = PodcastEpisodeManagementAccess(
    canFindEpisodes: true, canClearDownloadQueue: true, canRemoveEpisodes: true)

@Suite struct PodcastEpisodeManagementAccessTests {
    @Test(arguments: [UserType.admin, .root])
    func adminsWithPermissionsGetEverything(type: UserType) {
        let access = PodcastEpisodeManagementAccess(user: user(type), podcast: podcast(), isGone: false)
        #expect(
            access
                == PodcastEpisodeManagementAccess(
                    canFindEpisodes: true, canClearDownloadQueue: true, canRemoveEpisodes: true))
        #expect(access.offersAny)
    }

    /// Legacy offered none of these to other users; the server refuses the feed lookup and the
    /// queue to them.
    @Test(arguments: [UserType.user, .guest, .unknown("editor")])
    func nonAdminsGetNothing(type: UserType) {
        let access = PodcastEpisodeManagementAccess(user: user(type), podcast: podcast(), isGone: false)
        #expect(access == .none)
        #expect(!access.offersAny)
    }

    @Test func findingEpisodesNeedsUpdateAndAFeedURL() {
        #expect(
            !PodcastEpisodeManagementAccess(user: user(.admin, update: false), podcast: podcast(), isGone: false)
                .canFindEpisodes)
        for feedURL in [nil, "", "  "] {
            let access = PodcastEpisodeManagementAccess(
                user: user(.admin), podcast: podcast(feedURL: feedURL), isGone: false)
            #expect(!access.canFindEpisodes)
            #expect(access.canClearDownloadQueue)
        }
    }

    @Test func removingNeedsDelete() {
        let access = PodcastEpisodeManagementAccess(
            user: user(.admin, delete: false), podcast: podcast(), isGone: false)
        #expect(!access.canRemoveEpisodes)
        #expect(access.canFindEpisodes)
    }

    @Test func nothingWhenInactiveOfflineGoneOrUnloaded() {
        #expect(
            PodcastEpisodeManagementAccess(user: user(.root, isActive: false), podcast: podcast(), isGone: false)
                == .none)
        #expect(PodcastEpisodeManagementAccess(user: nil, podcast: podcast(), isGone: false) == .none)
        #expect(PodcastEpisodeManagementAccess(user: user(.root), podcast: podcast(), isGone: true) == .none)
        #expect(PodcastEpisodeManagementAccess(user: user(.root), podcast: nil, isGone: false) == .none)
    }
}

@MainActor
@Suite struct PodcastFeedEpisodesModelTests {
    private func makeModel(
        library: [String] = [], feed: [RSSFeedEpisode],
        download: @escaping @Sendable (String, [RSSFeedEpisode]) async throws -> Void = { _, _ in }
    ) -> PodcastFeedEpisodesModel {
        let episodes = library.enumerated().map { index, url in
            PodcastEpisode(id: "ep-\(index)", enclosure: PodcastEpisodeEnclosure(url: url))
        }
        return PodcastFeedEpisodesModel(
            podcastID: "li-1", feedURL: "https://example.com/feed.xml", libraryEpisodes: episodes,
            service: FakeEpisodeManagementService(feed: { _ in feed }, download: download))
    }

    @Test func sortsNewestFirstWithUndatedLast() async {
        let model = makeModel(feed: [
            feedEpisode("a", publishedAt: 1), feedEpisode("u1"), feedEpisode("c", publishedAt: 3),
            feedEpisode("u2"), feedEpisode("b", publishedAt: 2),
        ])
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.rows.map(\.episode.enclosureURL) == ["c", "b", "a", "u1", "u2"])
        #expect(model.rows.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func passesTheFeedURL() async {
        let asked = Locked<String?>(nil)
        let model = PodcastFeedEpisodesModel(
            podcastID: "li-1", feedURL: "https://example.com/feed.xml", libraryEpisodes: [],
            service: FakeEpisodeManagementService(feed: { url in
                asked.value = url
                return []
            }))
        await model.load()
        #expect(asked.value == "https://example.com/feed.xml")
    }

    /// An episode whose enclosure URL the library has is marked and can't be selected, even by
    /// Select All.
    @Test func marksLibraryEpisodesAndKeepsThemUnselectable() async {
        let model = makeModel(
            library: [" https://x/1.mp3 ", "https://x/other.mp3"],
            feed: [feedEpisode("https://x/1.mp3", publishedAt: 2), feedEpisode("https://x/2.mp3", publishedAt: 1)])
        await model.load()
        #expect(model.rows.map(\.isInLibrary) == [true, false])
        model.toggle(0)
        #expect(model.selection.isEmpty)
        model.toggle(1)
        #expect(model.selection == [1])
        model.toggle(1)
        #expect(model.selection.isEmpty)
        model.toggleAll()
        #expect(model.selection == [1])
        #expect(model.isAllSelected)
        model.toggleAll()
        #expect(model.selection.isEmpty)
        model.toggle(7)
        #expect(model.selection.isEmpty)
    }

    /// Episodes the server downloaded after the sheet opened are marked once the podcast
    /// reloads, and leave the selection.
    @Test func updatedLibraryEpisodesAreMarkedAndDeselected() async {
        let model = makeModel(
            library: ["https://x/0.mp3"],
            feed: [
                feedEpisode("https://x/1.mp3", publishedAt: 3), feedEpisode("https://x/2.mp3", publishedAt: 2),
                feedEpisode("https://x/0.mp3", publishedAt: 1),
            ])
        await model.load()
        model.toggleAll()
        #expect(model.selection == [0, 1])
        model.updateLibraryEpisodes([
            PodcastEpisode(id: "ep-0", enclosure: PodcastEpisodeEnclosure(url: "https://x/0.mp3")),
            PodcastEpisode(id: "ep-1", enclosure: PodcastEpisodeEnclosure(url: " https://x/1.mp3 ")),
        ])
        #expect(model.rows.map(\.isInLibrary) == [true, false, true])
        #expect(model.selection == [1])
        #expect(model.isAllSelected)
    }

    @Test func everythingInTheLibraryOffersNoSelection() async {
        let model = makeModel(library: ["a"], feed: [feedEpisode("a")])
        await model.load()
        #expect(!model.isAllSelected)
        model.toggleAll()
        #expect(model.selection.isEmpty)
        #expect(!model.canDownload)
    }

    @Test func downloadSendsTheSelectedEpisodesInListOrder() async {
        let sent = Locked<(String, [String])?>(nil)
        let model = makeModel(
            feed: [
                feedEpisode("a", publishedAt: 1), feedEpisode("b", publishedAt: 2), feedEpisode("c", publishedAt: 3),
            ]
        ) { podcastID, episodes in
            sent.value = (podcastID, episodes.map(\.enclosureURL))
        }
        await model.load()
        #expect(await model.download() == .ignored)
        model.toggle(2)
        model.toggle(0)
        #expect(model.canDownload)
        #expect(await model.download() == .queued(count: 2))
        #expect(sent.value?.0 == "li-1")
        #expect(sent.value?.1 == ["c", "a"])
        #expect(model.selection.isEmpty)
        #expect(!model.isDownloading)
    }

    @Test func failedDownloadClearsTheSelection() async {
        let model = makeModel(feed: [feedEpisode("a")]) { _, _ in throw TestError.offline }
        await model.load()
        model.toggle(0)
        #expect(await model.download() == .failed)
        #expect(model.selection.isEmpty)
    }

    @Test func oversizedRequestIsRefusedAndKeepsTheSelection() async {
        let called = Locked(false)
        let big = String(repeating: "x", count: PodcastFeedEpisodesModel.maxRequestBytes)
        let model = makeModel(feed: [feedEpisode("a", extra: #","description":"\#(big)""#)]) { _, _ in
            called.value = true
        }
        await model.load()
        model.toggle(0)
        #expect(await model.download() == .tooLarge)
        #expect(!called.value)
        #expect(model.selection == [0])
    }

    @Test func failedLoadCanBeRetried() async {
        let attempts = Locked(0)
        let model = PodcastFeedEpisodesModel(
            podcastID: "li-1", feedURL: "f", libraryEpisodes: [],
            service: FakeEpisodeManagementService(feed: { _ in
                attempts.value += 1
                if attempts.value == 1 { throw TestError.offline }
                return [feedEpisode("a")]
            }))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.rows.isEmpty)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.rows.count == 1)
    }

    /// A second download while one is in flight sends nothing, and the selection can't change
    /// meanwhile.
    @Test func oneDownloadAtATime() async throws {
        let gate = GatedCalls<[String], Void>()
        let count = Locked(0)
        // Only the first call waits, so a broken guard fails the test instead of hanging it.
        let model = makeModel(feed: [feedEpisode("a", publishedAt: 2), feedEpisode("b", publishedAt: 1)]) {
            _, episodes in
            count.value += 1
            if count.value == 1 { try await gate.call(episodes.map(\.enclosureURL)) }
        }
        await model.load()
        model.toggle(0)
        let first = Task { await model.download() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        #expect(call.request == ["a"])
        #expect(model.isDownloading)
        #expect(!model.canDownload)
        model.toggle(1)
        model.toggleAll()
        #expect(model.selection == [0])
        #expect(await model.download() == .ignored)
        #expect(count.value == 1)
        call.reply.resume()
        #expect(await first.value == .queued(count: 1))
        #expect(!model.isDownloading)
    }
}

@MainActor
@Suite struct PodcastEpisodeActionsModelTests {
    @Test func clearAndRemoveReachTheService() async {
        let log = Locked<[String]>([])
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1", access: everything,
            service: FakeEpisodeManagementService(
                clear: { log.value.append("clear \($0)") },
                remove: { log.value.append("remove \($0) \($1) \($2)") }))
        #expect(await model.clearDownloadQueue() == true)
        #expect(await model.removeEpisode("ep-1", deleteFile: true) == true)
        #expect(await model.removeEpisode("ep-2", deleteFile: false) == true)
        #expect(log.value == ["clear li-1", "remove li-1 ep-1 true", "remove li-1 ep-2 false"])
    }

    @Test func failuresReportFalse() async {
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1", access: everything,
            service: FakeEpisodeManagementService(
                clear: { _ in throw TestError.offline }, remove: { _, _, _ in throw TestError.offline }))
        #expect(await model.clearDownloadQueue() == false)
        #expect(await model.removeEpisode("ep-1", deleteFile: false) == false)
        #expect(!model.isBusy)
    }

    @Test func oneActionAtATime() async throws {
        let gate = GatedCalls<String, Void>()
        let removed = Locked(false)
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1", access: everything,
            service: FakeEpisodeManagementService(
                clear: { try await gate.call($0) }, remove: { _, _, _ in removed.value = true }))
        let first = Task { await model.clearDownloadQueue() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        #expect(model.isBusy)
        #expect(!model.canClearDownloadQueue)
        #expect(!model.canRemoveEpisodes)
        #expect(await model.removeEpisode("ep-1", deleteFile: true) == nil)
        #expect(!removed.value)
        call.reply.resume()
        #expect(await first.value == true)
        #expect(!model.isBusy)
        #expect(model.canClearDownloadQueue)
        #expect(model.canRemoveEpisodes)
    }

    /// Access lost while a confirmation was open (a same-account reconnect clearing the user)
    /// sends nothing.
    @Test func clearAndRemoveRecheckAccess() async {
        let log = Locked<[String]>([])
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1", access: everything,
            service: FakeEpisodeManagementService(
                clear: { log.value.append("clear \($0)") }, remove: { _, episode, _ in log.value.append(episode) }))
        model.access = PodcastEpisodeManagementAccess(
            canFindEpisodes: true, canClearDownloadQueue: false, canRemoveEpisodes: true)
        #expect(!model.canClearDownloadQueue)
        #expect(await model.clearDownloadQueue() == nil)
        model.access = .none
        #expect(!model.canRemoveEpisodes)
        #expect(await model.removeEpisode("ep-1", deleteFile: true) == nil)
        #expect(log.value.isEmpty)
    }

    @Test func feedOpensOnlyWhenAllowedWithAFeedURL() {
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1",
            access: PodcastEpisodeManagementAccess(
                canFindEpisodes: false, canClearDownloadQueue: true, canRemoveEpisodes: true),
            service: FakeEpisodeManagementService())
        #expect(model.openFeed(podcast: podcast(), libraryEpisodes: []) == nil)
        #expect(model.feed == nil)
        model.access = everything
        #expect(model.openFeed(podcast: podcast(feedURL: " "), libraryEpisodes: []) == nil)
        let feed = model.openFeed(podcast: podcast(), libraryEpisodes: [])
        #expect(feed != nil)
        #expect(model.feed === feed)
        #expect(feed?.feedURL == "https://example.com/feed.xml")
        model.closeFeed()
        #expect(model.feed == nil)
    }

    @Test func feedClosesWhenFindingIsNoLongerAllowed() {
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1", access: everything, service: FakeEpisodeManagementService())
        model.openFeed(podcast: podcast(), libraryEpisodes: [])
        model.access = PodcastEpisodeManagementAccess(
            canFindEpisodes: true, canClearDownloadQueue: false, canRemoveEpisodes: false)
        #expect(model.feed != nil)
        model.access = .none
        #expect(model.feed == nil)
    }

    /// A reconnect closes the feed made with the old client; a reopened feed uses the new one.
    @Test func feedClosesOnReconnectAndReopensWithTheNewService() async {
        let log = Locked<[String]>([])
        let model = PodcastEpisodeActionsModel(
            podcastID: "li-1", access: everything,
            service: FakeEpisodeManagementService(feed: { _ in
                log.value.append("old")
                return []
            }))
        model.openFeed(podcast: podcast(), libraryEpisodes: [])
        model.replaceService(
            FakeEpisodeManagementService(feed: { _ in
                log.value.append("new")
                return []
            }))
        #expect(model.feed == nil)
        await model.openFeed(podcast: podcast(), libraryEpisodes: [])?.load()
        #expect(log.value == ["new"])
    }
}
