import ABSCore
import Foundation
import Testing

@testable import ABSData

struct SessionAudioEvidenceTests {
    private let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "a")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> LocalProgressStore {
        LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    private func audio(_ time: Double) -> ProgressEdit.Audio {
        .init(currentTime: time, duration: 3600, progress: time / 3600)
    }

    private func commit(_ time: Double, to store: LocalProgressStore, at date: Date) async throws
        -> PlaybackPositionToken
    {
        let token = store.reservePlaybackPosition(for: key)
        _ = try await store.recordPlaybackPosition(audio(time), for: key, token: token, now: date)
        return token
    }

    private func prepare(_ store: LocalProgressStore, token: PlaybackPositionToken, time: Double = 15) async throws
        -> SessionAudioSend
    {
        try #require(
            try await store.prepareSessionAudio(for: key, token: token, audio: audio(time), sessionID: "a-1"))
    }

    private func intake(
        _ time: Double, into store: LocalProgressStore, source: ServerProgressSource = .fetch,
        expectedMerge: Bool = true
    )
        async throws
    {
        let generation = await store.captureGeneration()
        let server = ProgressBaseline(
            currentTime: time, progress: time / 3600, duration: 3600, isFinished: false,
            ebookProgress: 0, lastUpdate: t0 + 2)
        let merged = try await store.applyServerProgress([key: server], capturedAt: generation, source: source)
        #expect(merged == (expectedMerge ? [key] : []))
    }

    @Test func legacyEntriesDecodeWithoutSessionMetadata() throws {
        let legacy = Data(
            #"{"audio":{"currentTime":15,"duration":3600,"progress":0.004166666666666667,"editedAt":0}}"#.utf8)
        let decoded = try JSONDecoder().decode(ProgressSend.self, from: legacy)
        #expect(decoded.sessionAudio == nil)
        #expect(decoded.audio?.currentTime == 15)
        var modern = decoded
        modern.sessionAudio = .init(attemptID: UUID(), sessionID: "a-1", outcome: .ambiguous)
        #expect(try JSONDecoder().decode(ProgressSend.self, from: JSONEncoder().encode(modern)) == modern)
    }

    @Test(arguments: [15.0, 100.0])
    func matchingReportNeverAcknowledgesANewerEditEvenWhenValuesRepeat(newer: Double) async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        let send = try await prepare(store, token: token)
        let prepared = try #require(try await store.progress(for: key))
        #expect(prepared.unacknowledgedSends.count == 1)
        #expect(prepared.unacknowledgedSends.first?.audio?.editedAt == prepared.audioEditedAt)
        #expect(prepared.unacknowledgedSends.first?.sessionAudio?.attemptID == send.attemptID)
        #expect(prepared.unacknowledgedSends.first?.groups == .audio)
        _ = try await commit(newer, to: store, at: t0 + 1)
        try await intake(15, into: store)
        try await store.settleSessionAudio(send, outcome: .succeeded)
        for source in [ServerProgressSource.socket, .fetch, .socket, .fetch] {
            // Equal-dated sockets are rejected before merge; a fresh fetch may take the tie.
            try await intake(15, into: store, source: source, expectedMerge: source == .fetch)
            let row = try #require(try await store.progress(for: key))
            #expect(row.currentTime == newer && row.audioDirty && row.needsServerSync)
            #expect(row.unacknowledgedSends.first?.audio?.editedAt == prepared.audioEditedAt)
        }
    }

    @Test(arguments: [false, true], [ServerProgressSource.fetch, .socket])
    func nonmatchingNewerServerAudioStillWins(settled: Bool, source: ServerProgressSource) async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        let send = try await prepare(store, token: token)
        _ = try await commit(100, to: store, at: t0 + 1)
        if settled { try await store.settleSessionAudio(send, outcome: .succeeded) }
        try await intake(250, into: store, source: source)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 250 && !row.audioDirty)
        if !settled { try await store.settleSessionAudio(send, outcome: .succeeded) }
    }

    @Test func reportOnlyOwnsAudioAndCannotAcknowledgeCompletionOrEbook() async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        try await store.recordEdit(
            ProgressEdit(isFinished: true, ebook: .init(location: "new-location", progress: 0.7)),
            for: key, now: t0 + 1)
        let send = try await prepare(store, token: token)
        try await store.settleSessionAudio(send, outcome: .succeeded)
        #expect(try await store.progress(for: key)?.serverBaseline == nil)
        try await intake(15, into: store)
        let row = try #require(try await store.progress(for: key))
        #expect(row.isFinished && row.finishedDirty)
        #expect(row.ebookLocation == "new-location" && row.ebookProgress == 0.7 && row.ebookDirty)
        #expect(row.audioDirty)
        #expect(row.unacknowledgedSends.allSatisfy { $0.finished == nil && $0.ebook == nil })
    }

    @Test func rejectionRemovesOnlyTheExactAttempt() async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        let first = try await prepare(store, token: token)
        try await store.settleSessionAudio(first, outcome: .ambiguous)
        let second = try await prepare(store, token: token)
        #expect(first.attemptID != second.attemptID)
        try await store.settleSessionAudio(second, outcome: .notDelivered)
        try await store.settleSessionAudio(second, outcome: .succeeded)
        let row = try #require(try await store.progress(for: key))
        #expect(row.unacknowledgedSends.map { $0.sessionAudio?.attemptID } == [first.attemptID])
        #expect(row.serverBaseline == nil && row.audioDirty)
    }

    @Test func autoFinishedReportEchoCannotAcknowledgePendingUnfinish() async throws {
        let store = try store()
        let seed = ProgressBaseline(
            currentTime: 0, progress: 0, duration: 3600, isFinished: false, ebookProgress: 0, lastUpdate: t0 - 10)
        try await store.recordEdit(
            ProgressEdit(audio: audio(0)), for: key, serverProgress: seed, now: t0 - 10)
        let token = try await commit(3595, to: store, at: t0)
        let send = try await prepare(store, token: token, time: 3595)
        _ = try await commit(100, to: store, at: t0 + 1)
        try await store.recordEdit(
            ProgressEdit(isFinished: false, ebook: .init(location: "retained-local", progress: 0.7)),
            for: key, now: t0 + 1)
        try await store.settleSessionAudio(send, outcome: .succeeded)
        // An update to existing server progress with fewer than 10 seconds remaining auto-finishes.
        let server = ProgressBaseline(
            currentTime: 3595, progress: 1, duration: 3600, isFinished: true,
            finishedAt: t0 + 2, ebookProgress: 0, lastUpdate: t0 + 2)
        let generation = await store.captureGeneration()
        try await store.applyServerProgress([key: server], capturedAt: generation, source: .fetch)
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 100 && row.audioDirty)
        #expect(!row.isFinished && row.finishedAt == nil && row.finishedDirty)
        #expect(row.ebookLocation == "retained-local" && row.ebookProgress == 0.7 && row.ebookDirty)
        #expect(row.unacknowledgedSends.first?.groups == .audio)
    }

    @Test(arguments: [false, true])
    func supersededCaptureIsNotRelabeledAsLatestAudio(genericEdit: Bool) async throws {
        let store = try store()
        let old = try await commit(15, to: store, at: t0)
        if genericEdit {
            try await store.recordEdit(ProgressEdit(audio: audio(15)), for: key, now: t0 - 1)
        } else {
            _ = try await commit(15, to: store, at: t0 - 1)
        }
        #expect(
            try await store.prepareSessionAudio(for: key, token: old, audio: audio(15), sessionID: "a-1") == nil)
        #expect(try await store.progress(for: key)?.unacknowledgedSends.isEmpty == true)
    }

    @Test func evidenceUsesTheCommittedEditIdentityWhenTheClockMovesBackwards() async throws {
        let store = try store()
        _ = try await commit(50, to: store, at: t0)
        let token = try await commit(15, to: store, at: t0 - 1)
        let committed = try #require(try await store.progress(for: key))
        _ = try await prepare(store, token: token)
        let evidence = try #require(try await store.progress(for: key)?.unacknowledgedSends.first)
        #expect(evidence.audio?.editedAt == committed.audioEditedAt)
        #expect(try #require(evidence.audio?.editedAt) > t0)
    }

    @Test func anotherWriterCannotPrepareEvidenceFromThisWritersToken() async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        let other = try self.store()
        await #expect(throws: PlaybackPositionCommitError.wrongWriter) {
            try await other.prepareSessionAudio(for: key, token: token, audio: audio(15), sessionID: "a-1")
        }
        #expect(try await other.progress(for: key) == nil)
        #expect(try await store.progress(for: key)?.unacknowledgedSends.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func evidenceFailureDoesNotRegisterAnAttempt(lookupFails: Bool) async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        if lookupFails {
            await store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        } else {
            await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        await #expect(throws: CocoaError.self) { try await prepare(store, token: token) }
        #expect(try await store.progress(for: key)?.unacknowledgedSends.isEmpty == true)
        _ = try await prepare(store, token: token)
    }

    @Test(arguments: [SessionAudioOutcome.succeeded, .notDelivered, .ambiguous], [false, true])
    func failedSettlementBlocksNewSendsAndRetriesTheExactOutcome(
        outcome: SessionAudioOutcome, lookupFails: Bool
    ) async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        let send = try await prepare(store, token: token)
        _ = try await commit(100, to: store, at: t0 + 1)
        if lookupFails {
            await store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        } else {
            await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        await #expect(throws: CocoaError.self) { try await store.settleSessionAudio(send, outcome: outcome) }
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.beginSend(for: key) }
        #expect(try await store.progress(for: key)?.currentTime == 100)
        // A contradictory later call must not replace the retained original outcome.
        try await store.settleSessionAudio(send, outcome: outcome == .notDelivered ? .succeeded : .notDelivered)
        let row = try #require(try await store.progress(for: key))
        #expect(row.unacknowledgedSends.isEmpty == (outcome == .notDelivered))
        #expect(row.currentTime == 100 && row.audioDirty && row.serverBaseline == nil)
    }

    @Test func recreatedRowKeepsEvidenceButNotTheOldCaptureIdentity() async throws {
        let store = try store()
        let old = try await commit(15, to: store, at: t0)
        let send = try await prepare(store, token: old)
        try await store.deleteProgress(for: key)
        try await store.recordEdit(ProgressEdit(audio: audio(100)), for: key, now: t0 + 1)
        try await intake(15, into: store)
        #expect(try await store.progress(for: key)?.currentTime == 100)
        try await store.settleSessionAudio(send, outcome: .succeeded)
        #expect(try await store.progress(for: key)?.audioDirty == true)
        #expect(
            try await store.prepareSessionAudio(for: key, token: old, audio: audio(15), sessionID: "a-1") == nil)
    }

    @Test func diskReopenKeepsPreparedEvidenceAfterOutcomeSaveFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SessionAudio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        func leavePending() async throws {
            let stack = try DataStack(location: .url(url))
            let store = LocalProgressStore(modelContainer: stack.container)
            let token = try await commit(15, to: store, at: t0)
            let send = try await prepare(store, token: token)
            _ = try await commit(100, to: store, at: t0 + 1)
            await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
            await #expect(throws: CocoaError.self) { try await store.settleSessionAudio(send, outcome: .succeeded) }
        }
        try await leavePending()
        let stack = try DataStack(location: .url(url))
        let reopened = LocalProgressStore(modelContainer: stack.container)
        try await intake(15, into: reopened)
        let row = try #require(try await reopened.progress(for: key))
        #expect(row.currentTime == 100 && row.audioDirty)
        #expect(row.unacknowledgedSends.first?.sessionAudio?.outcome == nil)
    }

    @Test func patchAcknowledgementStillRequiresFetchNotEqualSocket() async throws {
        let store = try store()
        let token = try await commit(15, to: store, at: t0)
        let send = try await prepare(store, token: token)
        try await store.settleSessionAudio(send, outcome: .succeeded)
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: nil)
        #expect(await store.needsConfirmationFetch == [key])
        let generation = await store.captureGeneration()
        let server = ProgressBaseline(
            currentTime: 15, progress: 15.0 / 3600, duration: 3600, isFinished: false, lastUpdate: t0 + 2)
        #expect(
            try await store.applyServerProgress([key: server], capturedAt: generation, source: .socket).isEmpty)
        #expect(await store.needsConfirmationFetch == [key])
        try await intake(15, into: store)
        #expect(await store.needsConfirmationFetch.isEmpty)
        #expect(try await store.progress(for: key)?.unacknowledgedSends.isEmpty == true)
    }

    @Test func reportHistoryIsBoundedWithoutCoalescingAttemptIdentities() {
        var state = ProgressSyncState(lastUpdate: t0)
        state.apply(ProgressEdit(audio: audio(100)), now: t0 + 1)
        for _ in 0...ProgressSend.historyLimit {
            var send = ProgressSend(
                audio: .init(currentTime: 15, progress: 15.0 / 3600, duration: 3600, editedAt: t0))
            send.sessionAudio = .init(attemptID: UUID(), sessionID: "a-1")
            state.recordSessionAudio(send)
        }
        #expect(state.unacknowledgedSends.count == ProgressSend.historyLimit)
        #expect(state.truncated.contains(.audio))
        #expect(
            Set(state.unacknowledgedSends.compactMap { $0.sessionAudio?.attemptID }).count == ProgressSend.historyLimit)
    }
}
