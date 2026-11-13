import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private func progress(_ itemID: String, episode: String? = nil, currentTime: Double = 0, lastUpdate: Int?)
    -> MediaProgress
{
    MediaProgress(
        id: "p-\(itemID)-\(episode ?? "")", libraryItemId: itemID, episodeId: episode, currentTime: currentTime,
        lastUpdate: lastUpdate)
}

/// ``ProgressCache/onChange`` (#160): every real change, however it's made, and nothing else.
@MainActor
@Suite struct ProgressCacheChangeTests {
    private struct Change: Equatable {
        let item: String
        let episode: String?
    }

    private final class Recorder {
        var changes: [Change] = []
    }

    private func recording(_ cache: ProgressCache) -> Recorder {
        let recorder = Recorder()
        cache.onChange = { recorder.changes.append(Change(item: $0, episode: $1)) }
        return recorder
    }

    @Test func storingReplacingAndRemovingReportTheMedia() {
        let cache = ProgressCache()
        let recorder = recording(cache)

        cache.apply(progress("podcast", episode: "e1", currentTime: 1, lastUpdate: 10))
        cache.apply(progress("podcast", episode: "e1", currentTime: 2, lastUpdate: 20))
        cache.remove(libraryItemID: "podcast", episodeID: "e1")

        #expect(recorder.changes == Array(repeating: Change(item: "podcast", episode: "e1"), count: 3))
    }

    /// An update the cache keeps out, a read, or removing nothing changes no value.
    @Test func noChangeReportsNothing() {
        let cache = ProgressCache()
        cache.apply(progress("book", currentTime: 10, lastUpdate: 200))
        let recorder = recording(cache)

        cache.apply(progress("book", currentTime: 5, lastUpdate: 100))
        cache.apply(progress("book", currentTime: 10, lastUpdate: 200))
        _ = cache.progress(libraryItemID: "other")
        cache.remove(libraryItemID: "other")

        #expect(recorder.changes.isEmpty)
    }

    /// A seed reports each entry it stores, replaces or drops, and none it leaves as they were.
    @Test func aSeedReportsWhatItChanges() {
        let cache = ProgressCache()
        cache.seed(
            [
                progress("kept", lastUpdate: 10), progress("replaced", lastUpdate: 10),
                progress("dropped", lastUpdate: 10),
            ],
            token: cache.beginSeed())
        let recorder = recording(cache)

        cache.seed(
            [
                progress("kept", lastUpdate: 10), progress("replaced", currentTime: 5, lastUpdate: 20),
                progress("added", lastUpdate: 10),
            ],
            token: cache.beginSeed())

        #expect(Set(recorder.changes.map(\.item)) == ["replaced", "dropped", "added"])
        #expect(recorder.changes.count == 3)
    }

    /// An optimistic action and its rollback each report the media.
    @Test func optimisticActionsReport() throws {
        let cache = ProgressCache()
        let recorder = recording(cache)
        let token = cache.sessionToken()

        let update = try #require(cache.applyOptimistic(progress("book", currentTime: 9, lastUpdate: 30), token: token))
        cache.rollbackOptimistic(update, to: nil, token: token)

        #expect(recorder.changes == [Change(item: "book", episode: nil), Change(item: "book", episode: nil)])
    }

    /// Clearing ends the account's session; it reports nothing.
    @Test func clearingReportsNothing() {
        let cache = ProgressCache()
        cache.apply(progress("book", lastUpdate: 10))
        let recorder = recording(cache)

        cache.clear()

        #expect(cache.progress(libraryItemID: "book") == nil)
        #expect(recorder.changes.isEmpty)
    }
}
