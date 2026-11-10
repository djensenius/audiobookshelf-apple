import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private func progress(
    _ itemID: String, episode: String? = nil, currentTime: Double = 0, lastUpdate: Int?
) -> MediaProgress {
    MediaProgress(
        id: "p-\(itemID)-\(episode ?? "")", libraryItemId: itemID, episodeId: episode, currentTime: currentTime,
        lastUpdate: lastUpdate)
}

@MainActor
@Suite struct ProgressCacheTests {
    @Test func seedKeysByItemAndEpisode() {
        let cache = ProgressCache()
        cache.seed([
            progress("book", currentTime: 1, lastUpdate: 10),
            progress("podcast", episode: "e1", currentTime: 2, lastUpdate: 10),
            progress("podcast", episode: "e2", currentTime: 3, lastUpdate: 10),
        ])

        #expect(cache.progress(libraryItemID: "book")?.currentTime == 1)
        #expect(cache.progress(libraryItemID: "podcast", episodeID: "e1")?.currentTime == 2)
        #expect(cache.progress(libraryItemID: "podcast", episodeID: "e2")?.currentTime == 3)
        #expect(cache.progress(libraryItemID: "podcast") == nil)
        #expect(cache.progress(libraryItemID: "book", episodeID: "") != nil)
    }

    @Test func applyKeepsTheNewerUpdate() {
        let cache = ProgressCache()
        #expect(cache.apply(progress("book", currentTime: 10, lastUpdate: 200)))

        // Older and undated updates never overwrite a newer one.
        #expect(!cache.apply(progress("book", currentTime: 5, lastUpdate: 100)))
        #expect(!cache.apply(progress("book", currentTime: 6, lastUpdate: nil)))
        #expect(cache.progress(libraryItemID: "book")?.currentTime == 10)

        #expect(cache.apply(progress("book", currentTime: 20, lastUpdate: 300)))
        #expect(cache.progress(libraryItemID: "book")?.currentTime == 20)
        // The same timestamp replaces.
        #expect(cache.apply(progress("book", currentTime: 21, lastUpdate: 300)))
        #expect(cache.progress(libraryItemID: "book")?.currentTime == 21)
    }

    @Test func undatedEntriesAreReplacedByAnyUpdate() {
        let cache = ProgressCache()
        cache.apply(progress("book", currentTime: 1, lastUpdate: nil))
        #expect(cache.apply(progress("book", currentTime: 2, lastUpdate: nil)))
        #expect(cache.apply(progress("book", currentTime: 3, lastUpdate: 1)))
        #expect(cache.progress(libraryItemID: "book")?.currentTime == 3)
    }

    @Test func seedReplacesTheCacheButKeepsNewerLocalUpdates() {
        let cache = ProgressCache()
        cache.apply(progress("played-locally", currentTime: 50, lastUpdate: 500))
        cache.apply(progress("stale-locally", currentTime: 5, lastUpdate: 100))
        cache.apply(progress("deleted-on-server", currentTime: 1, lastUpdate: 100))

        cache.seed([
            progress("played-locally", currentTime: 40, lastUpdate: 400),
            progress("stale-locally", currentTime: 9, lastUpdate: 200),
            progress("new", currentTime: 7, lastUpdate: 100),
            // Duplicate rows in the seed: the newer one wins regardless of order.
            progress("dup", currentTime: 2, lastUpdate: 20),
            progress("dup", currentTime: 1, lastUpdate: 10),
        ])

        #expect(cache.progress(libraryItemID: "played-locally")?.currentTime == 50)
        #expect(cache.progress(libraryItemID: "stale-locally")?.currentTime == 9)
        #expect(cache.progress(libraryItemID: "new")?.currentTime == 7)
        #expect(cache.progress(libraryItemID: "dup")?.currentTime == 2)
        #expect(cache.progress(libraryItemID: "deleted-on-server") == nil)
        #expect(cache.entries.count == 4)
    }

    @Test func removeAndClear() {
        let cache = ProgressCache()
        cache.seed([progress("a", lastUpdate: 1), progress("p", episode: "e", lastUpdate: 1)])

        cache.remove(libraryItemID: "p", episodeID: "e")
        #expect(cache.progress(libraryItemID: "p", episodeID: "e") == nil)
        #expect(cache.progress(libraryItemID: "a") != nil)

        cache.clear()
        #expect(cache.entries.isEmpty)
    }
}
