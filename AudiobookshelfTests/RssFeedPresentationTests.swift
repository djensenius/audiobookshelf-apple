import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

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

    @Test(arguments: [(Bool?.some(true), "ButtonYes"), (false, "LabelNo"), (nil, "ButtonYes")])
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
}
