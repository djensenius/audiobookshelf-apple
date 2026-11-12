import ABSAPI
import ABSAppModel
import ABSCore
import ABSRealtime
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

/// Answers the current feed with `open`; nothing else is asked for.
private struct StubRssFeedService: RssFeedService {
    var open: RssFeed?

    func serverURL() async -> URL { URL(string: "https://abs.example")! }
    func currentFeed(for target: RssFeedTarget) async throws -> RssFeed? { open }
    func openFeed(for target: RssFeedTarget, _ request: RssFeedOpenRequest) async throws -> RssFeed {
        throw CancellationError()
    }
    func closeFeed(id: String) async throws {}
}

@Suite struct RssFeedPresentationTests {
    @Test(arguments: [
        (UserType.root, true, true), (.admin, true, true), (.admin, false, false), (.user, true, false),
        (.guest, true, false),
    ])
    func theEntryShowsForAdminsWithAClient(type: UserType, hasClient: Bool, shows: Bool) {
        #expect(RssFeedPresentation.showsEntry(userType: type, hasClient: hasClient) == shows)
    }

    @Test func offlineHidesTheEntry() {
        #expect(!RssFeedPresentation.showsEntry(userType: nil, hasClient: true))
    }

    @Test func onlyCollectionsGetAGroupFeed() {
        #expect(RssFeedPresentation.target(.collection, id: "c1") == RssFeedTarget(.collection, id: "c1"))
        #expect(RssFeedPresentation.target(.playlist, id: "p1") == nil)
    }

    @Test(arguments: [
        (RssFeedModelError.slugRequired, "MessageRSSFeedSlugRequired", String?.none),
        (.slugChanged, "MessageRSSFeedSlugChanged", nil), (.invalidOwnerEmail, "MessageRSSFeedInvalidOwnerEmail", nil),
        (.loadFailed, "MessageRSSFeedLoadFailed", nil), (.openFailed(message: nil), "MessageRSSFeedOpenFailed", nil),
        (.openFailed(message: "Slug already in use"), "MessageRSSFeedOpenFailed", "Slug already in use"),
        (.closeFailed, "ToastRSSFeedCloseFailed", nil),
    ])
    func everyFailureHasALocalizedMessage(error: RssFeedModelError, key: String, detail: String?) {
        let message = RssFeedPresentation.message(for: error)
        #expect(message.key == key)
        #expect(message.detail == detail)
        // A key missing from the catalog resolves to itself.
        #expect(L10n.string(message.key, locale: Locale(identifier: "en")) != message.key)
    }

