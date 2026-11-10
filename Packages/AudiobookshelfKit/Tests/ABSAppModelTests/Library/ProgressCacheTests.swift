import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

private func progress(
    _ itemID: String, episode: String? = nil, currentTime: Double = 0, lastUpdate: Int?
) -> MediaProgress {
    MediaProgress(
        id: "p-\(itemID)-\(episode ?? "")", libraryItemId: itemID, episodeId: episode, currentTime: currentTime,
        lastUpdate: lastUpdate)
}

/// A request time in epoch milliseconds.
private func at(_ milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

@MainActor
@Suite struct ProgressCacheTests {
    @Test func seedKeysByItemAndEpisode() {
        let cache = ProgressCache()
        cache.seed(
            [
                progress("book", currentTime: 1, lastUpdate: 10),
                progress("podcast", episode: "e1", currentTime: 2, lastUpdate: 10),
                progress("podcast", episode: "e2", currentTime: 3, lastUpdate: 10),
            ], fetchedAt: at(10))

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

    @Test func seedKeepsNewerCachedEntries() {
        let cache = ProgressCache()
        cache.apply(progress("played-locally", currentTime: 50, lastUpdate: 500))
        cache.apply(progress("stale-locally", currentTime: 5, lastUpdate: 100))
        cache.apply(progress("tie", currentTime: 1, lastUpdate: 300))
        cache.apply(progress("dated", currentTime: 8, lastUpdate: 300))

        cache.seed(
            [
                progress("played-locally", currentTime: 40, lastUpdate: 400),
                progress("stale-locally", currentTime: 9, lastUpdate: 200),
                // A tie goes to the server's row.
                progress("tie", currentTime: 2, lastUpdate: 300),
                // An undated row never replaces a dated entry.
                progress("dated", currentTime: 0, lastUpdate: nil),
                progress("new", currentTime: 7, lastUpdate: 100),
            ], fetchedAt: at(1000))

        #expect(cache.progress(libraryItemID: "played-locally")?.currentTime == 50)
        #expect(cache.progress(libraryItemID: "stale-locally")?.currentTime == 9)
        #expect(cache.progress(libraryItemID: "tie")?.currentTime == 2)
        #expect(cache.progress(libraryItemID: "dated")?.currentTime == 8)
        #expect(cache.progress(libraryItemID: "new")?.currentTime == 7)
    }

    @Test func seedDuplicatesKeepTheNewerRowInEitherOrder() {
        let cache = ProgressCache()
        cache.seed(
            [
                progress("newer-first", currentTime: 2, lastUpdate: 20),
                progress("newer-first", currentTime: 1, lastUpdate: 10),
                progress("older-first", currentTime: 1, lastUpdate: 10),
                progress("older-first", currentTime: 2, lastUpdate: 20),
            ], fetchedAt: at(100))

        #expect(cache.progress(libraryItemID: "newer-first")?.currentTime == 2)
        #expect(cache.progress(libraryItemID: "older-first")?.currentTime == 2)
    }

    @Test func seedKeepsEntriesAppliedAfterTheRequest() {
        let cache = ProgressCache()
        cache.apply(progress("deleted-on-server", lastUpdate: 900))
        cache.apply(progress("same-millisecond", lastUpdate: 1000))
        cache.apply(progress("undated", lastUpdate: nil))
        // `/api/me` was requested at 1000; meanwhile playback started an item with no server
        // progress, which the response therefore doesn't contain.
        cache.apply(progress("started-meanwhile", currentTime: 3, lastUpdate: 1500))

        cache.seed([progress("on-server", lastUpdate: 800)], fetchedAt: at(1000))

        #expect(cache.progress(libraryItemID: "started-meanwhile")?.currentTime == 3)
        #expect(cache.progress(libraryItemID: "on-server") != nil)
        #expect(cache.progress(libraryItemID: "deleted-on-server") == nil)
        #expect(cache.progress(libraryItemID: "same-millisecond") == nil)
        #expect(cache.progress(libraryItemID: "undated") == nil)
        #expect(cache.storedKeys == ["started-meanwhile", "on-server"])
    }

    @Test func removeAndClear() {
        let cache = ProgressCache()
        cache.seed([progress("a", lastUpdate: 1), progress("p", episode: "e", lastUpdate: 1)], fetchedAt: at(1))

        cache.remove(libraryItemID: "p", episodeID: "e")
        #expect(cache.progress(libraryItemID: "p", episodeID: "e") == nil)
        #expect(cache.progress(libraryItemID: "a") != nil)

        cache.clear()
        #expect(cache.storedKeys.isEmpty)
        #expect(cache.progress(libraryItemID: "a") == nil)
    }

    @Test func observationIsPerKey() {
        let cache = ProgressCache()
        cache.apply(progress("b", lastUpdate: 1))

        func observe(_ key: String) -> Locked<Bool> {
            let changed = Locked(false)
            withObservationTracking {
                _ = cache.progress(libraryItemID: key)
            } onChange: {
                changed.value = true
            }
            return changed
        }

        let readerOfB = observe("b")
        let readerOfC = observe("c")  // not cached yet
        cache.apply(progress("a", lastUpdate: 2))
        cache.seed([progress("a", lastUpdate: 2), progress("b", lastUpdate: 1)], fetchedAt: at(2))
        #expect(!readerOfB.value)
        #expect(!readerOfC.value)

        cache.apply(progress("c", lastUpdate: 3))
        #expect(readerOfC.value)
        #expect(!readerOfB.value)

        cache.apply(progress("b", lastUpdate: 4))
        #expect(readerOfB.value)

        // Removal by a seed and clearing notify readers too.
        let rereadB = observe("b")
        cache.seed([progress("a", lastUpdate: 2)], fetchedAt: at(10))
        #expect(rereadB.value)
        let readerOfA = observe("a")
        cache.clear()
        #expect(readerOfA.value)
    }
}
