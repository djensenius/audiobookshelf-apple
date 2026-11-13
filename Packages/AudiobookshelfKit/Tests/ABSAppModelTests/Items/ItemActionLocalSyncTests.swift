import ABSAPI
import ABSCore
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSData

/// Accepts every request, or fails them all while `fails` is set.
private struct ScriptedWriter: ProgressWriting {
    struct Failure: Error {}

    let fails = Locked(false)
    let deletes = Locked<[String]>([])

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        if fails.value { throw Failure() }
    }

    func progressID(itemID: String, episodeID: String?) async throws -> String? {
        if fails.value { throw Failure() }
        return "mp-\(itemID)"
    }

    func deleteProgress(id: String) async throws {
        if fails.value { throw Failure() }
        deletes.value.append(id)
    }
}

/// Counts `base`'s accepted writes.
private struct CountingWriter: ProgressWriting {
    let base: ScriptedWriter
    let writes: Locked<Int>

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        try await base.writeProgress(itemID: itemID, episodeID: episodeID, update: update)
        writes.value += 1
    }

    func progressID(itemID: String, episodeID: String?) async throws -> String? {
        try await base.progressID(itemID: itemID, episodeID: episodeID)
    }

    func deleteProgress(id: String) async throws {
        try await base.deleteProgress(id: id)
        writes.value += 1
    }
}

/// Holds each write at `gate` until it opens, counting the writes that reached it.
private struct GatedWriter: ProgressWriting {
    let base: ScriptedWriter
    let gate: Gate
    let entered = Locked(0)

    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        entered.value += 1
        await gate.wait()
        try await base.writeProgress(itemID: itemID, episodeID: episodeID, update: update)
    }

    func progressID(itemID: String, episodeID: String?) async throws -> String? {
        try await base.progressID(itemID: itemID, episodeID: episodeID)
    }

    func deleteProgress(id: String) async throws {
        entered.value += 1
        await gate.wait()
        try await base.deleteProgress(id: id)
    }
}

/// Records the hook's calls; throws after recording while `fails` is set.
private struct RecordingSync: ItemActionLocalSync {
    struct Failure: Error {}

    let calls = Locked<[String]>([])
    let fails = Locked(false)

    func didMarkFinished(_ target: ItemActionTarget) async throws { try record("finished \(target.libraryItemID)") }
    func didMarkNotFinished(_ target: ItemActionTarget) async throws {
        try record("notFinished \(target.libraryItemID)")
    }
    func didDiscard(_ target: ItemActionTarget) async throws { try record("discard \(target.libraryItemID)") }

    private func record(_ call: String) throws {
        calls.value.append(call)
        if fails.value { throw Failure() }
    }
}

private let connection = UUID()
private let key = MediaKey(serverConnectionID: connection, libraryItemId: "item")
private let target = ItemActionTarget(libraryItemID: "item", duration: 600)
private let edited = Date(timeIntervalSince1970: 1_000)

private func cachedProgress(finished: Bool = false) -> MediaProgress {
    MediaProgress(
        id: "mp-item", libraryItemId: "item", duration: 600, progress: finished ? 1 : 0.5,
        currentTime: finished ? 600 : 300, isFinished: finished, lastUpdate: 1_000)
}

@MainActor
@Suite struct ItemActionLocalSyncTests {
    private let store: LocalProgressStore
    private let cache = ProgressCache()
    private let writer = ScriptedWriter()

