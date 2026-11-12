import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

private struct Write: Sendable {
    let itemID: String
    let episodeID: String?
    let update: MediaProgressUpdate
}

/// Counts requests in flight, atomically.
private final class Concurrency: Sendable {
    private let state = Mutex((current: 0, peak: 0))
    var peak: Int { state.withLock { $0.peak } }

    func enter() {
        state.withLock {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
        }
    }

    func leave() { state.withLock { $0.current -= 1 } }
}

private struct GatedWriter: ProgressWriting {
    let gate = GatedCalls<Write, Void>()
    /// The progress IDs of deletes, held until the test replies.
    let deletes = GatedCalls<String, Void>()
    /// The most requests in flight at once, for the per-key serialization.
    let concurrency = Concurrency()
    /// Each write as it arrives, and the test's own markers, in order.
    let log = Locked<[String]>([])

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        log.value.append("write \(update)")
        concurrency.enter()
        defer { concurrency.leave() }
        try await gate.call(Write(itemID: itemID, episodeID: episodeID, update: update))
    }

    func deleteProgress(id: String) async throws {
        log.value.append("delete \(id)")
        concurrency.enter()
        defer { concurrency.leave() }
        try await deletes.call(id)
    }
}

private struct FirstGatedWriter: ProgressWriting {
    let gate = GatedCalls<Write, Void>()
    let writes = Locked<[Write]>([])
    let deletes = Locked<[String]>([])

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        let write = Write(itemID: itemID, episodeID: episodeID, update: update)
        writes.value.append(write)
        if writes.value.count == 1 { try await gate.call(write) }
    }

    /// Records the delete and succeeds at once.
    func deleteProgress(id: String) async throws {
        deletes.value.append(id)
    }
}

private let clock = Date(timeIntervalSince1970: 2_000)
private let clockMilliseconds = 2_000_000

private func progress(
    _ item: String = "item", episode: String? = nil, finished: Bool = false, current: Double = 30,
    duration: Double = 100, lastUpdate: Int? = 1_000, hidden: Bool = false
) -> MediaProgress {
    MediaProgress(
        id: "mp-\(item)", libraryItemId: item, episodeId: episode, duration: duration,
        progress: current / duration, currentTime: current, isFinished: finished, hideFromContinueListening: hidden,
        lastUpdate: lastUpdate)
}

@MainActor
private func makeActions(_ cache: ProgressCache, _ writer: any ProgressWriting) -> ProgressItemActions {
    ProgressItemActions(cache: cache, writer: writer, now: { clock })
}

