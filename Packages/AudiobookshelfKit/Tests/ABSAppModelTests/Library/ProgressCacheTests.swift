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

@MainActor
@Suite struct ProgressCacheTests {
    @Test func seedKeysByItemAndEpisode() {
        let cache = ProgressCache()
        cache.seed(
            [
                progress("book", currentTime: 1, lastUpdate: 10),
                progress("podcast", episode: "e1", currentTime: 2, lastUpdate: 10),
                progress("podcast", episode: "e2", currentTime: 3, lastUpdate: 10),
            ], token: cache.beginSeed())

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
            ], token: cache.beginSeed())

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
            ], token: cache.beginSeed())

        #expect(cache.progress(libraryItemID: "newer-first")?.currentTime == 2)
        #expect(cache.progress(libraryItemID: "older-first")?.currentTime == 2)
    }

    @Test func seedKeepsEntriesAppliedAfterTheRequest() {
        let cache = ProgressCache()
        cache.apply(progress("deleted-on-server", lastUpdate: 900))
        // A clock far ahead doesn't keep an entry applied before the request.
        cache.apply(progress("clock-ahead", lastUpdate: 9_999_999))
        cache.apply(progress("undated-before", lastUpdate: nil))
        let token = cache.beginSeed()
        // While `/api/me` is in flight, playback starts items with no server progress, so the
        // response doesn't contain them, whatever their timestamps.
        cache.apply(progress("started-meanwhile", currentTime: 3, lastUpdate: 1500))
        cache.apply(progress("undated-meanwhile", currentTime: 4, lastUpdate: nil))
        cache.apply(progress("server-clock-behind", currentTime: 5, lastUpdate: 1))

        cache.seed([progress("on-server", lastUpdate: 800)], token: token)

        #expect(cache.progress(libraryItemID: "started-meanwhile")?.currentTime == 3)
        #expect(cache.progress(libraryItemID: "undated-meanwhile")?.currentTime == 4)
        #expect(cache.progress(libraryItemID: "server-clock-behind")?.currentTime == 5)
        #expect(cache.progress(libraryItemID: "on-server") != nil)
        #expect(cache.progress(libraryItemID: "deleted-on-server") == nil)
        #expect(cache.progress(libraryItemID: "clock-ahead") == nil)
        #expect(cache.progress(libraryItemID: "undated-before") == nil)
        #expect(
            cache.storedKeys == ["started-meanwhile", "undated-meanwhile", "server-clock-behind", "on-server"])
    }

    @Test func seedRowsAgainstEntriesAppliedAfterTheRequest() {
        let cache = ProgressCache()
        let token = cache.beginSeed()
        cache.apply(progress("undated", currentTime: 1, lastUpdate: nil))
        cache.apply(progress("older-row", currentTime: 2, lastUpdate: 500))
        cache.apply(progress("tie", currentTime: 3, lastUpdate: 500))
        cache.apply(progress("newer-row", currentTime: 4, lastUpdate: 500))

        cache.seed(
            [
                // A dated row doesn't replace an undated local update made after the request.
                progress("undated", currentTime: 10, lastUpdate: 100),
                progress("older-row", currentTime: 20, lastUpdate: 400),
                progress("tie", currentTime: 30, lastUpdate: 500),
                // The server got a later update (for example from another device).
                progress("newer-row", currentTime: 40, lastUpdate: 600),
            ], token: token)

        #expect(cache.progress(libraryItemID: "undated")?.currentTime == 1)
        #expect(cache.progress(libraryItemID: "older-row")?.currentTime == 2)
        #expect(cache.progress(libraryItemID: "tie")?.currentTime == 3)
        #expect(cache.progress(libraryItemID: "newer-row")?.currentTime == 40)
    }

    @Test func anOlderSnapshotNeverOverwritesANewerSeed() {
        let cache = ProgressCache()
        let older = cache.beginSeed()
        let newer = cache.beginSeed()

        #expect(cache.seed([progress("a", currentTime: 2, lastUpdate: 20)], token: newer))
        // The older response arrives last, without `a` and with a row the server since deleted.
        #expect(!cache.seed([progress("deleted", lastUpdate: 10)], token: older))
        #expect(cache.storedKeys == ["a"])
        #expect(cache.progress(libraryItemID: "a")?.currentTime == 2)

        // An older response that arrives first applies; the newer one then replaces it.
        let first = cache.beginSeed()
        let second = cache.beginSeed()
        #expect(cache.seed([progress("b", lastUpdate: 1)], token: first))
        #expect(cache.seed([progress("c", lastUpdate: 1)], token: second))
        #expect(cache.storedKeys == ["c"])
        // A token applies once.
        #expect(!cache.seed([progress("d", lastUpdate: 1)], token: second))
    }

    @Test func aSeedRequestedBeforeClearIsDropped() {
        let cache = ProgressCache()
        let token = cache.beginSeed()
        cache.apply(progress("a", lastUpdate: 1))
        cache.clear()

        #expect(!cache.seed([progress("previous-account", lastUpdate: 1)], token: token))
        #expect(cache.storedKeys.isEmpty)
        #expect(cache.seed([progress("b", lastUpdate: 1)], token: cache.beginSeed()))
        #expect(cache.storedKeys == ["b"])
    }

    @Test func seedDoesNotChangeTheRevision() {
        let cache = ProgressCache()
        #expect(cache.revision == 0)
        cache.apply(progress("a", lastUpdate: 1))
        #expect(cache.revision == 1)
        #expect(!cache.apply(progress("a", lastUpdate: 0)))
        #expect(cache.revision == 1)
        cache.seed([progress("b", lastUpdate: 1)], token: cache.beginSeed())
        cache.clear()
        #expect(cache.revision == 1)
    }

    @Test func removeAndClear() {
        let cache = ProgressCache()
        cache.seed(
            [progress("a", lastUpdate: 1), progress("p", episode: "e", lastUpdate: 1)], token: cache.beginSeed())

        cache.remove(libraryItemID: "p", episodeID: "e")
        #expect(cache.progress(libraryItemID: "p", episodeID: "e") == nil)
        #expect(cache.progress(libraryItemID: "a") != nil)

        cache.clear()
        #expect(cache.storedKeys.isEmpty)
        #expect(cache.progress(libraryItemID: "a") == nil)
    }

    @Test func seedRemovalsArePrunedAndRemoveKeepsTombstones() {
        let cache = ProgressCache()
        cache.apply(progress("a", lastUpdate: 1))
        cache.apply(progress("b", lastUpdate: 1))
        _ = cache.progress(libraryItemID: "c")  // an empty entry a view may be watching
        #expect(cache.entryCount == 3)

        cache.seed([progress("b", lastUpdate: 1)], token: cache.beginSeed())
        #expect(cache.entryCount == 2)
        cache.remove(libraryItemID: "b")
        #expect(cache.entryCount == 2)
        cache.remove(libraryItemID: "missing")
        #expect(cache.entryCount == 3)
        #expect(cache.storedKeys.isEmpty)

        // A reader of a pruned key reads a new entry and sees later progress.
        let changed = Locked(false)
        withObservationTracking {
            _ = cache.progress(libraryItemID: "a")
        } onChange: {
            changed.value = true
        }
        cache.apply(progress("a", currentTime: 5, lastUpdate: 20))
        #expect(changed.value)
        #expect(cache.progress(libraryItemID: "a")?.currentTime == 5)
    }

    @Test func aSeedRequestedBeforeARemoveDoesNotRestoreIt() {
        let cache = ProgressCache()
        cache.apply(progress("x", currentTime: 1, lastUpdate: 10))
        let token = cache.beginSeed()
        // While `/api/me` is in flight, the progress is removed (a socket event or a reset).
        cache.remove(libraryItemID: "x")
        let changed = Locked(false)
        withObservationTracking {
            _ = cache.progress(libraryItemID: "x")
        } onChange: {
            changed.value = true
        }

        // The server read its list before the delete.
        #expect(cache.seed([progress("x", currentTime: 1, lastUpdate: 10)], token: token))
        #expect(cache.progress(libraryItemID: "x") == nil)
        #expect(!changed.value)
    }

    @Test func applyThenRemoveDuringASeedRequestStaysRemoved() {
        let cache = ProgressCache()
        let token = cache.beginSeed()
        cache.apply(progress("x", currentTime: 2, lastUpdate: 20))
        cache.remove(libraryItemID: "x")

        cache.seed([progress("x", currentTime: 3, lastUpdate: 30)], token: token)
        #expect(cache.progress(libraryItemID: "x") == nil)
        #expect(cache.storedKeys.isEmpty)
    }

    @Test func aSeedRequestedAfterARemoveRestoresIt() {
        let cache = ProgressCache()
        cache.apply(progress("x", currentTime: 1, lastUpdate: 10))
        cache.remove(libraryItemID: "x")
        let token = cache.beginSeed()

        // The server still has the progress.
        cache.seed([progress("x", currentTime: 1, lastUpdate: 10)], token: token)
        #expect(cache.progress(libraryItemID: "x")?.currentTime == 1)
    }

    @Test func clearKeepsObserversOfMissingProgressAttached() {
        let cache = ProgressCache()
        cache.apply(progress("a", lastUpdate: 1))
        let changed = Locked(false)
        withObservationTracking {
            _ = cache.progress(libraryItemID: "missing")
        } onChange: {
            changed.value = true
        }
        let entries = cache.entryCount

        cache.clear()
        #expect(cache.entryCount == entries)
        #expect(!changed.value)

        cache.apply(progress("missing", currentTime: 7, lastUpdate: 2))
        #expect(changed.value)
        #expect(cache.progress(libraryItemID: "missing")?.currentTime == 7)
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
        cache.seed([progress("a", lastUpdate: 2), progress("b", lastUpdate: 1)], token: cache.beginSeed())
        #expect(!readerOfB.value)
        #expect(!readerOfC.value)

        cache.apply(progress("c", lastUpdate: 3))
        #expect(readerOfC.value)
        #expect(!readerOfB.value)

        cache.apply(progress("b", lastUpdate: 4))
        #expect(readerOfB.value)

        // Removal by a seed and clearing notify readers too.
        let rereadB = observe("b")
        cache.seed([progress("a", lastUpdate: 2)], token: cache.beginSeed())
        #expect(rereadB.value)
        let readerOfA = observe("a")
        cache.clear()
        #expect(readerOfA.value)
    }
}