    init() throws {
        store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    private func actions(_ localSync: (any ItemActionLocalSync)? = nil) -> ProgressItemActions {
        ProgressItemActions(
            cache: cache, writer: writer,
            localSync: localSync ?? LocalProgressItemActionSync(store: store, connectionID: connection))
    }

    /// A row with an unsent position, as playback leaves it.
    private func playedRow(at currentTime: Double = 120) async throws {
        let audio = ProgressEdit.Audio(currentTime: currentTime, duration: 600, progress: currentTime / 600)
        try await store.recordEdit(ProgressEdit(audio: audio), for: key, now: edited)
    }

    @Test func finishedEditOnlyWhenRowExists() async throws {
        cache.apply(cachedProgress())
        try await actions().markFinished(target)
        #expect(try await store.progress(for: key) == nil)

        try await playedRow()
        try await actions().markFinished(target)
        let row = try #require(try await store.progress(for: key))
        #expect(row.isFinished)
        #expect(row.finishedDirty)
        // The position is still sent, before finished.
        #expect(row.audioDirty)
        #expect(row.currentTime == 120)
    }

    @Test func discardDeletesRow() async throws {
        cache.apply(cachedProgress())
        try await playedRow()
        try await actions().discardProgress(target)
        #expect(writer.deletes.value == ["mp-item"])
        #expect(try await store.progress(for: key) == nil)
        #expect(try await store.pendingSync(for: connection).isEmpty)
    }

    @Test func notFinishedResetsAudioAndFinished() async throws {
        cache.apply(cachedProgress(finished: true))
        try await playedRow(at: 595)
        try await store.recordEdit(ProgressEdit(isFinished: true), for: key, now: edited)

        try await actions().markNotFinished(target)
        let row = try #require(try await store.progress(for: key))
        #expect(!row.isFinished)
        #expect(row.currentTime == 0)
        #expect(row.progress == 0)
        #expect(row.duration == 600)
        #expect(row.audioDirty && row.finishedDirty)

        // Nothing to reset without a row.
        try await store.deleteProgress(for: key)
        cache.apply(cachedProgress(finished: true))
        try await actions().markNotFinished(target)
        #expect(try await store.progress(for: key) == nil)
    }

    /// A closed session's position whose save failed, retried by the syncer after the action
    /// (#368): the action superseded it, so the retry writes nothing, and neither restores the old
    /// position nor recreates discarded progress. Negative control: a position reserved after the
    /// action, by new playback, commits.
    @Test(arguments: ["finished", "notFinished", "discard"])
    func aFailedPlaybackSaveRetriedAfterTheActionCantUndoIt(action: String) async throws {
        cache.apply(cachedProgress(finished: action == "notFinished"))
        try await playedRow(at: 300)
        let stale = ProgressEdit.Audio(currentTime: 310, duration: 600, progress: 310.0 / 600)
        let failed = store.reservePlaybackPosition(for: key)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) {
            try await store.recordPlaybackPosition(stale, for: key, token: failed, now: edited)
        }

        switch action {
        case "finished": try await actions().markFinished(target)
        case "notFinished": try await actions().markNotFinished(target)
        default: try await actions().discardProgress(target)
        }
        let acted = try await store.progress(for: key)
        #expect((acted == nil) == (action == "discard"))

        let retry = try await store.recordPlaybackPosition(stale, for: key, token: failed, now: edited)
        #expect(retry == .supersededByCommittedPosition)
        #expect(try await store.progress(for: key) == acted)

        let later = store.reservePlaybackPosition(for: key)
        #expect(try await store.recordPlaybackPosition(stale, for: key, token: later, now: edited) == .committed)
        #expect(try await store.progress(for: key)?.currentTime == 310)
    }

    /// Negative control: the local row changes only after the server accepted the action.
    @Test func failedServerCallLeavesRowUntouched() async throws {
        cache.apply(cachedProgress())
        try await playedRow()
        let before = try await store.progress(for: key)
        writer.fails.value = true
        let actions = actions()

        await #expect(throws: ScriptedWriter.Failure.self) { try await actions.markFinished(target) }
        await #expect(throws: ScriptedWriter.Failure.self) { try await actions.markNotFinished(target) }
        await #expect(throws: ScriptedWriter.Failure.self) { try await actions.discardProgress(target) }
        #expect(try await store.progress(for: key) == before)
    }

    @Test func rolledBackActionDoesNotCallHook() async throws {
        let sync = RecordingSync()
        cache.apply(cachedProgress(finished: true))
        writer.fails.value = true
        let actions = actions(sync)

        await #expect(throws: ScriptedWriter.Failure.self) { try await actions.markFinished(target) }
        await #expect(throws: ScriptedWriter.Failure.self) { try await actions.markNotFinished(target) }
        await #expect(throws: ScriptedWriter.Failure.self) { try await actions.discardProgress(target) }
        #expect(cache.progress(libraryItemID: "item") == cachedProgress(finished: true))
        #expect(sync.calls.value.isEmpty)

        // Hiding isn't synced locally, and discarding without progress sends nothing.
        writer.fails.value = false
        try await actions.hideFromContinueListening(target)
        cache.clear()
        let empty = ProgressItemActions(cache: cache, writer: writer, localSync: sync)
        try await empty.discardProgress(target)
        #expect(sync.calls.value.isEmpty)
    }

    @Test func hookFailureDoesNotRethrow() async throws {
        let sync = RecordingSync()
        sync.fails.value = true
        cache.apply(cachedProgress())
        let actions = actions(sync)

        try await actions.markFinished(target)
        #expect(cache.progress(libraryItemID: "item")?.isFinished == true)
        try await actions.markNotFinished(target)
        try await actions.discardProgress(target)
        #expect(cache.progress(libraryItemID: "item") == nil)
        #expect(sync.calls.value == ["finished item", "notFinished item", "discard item"])
    }