@MainActor
@Suite struct ItemActionsTests {
    @Test func markFinishedIsOptimisticThenSendsTheFinishedGroup() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.markFinished(ItemActionTarget(libraryItemID: "item")) }
        let write = try #require(await writes.next())

        let optimistic = try #require(cache.progress(libraryItemID: "item"))
        #expect(optimistic.isFinished && optimistic.progress == 1 && optimistic.currentTime == 100)
        #expect(optimistic.lastUpdate == 1_000 && optimistic.finishedAt == clockMilliseconds)
        #expect(write.request.update == .finished(true, at: clock))
        #expect(write.request.itemID == "item" && write.request.episodeID == nil)

        write.reply.resume(returning: ())
        try await action.value
        #expect(cache.progress(libraryItemID: "item") == optimistic)
    }

    @Test func aServerSeedAfterASuccessfulActionReconcilesDespiteDeviceClockSkew() async throws {
        let cache = ProgressCache()
        cache.apply(progress(finished: true, current: 100, lastUpdate: 1_000))
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.markFinished(ItemActionTarget(libraryItemID: "item")) }
        let write = try #require(await writes.next())
        write.reply.resume(returning: ())
        try await action.value

        let serverProgress = progress(current: 15, lastUpdate: 1_500)
        let token = cache.beginSeed()
        #expect(cache.seed([serverProgress], token: token))
        #expect(cache.progress(libraryItemID: "item") == serverProgress)
    }

    @Test func markFinishedWithoutProgressCreatesAFinishedEntryFromTheTargetsDuration() async throws {
        let cache = ProgressCache()
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let target = ItemActionTarget(libraryItemID: "ep-item", episodeID: "ep", duration: 600)
        let action = Task { try await actions.markFinished(target) }
        let write = try #require(await writes.next())
        let created = try #require(cache.progress(libraryItemID: "ep-item", episodeID: "ep"))
        #expect(created.isFinished && created.currentTime == 600 && created.episodeId == "ep")
        #expect(write.request.episodeID == "ep")
        write.reply.resume(returning: ())
        try await action.value
    }

    @Test func markNotFinishedResetsFinishedProgressAndLeavesOtherProgressAlone() async throws {
        let cache = ProgressCache()
        cache.apply(progress("done", finished: true, current: 100))
        cache.apply(progress("partway"))
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let first = Task { try await actions.markNotFinished(ItemActionTarget(libraryItemID: "done")) }
        let firstWrite = try #require(await writes.next())
        let reset = try #require(cache.progress(libraryItemID: "done"))
        #expect(!reset.isFinished && reset.currentTime == 0 && reset.progress == 0 && reset.finishedAt == nil)
        #expect(firstWrite.request.update == .finished(false))
        firstWrite.reply.resume(returning: ())
        try await first.value

        let before = cache.progress(libraryItemID: "partway")
        let second = Task { try await actions.markNotFinished(ItemActionTarget(libraryItemID: "partway")) }
        let secondWrite = try #require(await writes.next())
        #expect(cache.progress(libraryItemID: "partway") == before)
        secondWrite.reply.resume(returning: ())
        try await second.value
    }

    @Test func hideFromContinueListeningMarksTheEntryAndKeepsProgress() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.hideFromContinueListening(ItemActionTarget(libraryItemID: "item")) }
        let write = try #require(await writes.next())
        let hidden = try #require(cache.progress(libraryItemID: "item"))
        #expect(hidden.hideFromContinueListening && hidden.currentTime == 30 && !hidden.isFinished)
        #expect(write.request.update == .hideFromContinueListening(true))
        write.reply.resume(returning: ())
        try await action.value
    }

    // MARK: Rollback

    @Test func aFailedMarkFinishedRestoresThePreviousProgress() async throws {
        let cache = ProgressCache()
        let previous = progress()
        cache.apply(previous)
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.markFinished(ItemActionTarget(libraryItemID: "item")) }
        let write = try #require(await writes.next())
        #expect(cache.progress(libraryItemID: "item")?.isFinished == true)
        write.reply.resume(throwing: TestError.offline)

        await #expect(throws: TestError.self) { try await action.value }
        #expect(cache.progress(libraryItemID: "item") == previous)
    }

    @Test func aFailedMarkFinishedWithNoPreviousProgressRemovesTheEntry() async throws {
        let cache = ProgressCache()
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.markFinished(ItemActionTarget(libraryItemID: "item", duration: 50)) }
        let write = try #require(await writes.next())
        #expect(cache.progress(libraryItemID: "item") != nil)
        write.reply.resume(throwing: TestError.offline)
        await #expect(throws: TestError.self) { try await action.value }
        #expect(cache.progress(libraryItemID: "item") == nil)
    }

    @Test func aRollbackDoesNotOverwriteANewerEntry() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.markFinished(ItemActionTarget(libraryItemID: "item")) }
        let write = try #require(await writes.next())
        let newer = progress(current: 55, lastUpdate: clockMilliseconds + 500)
        #expect(cache.apply(newer))

        write.reply.resume(throwing: TestError.offline)
        await #expect(throws: TestError.self) { try await action.value }
        #expect(cache.progress(libraryItemID: "item") == newer)
    }

    @Test func aFailedHideRestoresTheEntry() async throws {
        let cache = ProgressCache()
        let previous = progress()
        cache.apply(previous)
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let action = Task { try await actions.hideFromContinueListening(ItemActionTarget(libraryItemID: "item")) }
        let write = try #require(await writes.next())
        write.reply.resume(throwing: TestError.offline)
        await #expect(throws: TestError.self) { try await action.value }
        #expect(cache.progress(libraryItemID: "item") == previous)
    }

    // MARK: Ordering

    @Test func actionsOnTheSameKeyRunOneAfterTheOther() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()
        let target = ItemActionTarget(libraryItemID: "item")

        let finish = Task { try await actions.markFinished(target) }
        let unfinish = Task { try await actions.markNotFinished(target) }
        // Both tasks have started by the time the first write arrives; unchained, the second
        // would write too, before the first reply is released.
        let finishWrite = try #require(await writes.next())
        #expect(finishWrite.request.update == .finished(true, at: clock))
        #expect(cache.progress(libraryItemID: "item")?.isFinished == true)

        writer.log.value.append("release")
        finishWrite.reply.resume(returning: ())
        try await finish.value
        let unfinishWrite = try #require(await writes.next())
        #expect(unfinishWrite.request.update == .finished(false))
        #expect(cache.progress(libraryItemID: "item")?.isFinished == false)
        unfinishWrite.reply.resume(returning: ())
        try await unfinish.value
        #expect(writer.log.value.map { $0.hasPrefix("write") ? "write" : $0 } == ["write", "release", "write"])
        #expect(writer.concurrency.peak == 1)
    }

    @Test func queuedActionsCannotMutateTheNextAccountProgress() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = FirstGatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()
        let target = ItemActionTarget(libraryItemID: "item")

        let first = Task { try await actions.markFinished(target) }
        let firstWrite = try #require(await writes.next())
        let second = Task { try await actions.markNotFinished(target) }
        await Task.yield()

        cache.clear()
        let newAccountProgress = progress(finished: true, current: 100, lastUpdate: 1_500)
        cache.apply(newAccountProgress)
        firstWrite.reply.resume(returning: ())

        let firstResult = await first.result
        let secondResult = await second.result
        #expect(throws: CancellationError.self) { try firstResult.get() }
        #expect(throws: CancellationError.self) { try secondResult.get() }
        #expect(writer.writes.value.count == 1)
        #expect(cache.progress(libraryItemID: "item") == newAccountProgress)
    }

    @Test func aSecondActionStartsFromTheStateLeftByAFailedFirst() async throws {
        let cache = ProgressCache()
        let previous = progress(finished: true, current: 100)
        cache.apply(previous)
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()
        let target = ItemActionTarget(libraryItemID: "item")

        let hide = Task { try await actions.hideFromContinueListening(target) }
        let hideWrite = try #require(await writes.next())
        let unfinish = Task { try await actions.markNotFinished(target) }
        hideWrite.reply.resume(throwing: TestError.offline)
        await #expect(throws: TestError.self) { try await hide.value }

        let unfinishWrite = try #require(await writes.next())
        let optimistic = try #require(cache.progress(libraryItemID: "item"))
        #expect(!optimistic.isFinished && !optimistic.hideFromContinueListening)
        unfinishWrite.reply.resume(throwing: TestError.offline)
        await #expect(throws: TestError.self) { try await unfinish.value }
        #expect(cache.progress(libraryItemID: "item") == previous)
    }

    @Test func actionsOnOtherKeysDoNotWait() async throws {
        let cache = ProgressCache()
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()

        let first = Task { try await actions.markFinished(ItemActionTarget(libraryItemID: "a", duration: 10)) }
        let firstWrite = try #require(await writes.next())
        let second = Task {
            try await actions.markFinished(ItemActionTarget(libraryItemID: "a", episodeID: "e", duration: 10))
        }
        let secondWrite = try #require(await writes.next())
        #expect(secondWrite.request.episodeID == "e")
        firstWrite.reply.resume(returning: ())
        secondWrite.reply.resume(returning: ())
        try await first.value
        try await second.value
    }

    @Test func theNoOpActionsDoNothing() async throws {
        let actions: any ItemActionPerforming = NoOpItemActions()
        let target = ItemActionTarget(libraryItemID: "item")
        try await actions.markFinished(target)
        try await actions.markNotFinished(target)
        try await actions.hideFromContinueListening(target)
        try await actions.discardProgress(target)
    }

    // MARK: Discard

    @Test func discardRemovesOptimisticallyAndDeletesByProgressID() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var deletes = writer.deletes.calls.makeAsyncIterator()

        let action = Task { try await actions.discardProgress(ItemActionTarget(libraryItemID: "item")) }
        let delete = try #require(await deletes.next())
        #expect(delete.request == "mp-item")
        #expect(cache.progress(libraryItemID: "item") == nil)

        delete.reply.resume(returning: ())
        try await action.value
        #expect(cache.progress(libraryItemID: "item") == nil)
        #expect(writer.log.value == ["delete mp-item"])
    }

    @Test func discardRollsBackOnFailureAndRethrows() async throws {
        let cache = ProgressCache()
        let previous = progress()
        cache.apply(previous)
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var deletes = writer.deletes.calls.makeAsyncIterator()

        let action = Task { try await actions.discardProgress(ItemActionTarget(libraryItemID: "item")) }
        let delete = try #require(await deletes.next())
        #expect(cache.progress(libraryItemID: "item") == nil)
        delete.reply.resume(throwing: TestError.offline)

        await #expect(throws: TestError.self) { try await action.value }
        #expect(cache.progress(libraryItemID: "item") == previous)
    }

    @Test func discardWithoutProgressSendsNothing() async throws {
        let cache = ProgressCache()
        let writer = FirstGatedWriter()
        let actions = makeActions(cache, writer)

        try await actions.discardProgress(ItemActionTarget(libraryItemID: "item", duration: 100))
        #expect(writer.deletes.value.isEmpty && writer.writes.value.isEmpty)
        #expect(cache.progress(libraryItemID: "item") == nil)
    }

    @Test func discardRollbackKeepsNewerUpdate() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var deletes = writer.deletes.calls.makeAsyncIterator()

        let action = Task { try await actions.discardProgress(ItemActionTarget(libraryItemID: "item")) }
        let delete = try #require(await deletes.next())
        // Playback elsewhere reported progress while the DELETE was in flight.
        let newer = progress(current: 70, lastUpdate: 5_000)
        #expect(cache.apply(newer))

        delete.reply.resume(throwing: TestError.offline)
        await #expect(throws: TestError.self) { try await action.value }
        #expect(cache.progress(libraryItemID: "item") == newer)
    }

    @Test func discardWaitsForPendingMarkFinishedOnSameKey() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = GatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()
        var deletes = writer.deletes.calls.makeAsyncIterator()
        let target = ItemActionTarget(libraryItemID: "item")

        let finish = Task { try await actions.markFinished(target) }
        let discard = Task { try await actions.discardProgress(target) }
        let finishWrite = try #require(await writes.next())
        #expect(cache.progress(libraryItemID: "item")?.isFinished == true)

        writer.log.value.append("release")
        finishWrite.reply.resume(returning: ())
        try await finish.value
        let delete = try #require(await deletes.next())
        #expect(delete.request == "mp-item")
        #expect(cache.progress(libraryItemID: "item") == nil)
        delete.reply.resume(returning: ())
        try await discard.value
        #expect(
            writer.log.value.map { $0.hasPrefix("write") ? "write" : $0 } == ["write", "release", "delete mp-item"])
        #expect(writer.concurrency.peak == 1)
    }

    @Test func discardAfterAccountSwitchCancelsWithoutRequest() async throws {
        let cache = ProgressCache()
        cache.apply(progress())
        let writer = FirstGatedWriter()
        let actions = makeActions(cache, writer)
        var writes = writer.gate.calls.makeAsyncIterator()
        let target = ItemActionTarget(libraryItemID: "item")

        let first = Task { try await actions.markFinished(target) }
        let firstWrite = try #require(await writes.next())
        let discard = Task { try await actions.discardProgress(target) }
        await Task.yield()

        cache.clear()
        let newAccountProgress = progress(current: 40, lastUpdate: 1_500)
        cache.apply(newAccountProgress)
        firstWrite.reply.resume(returning: ())

        _ = await first.result
        let discardResult = await discard.result
        #expect(throws: CancellationError.self) { try discardResult.get() }
        #expect(writer.deletes.value.isEmpty)
        #expect(cache.progress(libraryItemID: "item") == newAccountProgress)

        // Actions made before the switch never run against the next account, even unqueued.
        await #expect(throws: CancellationError.self) { try await actions.discardProgress(target) }
        #expect(writer.deletes.value.isEmpty)
    }
}
