import ABSAppModel
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
}
