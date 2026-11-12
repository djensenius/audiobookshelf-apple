import ABSAppModel
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct BookmarksPresentationTests {
    private let locale = Locale(identifier: "en_US")

    private func mark(_ title: String = "Twist", at time: Double) -> AudioBookmark {
        AudioBookmark(libraryItemId: "li_preview", title: title, time: time)
    }

    @Test func rowTimeAtRate() {
        // Legacy shows the time divided by the rate: 6:00 of media is 4:00 at 1.5×.
        #expect(BookmarkRowPresentation(bookmark: mark(at: 360), rate: 1.5, locale: locale).timeText == "4:00")
        #expect(BookmarkRowPresentation(bookmark: mark(at: 3_900), rate: 1, locale: locale).timeText == "1:05:00")
        for rate in [0, -1, .nan, .infinity] {
            let fallback = BookmarkRowPresentation(bookmark: mark(at: 360), rate: rate, locale: locale)
            #expect(fallback.timeText == "6:00", "rate \(rate)")
        }
    }

    @Test func accessibilityLabelHasTitleAndTime() {
        let row = BookmarkRowPresentation(bookmark: mark("Twist", at: 3_725), rate: 1, locale: locale)
        #expect(row.title == "Twist")
        #expect(row.accessibilityLabel == "Twist, at 1 hour, 2 minutes, 5 seconds")
    }

    @Test func failureMessagesUseLegacyToasts() {
        #expect(BookmarkFailure.create.messageKey == "ToastBookmarkCreateFailed")
        #expect(BookmarkFailure.update.messageKey == "ToastBookmarkUpdateFailed")
        #expect(BookmarkFailure.remove.messageKey == "ToastBookmarkRemoveFailed")
    }

    @Test func editorTextFollowsTarget() {
        let new = BookmarkEditorPresentation(target: .create(itemID: "li_preview", time: 42, defaultTitle: "Now"))
        #expect(new.titleKey == "HeaderNewBookmark")
        #expect(new.submitKey == "ButtonCreate")
        #expect(new.initialTitle.isEmpty)
        #expect(new.time == 42)

        let edit = BookmarkEditorPresentation(target: .edit(mark("Old", at: 30)))
        #expect(edit.titleKey == "HeaderEditBookmark")
        #expect(edit.submitKey == "ButtonUpdate")
        #expect(edit.initialTitle == "Old")
        #expect(edit.time == 30)

        #expect(BookmarkEditorTarget.create(itemID: "li_preview", time: 42, defaultTitle: "Now").isCreate)
        #expect(!BookmarkEditorTarget.edit(mark("Old", at: 30)).isCreate)
        #expect(BookmarkEditorTarget.create(itemID: "li_preview", time: 42, defaultTitle: "Now").placeholder == "Now")
        #expect(BookmarkEditorTarget.edit(mark("Old", at: 30)).placeholder == "Old")
    }

    @Test func slotDisabledWithoutStore() {
        let slot = BookmarksSlotPresentation(player: .preview(), store: nil)
        #expect(slot.isVisible)
        #expect(!slot.isEnabled)
        #expect(slot.systemImage == "bookmark")
    }

    @Test func slotHiddenWithoutItem() {
        let slot = BookmarksSlotPresentation(player: .preview(loaded: false), store: BookmarkStore())
        #expect(!slot.isVisible)
        #expect(!slot.isEnabled)
    }

    @Test func slotDisabledWhenStoreUnavailable() {
        // A store with no session has no client.
        let slot = BookmarksSlotPresentation(player: .preview(), store: BookmarkStore())
        #expect(slot.isVisible)
        #expect(!slot.isEnabled)
    }

    @Test func slotFilledWithBookmarks() {
        let store = BookmarkStore()
        let player = PlayerViewModel.preview()
        #expect(BookmarksSlotPresentation(player: player, store: store).systemImage == "bookmark")
        store.replaceAll(from: User(id: "u", username: "u", bookmarks: [mark(at: 10)]))
        #expect(BookmarksSlotPresentation(player: player, store: store).systemImage == "bookmark.fill")
    }
}
