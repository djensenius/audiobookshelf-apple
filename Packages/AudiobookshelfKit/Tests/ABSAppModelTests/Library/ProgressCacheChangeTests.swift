import ABSAPI
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

    /// An action reports its media again once the server and the local database have it, so a
    /// preparation the optimistic report started against the old progress runs again (#554); a
    /// failed one only reports its rollback.
    @Test func aSucceededActionReportsAgainOnceSettled() async throws {
        let cache = ProgressCache()
        cache.apply(progress("podcast", episode: "e2", currentTime: 5, lastUpdate: 10))
        let log = Locked<[String]>([])
        cache.onChange = { item, episode in log.value.append("change \(item) \(episode ?? "-")") }
        let writer = LoggingWriter(log: log)
        let actions = ProgressItemActions(cache: cache, writer: writer, localSync: LoggingSync(log: log))
        let target = ItemActionTarget(libraryItemID: "podcast", episodeID: "e2", duration: 60)

        try await actions.markFinished(target)
        #expect(log.value == ["change podcast e2", "write", "local finished", "change podcast e2"])

        log.value = []
        try await actions.discardProgress(target)
        #expect(log.value == ["change podcast e2", "delete", "local discard", "change podcast e2"])

        log.value = []
        cache.apply(progress("podcast", episode: "e2", currentTime: 5, lastUpdate: 20))
        writer.fails.value = true
        await #expect(throws: LoggingWriter.Failure.self) { try await actions.markFinished(target) }
        #expect(log.value == ["change podcast e2", "change podcast e2", "write", "change podcast e2"])
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

/// Logs each server request into the shared log; fails them while `fails` is set.
private struct LoggingWriter: ProgressWriting {
    struct Failure: Error {}

    let log: Locked<[String]>
    let fails = Locked(false)

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        log.value.append("write")
        if fails.value { throw Failure() }
    }

    func progressID(itemID: String, episodeID: String?) async throws -> String? { "mp-\(itemID)" }

    func deleteProgress(id: String) async throws { log.value.append("delete") }
}

/// Logs each local database update into the shared log.
private struct LoggingSync: ItemActionLocalSync {
    let log: Locked<[String]>

    func didMarkFinished(_ target: ItemActionTarget) async throws { log.value.append("local finished") }
    func didMarkNotFinished(_ target: ItemActionTarget) async throws { log.value.append("local not finished") }
    func didDiscard(_ target: ItemActionTarget) async throws { log.value.append("local discard") }
}
