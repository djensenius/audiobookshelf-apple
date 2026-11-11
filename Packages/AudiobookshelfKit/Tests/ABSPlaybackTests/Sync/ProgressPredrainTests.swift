import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressPredrainTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func edit(_ time: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600))
    }

    private func server(_ time: Double, at date: Date, itemID: String = "a") -> MediaProgress {
        MediaProgress(
            id: "p-\(itemID)", libraryItemId: itemID, duration: 3600, progress: time / 3600,
            currentTime: time, ebookProgress: 0, lastUpdate: Int(date.timeIntervalSince1970 * 1000))
    }

    private func baseline(_ time: Double, at date: Date) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: time, progress: time / 3600, duration: 3600, isFinished: false,
            ebookProgress: 0, lastUpdate: date)
    }

    @Test(arguments: [false, true])
    func observedNewerAudioWinsAndOnlyRemainingGroupsAreSent(localCompletion: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        try await s.store.recordEdit(edit(10), for: key, now: t0)
        let finishedAt = t0.addingTimeInterval(3)
        if localCompletion {
            try await s.store.recordEdit(ProgressEdit(isFinished: true), for: key, now: finishedAt)
        }
        s.service.state.withLock { $0.serverProgress[key] = server(90, at: t0.addingTimeInterval(2)) }

        await s.syncer.drainPendingProgress()

        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(
            s.service.patches
                == (localCompletion ? [.init(itemID: "a", update: .finished(true, at: finishedAt))] : []))
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 90 && row.isFinished == localCompletion && !row.needsServerSync)
        #expect(row.serverBaseline?.currentTime == 90)
        if !localCompletion { #expect(row.lastSyncAttemptAt == nil) }
    }

    @Test(arguments: [false, true])
    func heldLookupRejectsEditedGenerationWithoutSpinningAndLaterSendsLatest(absent: Bool) async throws {
        let s = try SyncHarness()
        let response = Gate()
        let started = Gate()
        defer {
            s.syncer.detach()
            response.open()
        }
        let key = s.h.key("a")
        let other = s.h.key("b")
        try await s.store.recordEdit(edit(10), for: key, now: t0)
        try await s.store.recordEdit(edit(30), for: other, now: t0.addingTimeInterval(1))
        s.service.state.withLock {
            if !absent { $0.serverProgress[key] = server(90, at: t0.addingTimeInterval(2)) }
            $0.fetchGates = [response]
            $0.fetchStarted = started
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(3))
        response.open()
        await drain.value

        #expect(s.service.state.withLock { $0.fetches } == [key, other])
        #expect(s.service.patches == [.init(itemID: "b", update: SyncHarness.audio(30))])
        let deferred = try #require(try await s.store.progress(for: key))
        #expect(deferred.currentTime == 80 && deferred.audioDirty)
        #expect(deferred.serverBaseline == nil && deferred.lastSyncAttemptAt == nil)

        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key, other, key])
        #expect(s.service.patches.last == .init(itemID: "a", update: SyncHarness.audio(80)))
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
    }

    @Test(arguments: ["undated", "wrongItem", "wrongEpisode"])
    func unusableRowDoesNotBlockAnotherRow(kind: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let other = s.h.key("b")
        try await s.store.recordEdit(edit(10), for: key, now: t0)
        try await s.store.recordEdit(edit(30), for: other, now: t0.addingTimeInterval(1))
        var unusable = server(90, at: t0.addingTimeInterval(2))
        if kind == "undated" { unusable.lastUpdate = nil }
        if kind == "wrongItem" { unusable.libraryItemId = "not-a" }
        if kind == "wrongEpisode" { unusable.episodeId = "not-the-book" }
        s.service.state.withLock { $0.serverProgress[key] = unusable }

        await s.syncer.drainPendingProgress()

        #expect(s.service.state.withLock { $0.fetches } == [key, other])
        #expect(s.service.patches == [.init(itemID: "b", update: SyncHarness.audio(30))])
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 10 && row.audioDirty)
        #expect(row.serverBaseline == nil && row.lastSyncAttemptAt == nil)
        #expect(row.unacknowledgedSends.isEmpty)
    }

    @Test(arguments: [APIError.timedOut, .forbidden(message: nil), .decoding("unsupported absence body")])
    func thrownLookupStopsFreshTransportWithoutLosingPendingRows(error: APIError) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let other = s.h.key("b")
        try await s.store.recordEdit(edit(10), for: key, now: t0)
        try await s.store.recordEdit(edit(30), for: other, now: t0.addingTimeInterval(1))
        s.service.state.withLock { $0.fetchErrors = [error] }

        await s.syncer.drainPendingProgress()

        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(s.service.patches.isEmpty)
        let pending = try await s.store.pendingSync(for: s.h.connectionID)
        #expect(pending.map(\.key) == [key, other])
        #expect(pending.allSatisfy { $0.lastSyncAttemptAt == nil && $0.unacknowledgedSends.isEmpty })
    }

    @Test(arguments: [false, true])
    func onlyDatedFetchReleasesPostAcknowledgementSuppression(absent: Bool) async throws {
        let s = try SyncHarness()
        let response = Gate()
        let started = Gate()
        defer {
            s.syncer.detach()
            response.open()
        }
        let key = s.h.key("a")
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        // The established 404/nil fixture must permit an ordinary first-progress write.
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(50))])
        #expect(await s.store.needsConfirmationFetch == [key])
        let generation = await s.store.captureGeneration()
        let merged = try await s.store.applyServerProgress(
            [key: baseline(50, at: t0.addingTimeInterval(1))], capturedAt: generation, source: .socket)
        #expect(merged.isEmpty)
        #expect(await s.store.needsConfirmationFetch == [key])

        try await s.store.recordEdit(
            ProgressEdit(ebook: .init(location: "epubcfi(/6/4)", progress: 0.4)),
            for: key, now: t0.addingTimeInterval(2))
        s.service.state.withLock {
            // The absent case models progress removed since the ACK, not an undated zero.
            if !absent { $0.serverProgress[key] = server(50, at: t0.addingTimeInterval(1)) }
            $0.patchGates = [response]
            $0.patchStarted = started
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        // Observe intake BEFORE the next PATCH ACK could establish a new confirmation obligation.
        #expect(await s.store.needsConfirmationFetch.contains(key) == absent)
        #expect(s.service.state.withLock { $0.fetches } == [key, key])
        #expect(s.service.patches.last?.update == .ebook(location: "epubcfi(/6/4)", progress: 0.4))
        response.open()
        await drain.value
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
    }

    @Test(arguments: ["quiesce", "detach", "accountSwitch"])
    func endedTransportDoesNotApplyHeldReplyOrStartAnotherLookup(ending: String) async throws {
        let s = try SyncHarness()
        let response = Gate()
        let started = Gate()
        defer {
            s.syncer.detach()
            response.open()
        }
        let key = s.h.key("a")
        try await s.store.recordEdit(edit(10), for: key, now: t0)
        try await s.store.recordEdit(edit(30), for: s.h.key("b"), now: t0.addingTimeInterval(1))
        s.service.state.withLock {
            $0.serverProgress[key] = server(90, at: t0.addingTimeInterval(2))
            $0.fetchGates = [response]
            $0.fetchStarted = started
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        switch ending {
        case "detach": s.syncer.detach()
        case "accountSwitch": s.coordinator.stop(reason: .accountSwitch)
        default: s.syncer.quiesceTransport()
        }
        // The fake deliberately returns the response despite cancellation.
        response.open()
        await drain.value
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(s.service.patches.isEmpty)
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 10 && row.audioDirty && row.serverBaseline == nil)
        #expect(try await s.store.pendingSync(for: s.h.connectionID).count == 2)
    }

    @Test(arguments: [false, true])
    func capturedPositionDuringFetchMustSettleBeforeAnyPatch(saveFails: Bool) async throws {
        let s = try SyncHarness()
        let response = Gate()
        let started = Gate()
        let persistence = Gate()
        let saving = Gate()
        defer {
            s.syncer.detach()
            response.open()
            persistence.open()
        }
        let key = s.h.key("a")
        await s.coordinator.play(itemID: "a")
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        s.service.state.withLock {
            $0.serverProgress[key] = server(0, at: t0.addingTimeInterval(-1))
            $0.fetchGates = [response]
            $0.fetchStarted = started
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        s.h.clock.advance(by: 1)
        s.h.engine.currentTime = 100
        s.coordinator.stop()
        await saving.wait()
        if saveFails { await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }
        persistence.open()
        await s.syncer.waitForPendingWrites()
        response.open()
        await drain.value
        #expect(s.service.patches.isEmpty)
        #expect(try await s.store.progress(for: key)?.currentTime == (saveFails ? 50 : 100))
        #expect(try await s.store.progress(for: key)?.audioDirty == true)

        s.syncer.beforePositionPersistence = nil
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(100))])
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
        await s.coordinator.waitForPendingCloses()
    }

    @Test func fullyPersistedPositionWhilePreparedPatchReturnsCannotSendObsoleteSnapshot() async throws {
        let s = try SyncHarness()
        let prepared = Gate()
        let response = Gate()
        defer {
            s.syncer.detach()
            response.open()
        }
        let key = s.h.key("a")
        await s.coordinator.play(itemID: "a")
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        s.service.state.withLock { $0.serverProgress[key] = server(0, at: t0.addingTimeInterval(-1)) }
        var captured: ProgressPatch?
        s.syncer.afterProgressSendPreparation = { patch in
            captured = patch
            prepared.open()
            await response.wait()
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await prepared.wait()
        let obsolete = try #require(captured)
        #expect(obsolete.values.audio?.currentTime == 50)
        #expect(s.service.patches.isEmpty)

        s.h.clock.advance(by: 1)
        s.h.engine.currentTime = 100
        s.coordinator.stop()
        // The entire owned persistence task, including removal from pendingPositions, finishes
        // while beginSend's actual prepared token is held. There is no outstanding write left.
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: key)?.currentTime == 100)
        #expect(try await s.store.progress(for: key)?.audioDirty == true)
        response.open()
        await drain.value

        #expect(s.service.patches.isEmpty, "A superseded, still-unsent PATCH must never reach transport")
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 100 && row.audioDirty && row.needsServerSync)
        #expect(row.lastSyncError == "pendingPosition")
        #expect(row.unacknowledgedSends == [obsolete.values])
        #expect(try await s.store.failSend(obsolete, error: "alreadySettledProbe") == false)

        s.syncer.afterProgressSendPreparation = nil
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(100))])
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
        await s.coordinator.waitForPendingCloses()
    }

    @Test(arguments: [false, true])
    func retainedPatchOutcomeRetriesBeforeFetchAndUsesPostSettlementGeneration(patchFails: Bool) async throws {
        let s = try SyncHarness()
        let patch = Gate()
        let patchStarted = Gate()
        let fetch = Gate()
        let fetchStarted = Gate()
        defer {
            s.syncer.detach()
            patch.open()
            fetch.open()
        }
        let key = s.h.key("a")
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        s.service.state.withLock {
            $0.patchGates = [patch]
            $0.patchStarted = patchStarted
            $0.patchErrors = patchFails ? [.timedOut] : []
        }
        let first = Task { await s.syncer.drainPendingProgress() }
        await patchStarted.wait()
        try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(1))
        await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        patch.open()
        await first.value
        #expect(s.service.state.withLock { $0.fetches } == [key])

        await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(s.service.patches.count == 1)

        s.service.state.withLock {
            // Both a successful PATCH and an ambiguous lost response can leave this value.
            $0.serverProgress[key] = server(50, at: t0.addingTimeInterval(2))
            $0.fetchGates = [fetch]
            $0.fetchStarted = fetchStarted
        }
        let retry = Task { await s.syncer.drainPendingProgress() }
        await fetchStarted.wait()
        #expect(await s.store.needsConfirmationFetch.contains(key) == !patchFails)
        fetch.open()
        await retry.value
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50), SyncHarness.audio(80)])
        #expect(s.service.state.withLock { $0.fetches } == [key, key])
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
    }

    @Test func retainedSessionAudioOutcomeAlsoBlocksFetchUntilCommitted() async throws {
        let s = try SyncHarness()
        let response = Gate()
        let processing = Gate()
        processing.open()
        defer {
            s.syncer.detach()
            response.open()
        }
        s.service.state.withLock {
            $0.serverSyncs = [
                .init(
                    key: s.h.key("a"), processedAt: t0.addingTimeInterval(15),
                    beforeProcessing: processing, processed: Gate(), response: response)
            ]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        response.open()
        await s.settle()
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches.isEmpty })
        #expect(s.service.patches.isEmpty && s.service.reports.count == 1)
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [s.h.key("a")])
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(15)])
        #expect(s.service.reports.count == 1)
    }

    @Test func automaticDrainMergesActualOlderSyncEchoWithoutLosingNewerCommittedAudio() async throws {
        let s = try SyncHarness()
        let processing = Gate()
        let processed = Gate()
        let response = Gate()
        defer {
            s.syncer.detach()
            processing.open()
            response.open()
        }
        let key = s.h.key("a")
        let reportedAt = t0.addingTimeInterval(15)
        let editedAt = reportedAt.addingTimeInterval(1)
        let processedAt = reportedAt.addingTimeInterval(2)
        s.service.state.withLock {
            $0.serverSyncs = [
                .init(
                    key: key, processedAt: processedAt, beforeProcessing: processing,
                    processed: processed, response: response)
            ]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        // A later committed writer intent, not a second report or a manufactured PATCH ACK.
        let token = s.store.reservePlaybackPosition(for: key)
        try await s.store.recordPlaybackPosition(
            .init(currentTime: 100, duration: 3600, progress: 100.0 / 3600),
            for: key, token: token, now: editedAt)
        processing.open()
        await processed.wait()
        #expect(s.service.state.withLock { $0.serverProgress[key]?.currentTime } == 15)
        response.open()
        await s.settle()

        #expect(s.service.reports.map(\.currentTime) == [15])
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(100)])
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 100 && !row.needsServerSync)
        #expect(row.serverBaseline?.lastUpdate == processedAt)
    }
}