    @Test func theAnnouncementAddsTheServersReason() {
        let english = Locale(identifier: "en")
        let failed = L10n.string("MessageRSSFeedOpenFailed", locale: english)
        #expect(
            RssFeedPresentation.announcement(for: .openFailed(message: "Slug already in use"), locale: english)
                == failed + " Slug already in use")
        #expect(RssFeedPresentation.announcement(for: .openFailed(message: nil), locale: english) == failed)
        #expect(
            RssFeedPresentation.announcement(for: .slugChanged, locale: english)
                == L10n.string("MessageRSSFeedSlugChanged", locale: english))
    }

    @Test(arguments: [(Bool?.some(true), "ButtonYes"), (false, "LabelNo"), (nil, "LabelNo")])
    func preventIndexingReadsYesOrNo(flag: Bool?, key: String) {
        let feed = RssFeed(
            id: "f", entityType: "series", entityId: "s", feedUrl: "/feed/s", meta: .init(preventIndexing: flag))
        #expect(RssFeedPresentation.preventIndexingKey(feed) == key)
        #expect(L10n.string(key, locale: Locale(identifier: "en")) != key)
    }

    @Test func onlyProgressShowsUntilTheFeedIsKnown() {
        #expect(RssFeedPresentation.isLoading(.idle))
        #expect(RssFeedPresentation.isLoading(.loading))
        #expect(!RssFeedPresentation.isLoading(.loaded))
        #expect(!RssFeedPresentation.isLoading(.failed))
    }

    @Test func theSheetsLegacyStringsResolve() {
        let keys = [
            "HeaderRSSFeed", "HeaderOpenRSSFeed", "HeaderRSSFeedIsOpen", "LabelRSSFeedSlug", "MessageFeedURLWillBe",
            "LabelRSSFeedPreventIndexing", "LabelPreventIndexing", "LabelRSSFeedCustomOwnerName",
            "LabelRSSFeedCustomOwnerEmail", "HeaderAdvanced", "NoteRSSFeedPodcastAppsHttps", "ButtonOpenFeed",
            "ButtonCloseFeed", "ButtonCopyFeedURL", "MessageFeedURLCopied", "ToastRSSFeedCloseSuccess",
        ]
        for key in keys {
            #expect(L10n.string(key, locale: Locale(identifier: "en")) != key, "\(key)")
        }
        #expect(
            L10n.string("MessageFeedURLWillBe", "https://abs.example/feed/s", locale: Locale(identifier: "en"))
                == "Feed URL will be https://abs.example/feed/s")
    }

    /// A feed carried over from the last sheet isn't offered for closing when the lookup failed: another
    /// client may have replaced it.
    @Test func aFailedLookupShowsRetryBeforeAnyFeed() {
        let feed = RssFeed(id: "feed-1", entityType: "libraryItem", entityId: "li-1", feedUrl: "/feed/li-1")
        #expect(RssFeedPresentation.content(.failed, feed: feed) == .retry)
        #expect(RssFeedPresentation.content(.failed, feed: nil) == .retry)
        #expect(RssFeedPresentation.content(.idle, feed: feed) == .loading)
        #expect(RssFeedPresentation.content(.loading, feed: nil) == .loading)
        #expect(RssFeedPresentation.content(.loaded, feed: feed) == .open(feed))
        #expect(RssFeedPresentation.content(.loaded, feed: nil) == .openForm)
    }

    /// A failed lookup with a carried-over feed doesn't read as open.
    @Test func onlyTheOpenFeedReadsAsOpen() {
        let feed = RssFeed(id: "feed-1", entityType: "libraryItem", entityId: "li-1", feedUrl: "/feed/li-1")
        let failed = RssFeedPresentation.content(.failed, feed: feed)
        #expect(failed.titleKey == "HeaderOpenRSSFeed")
        #expect(failed.dismissKey == "ButtonCancel")
        let open = RssFeedPresentation.content(.loaded, feed: feed)
        #expect(open.titleKey == "HeaderRSSFeedIsOpen")
        #expect(open.dismissKey == "ButtonDone")
        for content in [RssFeedPresentation.Content.loading, .openForm] {
            #expect(content.titleKey == "HeaderOpenRSSFeed")
            #expect(content.dismissKey == "ButtonCancel")
        }
    }

    /// What the screen fetched shows until the sheet knows better.
    @MainActor
    @Test func theIndicatorFollowsTheSheetOnceItKnows() async {
        let target = RssFeedTarget(.item, id: "li-1")
        let feed = RssFeed(id: "feed-1", entityType: "libraryItem", entityId: "li-1", feedUrl: "/feed/li-1")
        #expect(RssFeedPresentation.showsOpen(fetched: true, model: nil))
        #expect(!RssFeedPresentation.showsOpen(fetched: false, model: nil))

        let closedNow = RssFeedModel(target: target, service: StubRssFeedService(open: nil))
        #expect(RssFeedPresentation.showsOpen(fetched: true, model: closedNow))
        await closedNow.load()
        #expect(!RssFeedPresentation.showsOpen(fetched: true, model: closedNow))

        let openedLive = RssFeedModel(target: target, service: StubRssFeedService(open: nil))
        openedLive.apply(.opened(feed))
        #expect(RssFeedPresentation.showsOpen(fetched: false, model: openedLive))

        // A live close before any load answers.
        let closedLive = RssFeedModel(target: target, service: StubRssFeedService(open: feed))
        closedLive.apply(.closed(feed))
        #expect(!RssFeedPresentation.showsOpen(fetched: true, model: closedLive))

        // The next sheet starts from the last one's state, not the screen's stale fetch.
        let reopened = RssFeedModel(target: target, service: StubRssFeedService(open: feed))
        reopened.seed(from: closedNow)
        #expect(!RssFeedPresentation.showsOpen(fetched: true, model: reopened))
    }
}
