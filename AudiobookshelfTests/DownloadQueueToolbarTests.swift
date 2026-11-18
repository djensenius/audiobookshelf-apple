import ABSAppModel
import Foundation
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct DownloadQueueToolbarTests {
    @Test func openPushesTheQueueOnItsTabOnce() {
        let router = Router()
        router[path: .home] = [.item(id: "li_1")]
        DownloadQueueToolbar.open(in: router, on: .home)
        DownloadQueueToolbar.open(in: router, on: .home)
        #expect(router[path: .home] == [.item(id: "li_1"), .downloadQueue])

        // Its own tab's stack, not the selected tab's.
        router.selectedTab = .home
        DownloadQueueToolbar.open(in: router, on: .account)
        #expect(router[path: .account] == [.downloadQueue])
        #expect(router.selectedTab == .home)

        DownloadQueueToolbar.open(in: nil, on: .home)
    }

    /// The ring hides its count from VoiceOver, so the value gives it, with the progress (#686).
    @Test func accessibilityValueHasTheCountAndProgress() {
        let english = Locale(identifier: "en_US")
        #expect(
            DownloadQueueToolbar.accessibilityValue(count: 1, fraction: 0.5, locale: english) == "1 download, 50% done")
        #expect(
            DownloadQueueToolbar.accessibilityValue(count: 3, fraction: 0, locale: english) == "3 downloads, 0% done")
    }

    /// It outranks the Library screen's filter and sort, so a crowded bar keeps it (#685).
    @Test func outranksTheLibraryControls() {
        #expect(DownloadQueueToolbar.visibilityPriority > .high)
    }
}
