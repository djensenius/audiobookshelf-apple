import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct LocalProgressStoreTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func makeStore() throws -> (LocalProgressStore, ModelContainer) {
        let container = try DataStack(location: .inMemory).container
        return (LocalProgressStore(modelContainer: container), container)
    }

    private static func server(currentTime: Double = 100, ebookLocation: String? = nil, lastUpdate: Date)
        -> ProgressBaseline
    {
        ProgressBaseline(
            currentTime: currentTime, progress: currentTime / 1000, duration: 1000, isFinished: false,
            ebookLocation: ebookLocation, lastUpdate: lastUpdate)
    }

    private static func seek(_ currentTime: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: currentTime, duration: 1000, progress: currentTime / 1000))
    }

    // MARK: - CRUD and uniqueness

    @Test func recordEditCreatesSeededRowAndUpdatesInPlace() async throws {
        let (store, container) = try makeStore()
        let item = UUID()
        let created = try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), localLibraryItemID: item,
            now: Self.at(10))
        #expect(created.key == key)
        #expect(created.localLibraryItemID == item)
        #expect(created.startedAt == Self.at(10))
        #expect(created.serverBaseline == Self.server(lastUpdate: Self.t0))
        #expect(created.dirtyGroups == .audio)
        #expect(created.needsServerSync)

        let updated = try await store.recordEdit(Self.seek(250), for: key, now: Self.at(20))
        #expect(updated.currentTime == 250)
        #expect(updated.localLibraryItemID == item)
        #expect(updated.startedAt == Self.at(10))
        #expect(try await store.progress(for: key) == updated)
        #expect(try await store.progress(localLibraryItemID: item) == [updated])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
    }

    @Test func ebookOnlySaveCarriesNoAudioFields() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "epubcfi(/6/4)", progress: 0.3)), for: key,
            serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(5))
        let pending = try await store.pendingSync(for: Fixtures.connectionID)
        #expect(pending.count == 1)
        #expect(pending[0].audioDirty == false)
        #expect(pending[0].finishedDirty == false)
        #expect(pending[0].dirtyValues.audio == nil)
        #expect(pending[0].dirtyValues.finished == nil)

        let patch = try #require(try await store.beginSend(for: key))
        #expect(patch.values.groups == .ebook)
        #expect(patch.values.ebook?.ebookLocation == "epubcfi(/6/4)")
    }

    @Test func pendingSyncIsPerConnectionAndPruneKeepsDirtyAndLinkedRows() async throws {
        let (store, _) = try makeStore()
        let other = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_1")
        let synced = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2")
        let linked = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_3")
        try await store.recordEdit(Self.seek(1), for: key, now: Self.at(1))
        try await store.recordEdit(Self.seek(1), for: other, now: Self.at(1))
        for clean in [synced, linked] {
            try await store.recordEdit(Self.seek(1), for: clean, now: Self.at(1))
            let patch = try #require(try await store.beginSend(for: clean))
            try await store.completeSend(patch, serverLastUpdate: Self.at(2))
        }
        #expect(try await store.setLocalLibraryItemID(UUID(), for: linked))

        #expect(try await store.pendingSync(for: Fixtures.connectionID).map(\.key) == [key])
        #expect(try await store.pruneSynced() == 1)
        #expect(try await store.progress(for: synced) == nil)
        #expect(try await store.progress(for: linked) != nil)
        #expect(try await store.deleteProgress(for: key))
        #expect(try await store.deleteProgress(for: key) == false)
        #expect(try await store.setLocalLibraryItemID(nil, for: key) == false)
    }

    // MARK: - Sends

    @Test func onePatchInFlightPerRow() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(Self.seek(200), for: key, now: Self.at(1))
        let first = try #require(try await store.beginSend(for: key, now: Self.at(2)))
        #expect(try await store.beginSend(for: key) == nil)
        try await store.failSend(first, error: "offline")
        let row = try #require(try await store.progress(for: key))
        #expect(row.lastSyncError == "offline")
        #expect(row.lastSyncAttemptAt == Self.at(2))
        #expect(row.unacknowledgedSends == [first.values])
        #expect(row.needsServerSync)
        #expect(try await store.beginSend(for: key) != nil)
        #expect(try await store.beginSend(for: MediaKey(serverConnectionID: UUID(), libraryItemId: "none")) == nil)
    }

    @Test func editDuringPatchAdvancesBaselineAndSurvivesNextFetch() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        try await store.completeSend(patch, serverLastUpdate: Self.at(3))

        let acked = try #require(try await store.progress(for: key))
        #expect(acked.serverBaseline?.currentTime == 200)
        #expect(acked.currentTime == 300)
        #expect(acked.audioDirty)
        #expect(acked.unacknowledgedSends.isEmpty)

        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(3))], capturedAt: capture, source: .fetch)
        let fetched = try #require(try await store.progress(for: key))
        #expect(fetched.currentTime == 300)
        #expect(fetched.audioDirty)
    }

    @Test func lateCompletionOfSupersededPatchIsIgnored() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patchA = try #require(try await store.beginSend(for: key))
        #expect(try await store.failSend(patchA, error: "timed out"))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        let patchB = try #require(try await store.beginSend(for: key))
        #expect(patchB.token != patchA.token)

        // A's success arrives late, while B is in flight: nothing changes.
        let before = try await store.progress(for: key)
        #expect(try await store.completeSend(patchA, serverLastUpdate: Self.at(3)) == false)
        #expect(try await store.failSend(patchA, error: "again") == false)
        #expect(try await store.progress(for: key) == before)
        #expect(try await store.beginSend(for: key) == nil)

        #expect(try await store.completeSend(patchB, serverLastUpdate: Self.at(4)))
        let row = try #require(try await store.progress(for: key))
        #expect(row.serverBaseline?.currentTime == 300)
        #expect(row.dirtyGroups.isEmpty)
    }

    @Test func duplicateAcknowledgeIsIgnored() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        #expect(try await store.completeSend(patch, serverLastUpdate: Self.at(2)))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(3))
        let before = try await store.progress(for: key)
        #expect(try await store.completeSend(patch, serverLastUpdate: Self.at(2)) == false)
        #expect(try await store.progress(for: key) == before)
    }

    @Test func audioAndFinishedAreSentSeparatelyAndOnlyTheFailedOneIsResent() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(990), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        try await store.recordEdit(ProgressEdit(isFinished: true), for: key, now: Self.at(1))
        let audio = try #require(try await store.beginSend(for: key))
        #expect(audio.values.groups == .audio)
        #expect(try await store.completeSend(audio, serverLastUpdate: Self.at(2)))

        let finished = try #require(try await store.beginSend(for: key))
        #expect(finished.values.groups == .finished)
        #expect(try await store.failSend(finished, error: "offline"))
        var row = try #require(try await store.progress(for: key))
        #expect(row.dirtyGroups == .finished)
        #expect(row.unacknowledgedSends == [finished.values])

        let retry = try #require(try await store.beginSend(for: key))
        #expect(retry.values.groups == .finished)
        #expect(try await store.completeSend(retry, serverLastUpdate: Self.at(3)))
        row = try #require(try await store.progress(for: key))
        #expect(row.dirtyGroups.isEmpty)
        #expect(row.needsServerSync == false)
        #expect(row.unacknowledgedSends.isEmpty)
    }

    @Test func failedCommitRollsBackSendAndEdit() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))

        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.beginSend(for: key) }
        #expect(await store.hasUncommittedChanges == false)
        #expect(try await store.progress(for: key)?.unacknowledgedSends.isEmpty == true)

        let generation = await store.captureGeneration()
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) {
            try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        }
        #expect(await store.hasUncommittedChanges == false)
        #expect(await store.captureGeneration() == generation)
        #expect(try await store.progress(for: key)?.currentTime == 200)

        // No phantom in-flight send: the row can be sent and the next save commits only it.
        let patch = try #require(try await store.beginSend(for: key))
        #expect(patch.values.audio?.currentTime == 200)
        let reread = LocalProgressStore(modelContainer: store.modelContainer)
        #expect(try await reread.progress(for: key)?.unacknowledgedSends == [patch.values])
    }

    // MARK: - Stale and in-flight server values

    @Test func fetchIssuedBeforeLocalSeekChangesNothing() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let capture = await store.captureGeneration()
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        let before = try await store.progress(for: key)
        let merged = try await store.applyServerProgress(
            [key: Self.server(currentTime: 900, lastUpdate: Self.at(50))], capturedAt: capture, source: .fetch)
        #expect(merged.isEmpty)
        #expect(try await store.progress(for: key) == before)
    }

    @Test func fetchIssuedBeforePatchSettlesChangesNothing() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        let capture = await store.captureGeneration()
        try await store.failSend(patch, error: nil)
        let before = try await store.progress(for: key)
        #expect(
            try await store.applyServerProgress(
                [key: Self.server(currentTime: 900, lastUpdate: Self.at(50))], capturedAt: capture, source: .fetch
            )
            .isEmpty)
        #expect(try await store.progress(for: key) == before)
    }

    @Test(arguments: [true, false])
    func echoOfInFlightPatchAfterNewerSeekIsDeferred(_ succeeds: Bool) async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        // A socket echo of the PATCH (newer `lastUpdate`, older values) received after the seek.
        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(5))], capturedAt: capture, source: .socket)
        var row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
        #expect(row.serverBaseline?.currentTime == 100)

        if succeeds {
            try await store.completeSend(patch, serverLastUpdate: Self.at(5))
        } else {
            try await store.failSend(patch, error: "lost")
        }
        row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
        #expect(try await store.beginSend(for: key)?.values.audio?.currentTime == 300)
    }

    /// The PATCH's 200 has no body, so its server time is unknown. A socket event received after
    /// the acknowledgement may have been emitted before the PATCH was applied; whatever its
    /// `lastUpdate` (equal to the baseline's, later, or earlier), it can't roll the acknowledged
    /// value back.
    @Test(arguments: [0, 0.5, -1] as [TimeInterval])
    func socketValueEmittedBeforeAckedPatchIsIgnored(_ offset: TimeInterval) async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: nil)

        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 100, lastUpdate: Self.at(offset))], capturedAt: capture, source: .socket)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 200)
        #expect(row.dirtyGroups.isEmpty)
        #expect(row.serverBaseline?.currentTime == 200)
    }

    /// Another write in the millisecond of our acknowledged one may have been emitted before it, so
    /// once the row's server time is known (a timed acknowledgement or the confirming fetch), a
    /// socket value with that time is ignored.
    @Test(arguments: [true, false])
    func socketValueTyingTheAcknowledgedWriteIsIgnored(_ timed: Bool) async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: timed ? Self.at(2) : nil)
        if !timed {
            try await store.applyServerProgress(
                [key: Self.server(currentTime: 200, lastUpdate: Self.at(2))],
                capturedAt: await store.captureGeneration(), source: .fetch)
        }

        try await store.applyServerProgress(
            [key: Self.server(currentTime: 700, lastUpdate: Self.at(2))], capturedAt: await store.captureGeneration(),
            source: .socket)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 200)
        #expect(row.dirtyGroups.isEmpty)
    }

    /// Overlapping fetches can be read on either side of another write in the same millisecond:
    /// once the later response is applied, the earlier one with the same `lastUpdate` is ignored.
    @Test func earlierFetchResponseWithTheSameTimeIsIgnored() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: nil)
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(2))], capturedAt: await store.captureGeneration(),
            source: .fetch)

        let first = await store.captureGeneration()
        let second = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 700, lastUpdate: Self.at(5))], capturedAt: second, source: .fetch)
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 300, lastUpdate: Self.at(5))], capturedAt: first, source: .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 700)
        #expect(row.dirtyGroups.isEmpty)

        // A fetch issued after that merge was read after the server held 700, so a value with the
        // same time is a later write.
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 800, lastUpdate: Self.at(5))], capturedAt: await store.captureGeneration(),
            source: .fetch)
        #expect(try await store.progress(for: key)?.currentTime == 800)
    }

    /// Two edits with the same clock reading are still told apart: acknowledging the first leaves
    /// the second dirty.
    @Test func editWithTheSameTimeAsTheSentOneStaysDirty() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(1))
        try await store.completeSend(patch, serverLastUpdate: nil)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
    }

    /// A socket value equal to the acknowledged one doesn't prove it was emitted after the PATCH:
    /// queued pre-PATCH events of 200 and then 100 leave the row at 200 until a fetch.
    @Test func equalSocketValueDoesNotReleaseTheHold() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: nil)
        #expect(await store.needsConfirmationFetch == [key])

        let capture = await store.captureGeneration()
        for (time, offset) in [(200.0, 0.5), (100.0, 0.6)] {
            try await store.applyServerProgress(
                [key: Self.server(currentTime: time, lastUpdate: Self.at(offset))], capturedAt: capture,
                source: .socket)
        }
        #expect(try await store.progress(for: key)?.currentTime == 200)
        #expect(await store.needsConfirmationFetch == [key])

        // The fetch issued after the ack confirms; the held 100 is older and is dropped.
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(2))], capturedAt: capture, source: .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 200)
        #expect(row.dirtyGroups.isEmpty)
        #expect(await store.needsConfirmationFetch.isEmpty)
    }

    /// The server auto-finishes an un-finish sent fewer than 10 s from the end. Another device's
    /// later write arrives by socket before the confirming fetch: the fetch's normalized value is
    /// taken, then the held socket value, which is newer.
    @Test func confirmingFetchTakesNormalizedValueAndThenNewerSocketValue() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            ProgressEdit(isFinished: false), for: key,
            serverProgress: Self.server(currentTime: 995, lastUpdate: Self.t0),
            now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        #expect(patch.values.groups == .finished)
        try await store.completeSend(patch, serverLastUpdate: nil)

        let capture = await store.captureGeneration()
        var server = Self.server(currentTime: 995, lastUpdate: Self.at(2))
        server.isFinished = true
        server.finishedAt = Self.at(2)
        var other = server
        other.ebookLocation = "epubcfi(/6/8)"
        other.lastUpdate = Self.at(9)
        try await store.applyServerProgress([key: other], capturedAt: capture, source: .socket)
        try await store.applyServerProgress([key: server], capturedAt: capture, source: .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.isFinished)
        #expect(row.ebookLocation == "epubcfi(/6/8)")
        #expect(row.dirtyGroups.isEmpty)
        #expect(await store.needsConfirmationFetch.isEmpty)
    }

    /// Two server writes can share a millisecond: a held pre-PATCH snapshot with the same
    /// `lastUpdate` as the confirming fetch is dropped, so the fetch's value stands.
    @Test func heldSocketValueTyingTheConfirmingFetchIsDropped() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: nil)

        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 100, lastUpdate: Self.at(2))], capturedAt: capture, source: .socket)
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(2))], capturedAt: capture, source: .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 200)
        #expect(row.dirtyGroups.isEmpty)
        #expect(await store.needsConfirmationFetch.isEmpty)
    }

    /// A held socket value captured before a later local edit is dropped, as it would have been
    /// without the hold.
    @Test func heldSocketValueCapturedBeforeAnEditIsDropped() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: nil)
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 700, lastUpdate: Self.at(9))], capturedAt: await store.captureGeneration(),
            source: .socket)
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(3))

        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(2))], capturedAt: await store.captureGeneration(),
            source: .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
    }

    /// Another device's later value still arrives: by a fetch, or at once by socket when the
    /// response had a server time.
    @Test(arguments: [true, false])
    func newerValueAfterAckedPatchIsTaken(_ timed: Bool) async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: timed ? Self.at(2) : nil)
        #expect(await store.needsConfirmationFetch == (timed ? [] : [key]))

        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 700, lastUpdate: Self.at(9))], capturedAt: capture,
            source: timed ? .socket : .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 700)
        #expect(row.dirtyGroups.isEmpty)
    }

    @Test func lostResponseIsRecognisedAfterRelaunch() async throws {
        let (store, container) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patchA = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        try await store.failSend(patchA, error: "timed out")  // A committed; its response was lost.
        let patchB = try #require(try await store.beginSend(for: key))
        try await store.failSend(patchB, error: "offline")  // B never reached the server.

        // A new process: in-memory generations are gone, the send history is persisted.
        let relaunched = LocalProgressStore(modelContainer: container)
        let capture = await relaunched.captureGeneration()
        try await relaunched.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(3))], capturedAt: capture, source: .fetch)
        let row = try #require(try await relaunched.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
        #expect(row.unacknowledgedSends == [patchB.values])
        #expect(try await relaunched.beginSend(for: key)?.values.audio?.currentTime == 300)
    }

    @Test func serverProgressForUnknownMediaIsIgnored() async throws {
        let (store, _) = try makeStore()
        let capture = await store.captureGeneration()
        #expect(
            try await store.applyServerProgress(
                [key: Self.server(lastUpdate: Self.t0)], capturedAt: capture, source: .fetch
            ).isEmpty)
        #expect(try await store.progress(for: key) == nil)
    }

    // MARK: - Connections

    @Test func removedConnectionKeepsProgressForTheNextLogin() async throws {
        let (store, container) = try makeStore()
        let connections = ServerConnectionStore(modelContainer: container)
        let address = try #require(ServerAddress("https://abs.example.com"))
        let connection = try await connections.upsertLogin(
            address: address, userId: "usr_1", username: "reader", authMethod: .local, serverVersion: nil)
        let progressKey = MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1")
        try await store.recordEdit(Self.seek(42), for: progressKey)

        #expect(try await connections.remove(id: connection.id) == .disconnected)
        let again = try await connections.upsertLogin(
            address: address, userId: "usr_1", username: "reader", authMethod: .local, serverVersion: nil)
        #expect(again.id == connection.id)
        #expect(try await store.pendingSync(for: again.id).map(\.key) == [progressKey])
    }

    // MARK: - Pending sessions

    private func session(_ id: String, startedAt: Date, updatedAt: Date, isActive: Bool = false)
        -> PendingLocalSessionDTO
    {
        PendingLocalSessionDTO(
            id: id, key: key, userId: "usr_1", mediaType: .book, displayTitle: "The Book", duration: 1000,
            startTime: 10, startedAt: startedAt, updatedAt: updatedAt, timeListening: 30, currentTime: 40,
            isActive: isActive)
    }

    @Test func savesReadsAndDeletesSessions() async throws {
        let (store, container) = try makeStore()
        let later = session("b", startedAt: Self.at(10), updatedAt: Self.at(10))
        var earlier = session("a", startedAt: Self.at(1), updatedAt: Self.at(1))
        try await store.saveSession(later)
        try await store.saveSession(earlier)
        earlier.currentTime = 90
        earlier.updatedAt = Self.at(2)
        try await store.saveSession(earlier)

        #expect(try await store.session(id: "a") == earlier)
        #expect(try await store.pendingSessions(for: Fixtures.connectionID) == [earlier, later])
        #expect(try await store.pendingSessions(for: UUID()).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PendingLocalSession>()) == 2)
        #expect(try await store.deleteSession(id: "a"))
        #expect(try await store.deleteSession(id: "a") == false)
    }

    @Test func settlesUploadPerSessionResult() async throws {
        let (store, _) = try makeStore()
        let done = session("done", startedAt: Self.at(1), updatedAt: Self.at(1))
        let changed = session("changed", startedAt: Self.at(2), updatedAt: Self.at(2))
        let active = session("active", startedAt: Self.at(3), updatedAt: Self.at(3), isActive: true)
        let failed = session("failed", startedAt: Self.at(4), updatedAt: Self.at(4))
        for item in [done, changed, active, failed] {
            try await store.saveSession(item)
        }
        var sent = Dictionary(uniqueKeysWithValues: [done, changed, active, failed].map { ($0.id, $0.updatedAt) })
        // Changed while the upload was in flight.
        var newer = changed
        newer.updatedAt = Self.at(20)
        try await store.saveSession(newer)

        let results: [String: SessionUploadResult] = [
            "done": .success, "changed": .success, "active": .success, "failed": .failure("Media item not found"),
        ]
        let now = Self.at(100)
        let deleted = try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: false, now: now)
        #expect(deleted == ["done"])
        let failedRow = try #require(try await store.session(id: "failed"))
        #expect(failedRow.uploadAttempts == 1)
        #expect(failedRow.lastUploadError == "Media item not found")

        // The first sync after login also deletes acknowledged active sessions. A second failure
        // within the hour isn't counted.
        sent["changed"] = Self.at(20)
        let firstSync = try await store.settleSessionUpload(
            sent: sent, results: results, isFirstSync: true, now: now.addingTimeInterval(60))
        #expect(firstSync == ["changed", "active"])
        #expect(try await store.session(id: "failed")?.uploadAttempts == 1)

        // One failure per window; discarded after the fifth.
        let window = LocalProgressStore.uploadFailureWindow
        for round in 2..<LocalProgressStore.maxUploadFailures {
            let later = now.addingTimeInterval(Double(round) * window)
            #expect(
                try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: false, now: later)
                    .isEmpty)
            #expect(try await store.session(id: "failed")?.uploadAttempts == round)
        }
        let last = now.addingTimeInterval(Double(LocalProgressStore.maxUploadFailures) * window)
        #expect(
            try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: false, now: last) == [
                "failed"
            ])
        #expect(try await store.pendingSessions(for: Fixtures.connectionID).isEmpty)
    }

    @Test func missingResultsCountAsOneFailureAfterThree() async throws {
        let (store, _) = try makeStore()
        let missing = session("missing", startedAt: Self.at(1), updatedAt: Self.at(1))
        try await store.saveSession(missing)
        let sent = ["missing": missing.updatedAt]
        for round in 1...LocalProgressStore.missingResultsPerFailure {
            try await store.settleSessionUpload(
                sent: sent, results: [:], isFirstSync: false, now: Self.at(Double(round)))
            let row = try #require(try await store.session(id: "missing"))
            let counted = round == LocalProgressStore.missingResultsPerFailure
            #expect(row.uploadAttempts == (counted ? 1 : 0))
            #expect(row.lastUploadError == (counted ? "No upload result" : nil))
        }
    }

    @Test func failureOfSessionChangedDuringUploadIsNotCounted() async throws {
        let (store, _) = try makeStore()
        var item = session("s", startedAt: Self.at(1), updatedAt: Self.at(1))
        try await store.saveSession(item)
        let sent = ["s": item.updatedAt]
        item.updatedAt = Self.at(5)
        try await store.saveSession(item)
        for round in 0..<(LocalProgressStore.maxUploadFailures + 1) {
            let later = Self.at(Double(round) * LocalProgressStore.uploadFailureWindow * 2)
            try await store.settleSessionUpload(
                sent: sent, results: ["s": .failure("x")], isFirstSync: false, now: later)
            try await store.settleSessionUpload(sent: sent, results: [:], isFirstSync: false, now: later)
        }
        let row = try #require(try await store.session(id: "s"))
        #expect(row.uploadAttempts == 0)
        // The error is still kept for diagnostics.
        #expect(row.lastUploadError == "x")
    }

    @Test func uncountedFailureStillRecordsTheLatestError() async throws {
        let (store, _) = try makeStore()
        let item = session("s", startedAt: Self.at(1), updatedAt: Self.at(1))
        try await store.saveSession(item)
        let sent = ["s": item.updatedAt]
        try await store.settleSessionUpload(
            sent: sent, results: ["s": .failure("first")], isFirstSync: false, now: Self.at(10))
        // Within the hour: not counted, but the message is newer.
        try await store.settleSessionUpload(
            sent: sent, results: ["s": .failure("second")], isFirstSync: false, now: Self.at(20))
        let row = try #require(try await store.session(id: "s"))
        #expect(row.uploadAttempts == 1)
        #expect(row.lastUploadError == "second")
    }

    @Test func successResetsAttemptsOfKeptActiveSession() async throws {
        let (store, _) = try makeStore()
        let active = session("active", startedAt: Self.at(1), updatedAt: Self.at(1), isActive: true)
        try await store.saveSession(active)
        let sent = ["active": active.updatedAt]
        try await store.settleSessionUpload(sent: sent, results: ["active": .failure("boom")], isFirstSync: false)
        #expect(try await store.session(id: "active")?.uploadAttempts == 1)

        #expect(
            try await store.settleSessionUpload(sent: sent, results: ["active": .success], isFirstSync: false).isEmpty)
        let row = try #require(try await store.session(id: "active"))
        #expect(row.uploadAttempts == 0)
        #expect(row.lastUploadError == nil)
    }

    @Test func saveSessionKeepsUploadBookkeeping() async throws {
        let (store, _) = try makeStore()
        var item = session("s", startedAt: Self.at(1), updatedAt: Self.at(1))
        try await store.saveSession(item)
        try await store.settleSessionUpload(
            sent: ["s": item.updatedAt], results: ["s": .failure("boom")], isFirstSync: false)

        // The caller's copy still has the defaults; saving it must not reset the bookkeeping.
        item.currentTime = 99
        item.updatedAt = Self.at(2)
        item.uploadAttempts = 0
        item.lastUploadError = nil
        try await store.saveSession(item)
        let row = try #require(try await store.session(id: "s"))
        #expect(row.currentTime == 99)
        #expect(row.uploadAttempts == 1)
        #expect(row.lastUploadError == "boom")
    }
}