    /// The item in the player: marking and discarding are refused before anything changes (its
    /// session would write its position back), hiding isn't, and once the player moves on they run.
    @Test func itemInPlayerRefusesProgressActions() async throws {
        let sync = RecordingSync()
        let writes = Locked(0)
        let counting = CountingWriter(base: writer, writes: writes)
        let inPlayer = Locked<ItemActionTarget?>(target)
        let actions = ProgressItemActions(
            cache: cache, writer: counting, localSync: sync, isInPlayer: { inPlayer.value == $0 })
        cache.apply(cachedProgress())

        await #expect(throws: ItemActionError.itemInPlayer) { try await actions.markFinished(target) }
        await #expect(throws: ItemActionError.itemInPlayer) { try await actions.markNotFinished(target) }
        await #expect(throws: ItemActionError.itemInPlayer) { try await actions.discardProgress(target) }
        #expect(cache.progress(libraryItemID: "item") == cachedProgress())
        #expect(writes.value == 0)
        #expect(sync.calls.value.isEmpty)

        try await actions.hideFromContinueListening(target)
        #expect(writes.value == 1)

        // Another item, or the player closed: the actions run.
        try await actions.markFinished(ItemActionTarget(libraryItemID: "other"))
        inPlayer.value = nil
        try await actions.markFinished(target)
        #expect(sync.calls.value == ["finished other", "finished item"])
    }

    private func leasedActions(
        _ leases: MediaLeases, writer: any ProgressWriting, sync: RecordingSync,
        inPlayer: Locked<ItemActionTarget?> = Locked(nil)
    ) -> ProgressItemActions {
        ProgressItemActions(
            cache: cache, writer: writer, localSync: sync, isInPlayer: { inPlayer.value == $0 },
            lease: { target in
                await leases.acquire(
                    MediaKey(serverConnectionID: connection, libraryItemId: target.libraryItemID),
                    for: .progressAction, after: .closingSession)
            })
    }

    /// A closed player's final sync and `/close` still in flight (#368): the retried action waits
    /// for them to settle before it changes anything, and is refused if the item is back in the
    /// player by then.
    @Test func progressActionsWaitForTheItemsClosingSession() async throws {
        let leases = MediaLeases()
        let sync = RecordingSync()
        let writes = Locked(0)
        let inPlayer = Locked<ItemActionTarget?>(nil)
        let actions = leasedActions(
            leases, writer: CountingWriter(base: writer, writes: writes), sync: sync, inPlayer: inPlayer)
        cache.apply(cachedProgress())

        let closing = leases.acquire(key, for: .closingSession)
        let markFinished = Task { try await actions.markFinished(target) }
        let discard = Task { try await actions.discardProgress(target) }
        for _ in 0..<50 { await Task.yield() }
        #expect(writes.value == 0)
        #expect(cache.progress(libraryItemID: "item") == cachedProgress())

        closing.release()
        try await markFinished.value
        try await discard.value
        #expect(sync.calls.value == ["finished item", "discard item"])
        #expect(!leases.isHeld(key, by: .progressAction))

        // Held again, then the item went back into the player: refused once the close settles.
        let next = leases.acquire(key, for: .closingSession)
        let retry = Task { try await actions.markFinished(target) }
        for _ in 0..<20 { await Task.yield() }
        inPlayer.value = target
        next.release()
        await #expect(throws: ItemActionError.itemInPlayer) { try await retry.value }
        #expect(!leases.isHeld(key, by: .progressAction))
    }

    /// While the server request is suspended, the action holds the item's lease, so a playback
    /// start of it (which waits for ``MediaLeases/Holder/progressAction``) can't read the old
    /// position; the lease is released once the local sync ran.
    @Test func progressActionsHoldTheItemThroughTheRequestAndLocalSync() async throws {
        let leases = MediaLeases()
        let sync = RecordingSync()
        let gate = Gate()
        let gated = GatedWriter(base: writer, gate: gate)
        let actions = leasedActions(leases, writer: gated, sync: sync)
        cache.apply(cachedProgress())

        let markFinished = Task { try await actions.markFinished(target) }
        for _ in 0..<1000 where gated.entered.value == 0 { await Task.yield() }
        #expect(gated.entered.value == 1)
        #expect(leases.isHeld(key, by: .progressAction))
        let started = Locked(false)
        let start = Task {
            await leases.waitUntilFree(key, of: .progressAction)
            started.value = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!started.value)

        gate.open()
        try await markFinished.value
        await start.value
        #expect(started.value)
        #expect(sync.calls.value == ["finished item"])

        // Hiding doesn't touch the position, so it takes no lease.
        try await actions.hideFromContinueListening(target)
        #expect(!leases.isHeld(key, by: .progressAction))
    }

    /// The drain sends the old position before finished, so the server ends up finished.
    @Test func drainSendsAudioThenFinishedAfterMarkFinished() async throws {
        cache.apply(cachedProgress())
        try await playedRow()
        try await actions().markFinished(target)

        let audio = try #require(try await store.beginSend(for: key))
        #expect(audio.values.audio?.currentTime == 120)
        #expect(audio.values.finished == nil)
        #expect(try await store.completeSend(audio, serverLastUpdate: nil))

        let finished = try #require(try await store.beginSend(for: key))
        #expect(finished.values.audio == nil)
        #expect(finished.values.finished?.isFinished == true)
        #expect(try await store.completeSend(finished, serverLastUpdate: nil))
        #expect(try await store.beginSend(for: key) == nil)
    }
}
