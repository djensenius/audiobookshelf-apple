import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressConfirmationTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func edit(_ time: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600))
    }

    private func server(_ key: MediaKey, time: Double = 50, seconds: Double = 1) -> MediaProgress {
        MediaProgress(
            id: "p-\(key.libraryItemId)", libraryItemId: key.libraryItemId, episodeId: key.episodeId,
            duration: 3600, progress: time / 3600, currentTime: time, ebookProgress: 0,
            lastUpdate: Int(t0.addingTimeInterval(seconds).timeIntervalSince1970 * 1000))
    }

    private func baseline(_ time: Double, seconds: Double) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: time, progress: time / 3600, duration: 3600, isFinished: false,
            ebookProgress: 0, lastUpdate: t0.addingTimeInterval(seconds))
    }

    @discardableResult
    private func acknowledge(_ s: SyncHarness, _ key: MediaKey, time: Double = 50) async throws -> ProgressPatch {
        try await s.store.recordEdit(edit(time), for: key, now: t0)
        let patch = try #require(try await s.store.beginSend(for: key))
        #expect(try await s.store.completeSend(patch, serverLastUpdate: nil))
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == patch.token)
        return patch
    }

    /// Always releases and joins the owned transport task, including on a thrown requirement.
    private func holding(
        _ s: SyncHarness, patch: Bool = false, body: () async throws -> Void
    ) async throws {
        let response = Gate()
        let started = Gate()
        s.service.state.withLock {
            if patch {
                $0.patchGates = [response]
                $0.patchStarted = started
            } else {
                $0.fetchGates = [response]
                $0.fetchStarted = started
            }
        }
        let task = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        do {
            try await body()
        } catch {
            s.syncer.quiesceTransport()
            response.open()
            await task.value
            throw error
        }
        response.open()
        await task.value
    }

    @Test func finalAcknowledgementAutomaticallyConfirmsWithoutAnotherEdit() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        // The PATCH fake does not store progress. Configure the post-PATCH canonical reply.
        s.service.state.withLock { $0.fetchReplies = [nil, server(key)] }
        await s.syncer.drainPendingProgress()

        #expect(s.service.log == ["get a", "patch a", "get a"])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 50 && !row.needsServerSync)
        #expect(row.serverBaseline?.lastUpdate == t0.addingTimeInterval(1))
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get a", "patch a", "get a"], "No PATCH resend or unnecessary clean GET")
    }

    @Test(arguments: ["nil", "undated", "wrongItem", "wrongEpisode"])
    func unusableConfirmationRetainsOnlyItsObligationAndCleanDrainRetries(kind: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let other = s.h.key("b")
        let patch = try await acknowledge(s, key)
        try await acknowledge(s, other)
        var reply = server(key)
        if kind == "undated" { reply.lastUpdate = nil }
        if kind == "wrongItem" { reply.libraryItemId = "wrong" }
        if kind == "wrongEpisode" { reply.episodeId = "wrong" }
        s.service.state.withLock {
            $0.serverProgress[key] = kind == "nil" ? nil : reply
            $0.serverProgress[other] = server(other)
        }
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key, other])
        #expect(await s.store.needsConfirmationFetch == [key])
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == patch.token)
        #expect(try await s.store.pendingSync(for: s.h.connectionID).isEmpty)

        s.service.state.withLock { $0.serverProgress[key] = server(key) }
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key, other, key])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(s.service.patches.isEmpty)
    }

    @Test(arguments: [false, true])
    func rejectedPredrainDoesNotRetrySameAckButNewAckGetsFreshRead(newAck: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let first = try await acknowledge(s, key)
        try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(2))
        s.service.state.withLock { $0.serverProgress[key] = server(key) }
        var latest = first.token
        try await holding(s) {
            // Generation rejection is not a confirmation, regardless of the merged-key result.
            if newAck {
                let patch = try #require(try await s.store.beginSend(for: key))
                try await s.store.completeSend(patch, serverLastUpdate: nil)
                latest = patch.token
                s.service.state.withLock { $0.serverProgress[key] = server(key, time: 80, seconds: 3) }
            } else {
                try await s.store.recordEdit(edit(90), for: key, now: t0.addingTimeInterval(3))
            }
        }
        #expect(s.service.state.withLock { $0.fetches } == (newAck ? [key, key] : [key]))
        #expect(s.service.patches.isEmpty)
        #expect(latest != first.token || !newAck)
        #expect(await s.store.needsConfirmationFetch == (newAck ? [] : [key]))
        #expect(try await s.store.progress(for: key)?.currentTime == (newAck ? 80 : 90))
        #expect(try await s.store.progress(for: key)?.audioDirty == !newAck)
    }

    @Test func absenceBeforeNewAckAllowsExactlyOneFreshConfirmation() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        try await acknowledge(s, key)
        try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(2))
        s.service.state.withLock { $0.fetchReplies = [nil, server(key, time: 80, seconds: 3)] }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get a", "patch a", "get a"])
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(80)])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
    }

    @Test func multipleGroupAcknowledgementsUseOneFinalRead() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        try await s.store.recordEdit(
            ProgressEdit(audio: edit(50).audio, isFinished: true, ebook: .init(location: "cfi", progress: 0.4)),
            for: key, now: t0)
        var canonical = server(key)
        canonical.isFinished = true
        canonical.finishedAt = Int(t0.timeIntervalSince1970 * 1000)
        canonical.ebookLocation = "cfi"
        canonical.ebookProgress = 0.4
        s.service.state.withLock { $0.fetchReplies = [nil, canonical] }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get a", "patch a", "patch a", "patch a", "get a"])
        #expect(
            s.service.patches.map(\.update) == [
                SyncHarness.audio(50), .finished(true, at: t0), .ebook(location: "cfi", progress: 0.4),
            ])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
    }

    @Test func failedRetainedPatchSettlementBlocksCleanConfirmationUntilRetry() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let clean = s.h.key("b")
        try await acknowledge(s, clean)
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        try await holding(s, patch: true) {
            await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        }
        #expect(s.service.log == ["get a", "patch a"])
        #expect(await s.store.needsConfirmationFetch == [clean])
        await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get a", "patch a"])
        s.service.state.withLock {
            $0.serverProgress[key] = server(key)
            $0.serverProgress[clean] = server(clean)
        }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get a", "patch a", "get a", "get b"])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(s.service.patches.count == 1)
    }

    @Test func failedSessionSettlementBlocksConfirmationWithoutRepeatingReport() async throws {
        let s = try SyncHarness()
        let response = Gate()
        defer {
            s.syncer.detach()
            response.open()
        }
        let clean = s.h.key("b")
        try await acknowledge(s, clean)
        s.service.state.withLock { $0.syncGates = [response] }
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
        #expect(await s.store.needsConfirmationFetch == [clean])
        s.service.state.withLock {
            $0.fetchReplies = [nil, server(s.h.key("a"), time: 15), server(clean)]
        }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["sync 1", "sync 1 done", "get a", "patch a", "get a", "get b"])
        #expect(s.service.reports.count == 1 && s.service.patches.count == 1)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
    }

    @Test(arguments: ["GET", "lookup", "save"])
    func thrownConfirmationStopsOtherKeysAndLaterDrainRetries(kind: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let other = s.h.key("b")
        try await acknowledge(s, key)
        try await acknowledge(s, other)
        s.service.state.withLock {
            $0.serverProgress = [key: server(key), other: server(other)]
            if kind == "GET" { $0.fetchErrors = [.timedOut] }
        }
        try await holding(s) {
            if kind == "lookup" { await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown)) }
            if kind == "save" { await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }
        }
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(await s.store.needsConfirmationFetch == [key, other])
        #expect(try await s.store.progress(for: key)?.currentTime == 50)
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key, key, other])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(s.service.patches.isEmpty)
    }

    @Test(arguments: [false, true])
    func editOrNewAckDuringConfirmationDefersWithoutSpinningAndLaterConfirms(newAck: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let other = s.h.key("b")
        let first = try await acknowledge(s, key)
        try await acknowledge(s, other)
        s.service.state.withLock { $0.serverProgress = [key: server(key), other: server(other)] }
        var latest = first.token
        try await holding(s) {
            try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(2))
            if newAck {
                let patch = try #require(try await s.store.beginSend(for: key))
                try await s.store.completeSend(patch, serverLastUpdate: nil)
                latest = patch.token
            }
        }
        #expect(s.service.state.withLock { $0.fetches } == [key, other])
        #expect(await s.store.needsConfirmationFetch == [key])
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == latest)
        #expect(try await s.store.progress(for: key)?.currentTime == 80)
        s.service.state.withLock {
            $0.fetchReplies =
                newAck ? [server(key, time: 80, seconds: 3)] : [server(key), server(key, time: 80, seconds: 3)]
        }
        await s.syncer.drainPendingProgress()
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(s.service.patches.map(\.update) == (newAck ? [] : [SyncHarness.audio(80)]))
        #expect(try await s.store.progress(for: key)?.currentTime == 80)
    }

    @Test(arguments: ["detach", "quiesce", "accountSwitch"])
    func retiredScopeDoesNotApplyHeldConfirmationOrIssueMoreGets(ending: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let other = s.h.key("b")
        try await acknowledge(s, key)
        try await acknowledge(s, other)
        s.service.state.withLock { $0.serverProgress = [key: server(key, time: 90), other: server(other)] }
        try await holding(s) {
            switch ending {
            case "detach": s.syncer.detach()
            case "accountSwitch": s.coordinator.stop(reason: .accountSwitch)
            default: s.syncer.quiesceTransport()
            }
        }
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(s.service.state.withLock { $0.canceledCalls } == ["get"])
        #expect(await s.store.needsConfirmationFetch == [key, other])
        #expect(try await s.store.progress(for: key)?.currentTime == 50)
        #expect(s.service.patches.isEmpty)
        await s.coordinator.waitForPendingCloses()
    }

    @Test func confirmationIsConnectionScoped() async throws {
        let s = try SyncHarness()
        let other = try SyncHarness(progressStore: s.store)
        defer {
            s.syncer.detach()
            other.syncer.detach()
        }
        let key = s.h.key("a")
        let foreign = other.h.key("a")
        try await acknowledge(s, key)
        try await acknowledge(s, foreign)
        s.service.state.withLock { $0.serverProgress[key] = server(key) }
        other.service.state.withLock { $0.serverProgress[foreign] = server(foreign, time: 80) }
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(await s.store.needsConfirmationFetch == [foreign])
        #expect(try await s.store.progress(for: foreign)?.currentTime == 50)
        await other.syncer.drainPendingProgress()
        #expect(other.service.state.withLock { $0.fetches } == [foreign])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(s.service.patches.isEmpty && other.service.patches.isEmpty)
    }

    @Test(arguments: [0.0, 1.0, 2.0])
    func staleSocketIsHeldAndQualifyingFetchReleasesOnlyStrictlyNewerHeldValue(socketSeconds: Double) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        try await acknowledge(s, key)
        s.service.state.withLock { $0.serverProgress[key] = server(key) }
        try await holding(s) {
            let capture = await s.store.captureGeneration()
            let merged = try await s.store.applyServerProgress(
                [key: baseline(10, seconds: socketSeconds)], capturedAt: capture, source: .socket)
            #expect(merged.isEmpty)
            #expect(try await s.store.progress(for: key)?.currentTime == 50)
            #expect(await s.store.needsConfirmationFetch == [key])
        }
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(try await s.store.progress(for: key)?.currentTime == (socketSeconds > 1 ? 10 : 50))
        let capture = await s.store.captureGeneration()
        try await s.store.applyServerProgress(
            [key: baseline(90, seconds: 3)], capturedAt: capture, source: .socket)
        #expect(try await s.store.progress(for: key)?.currentTime == 90)
        #expect(s.service.patches.isEmpty)
    }

    @Test(arguments: [false, true])
    func ownedPositionWriteFinishesBeforeConfirmationIntake(saveFails: Bool) async throws {
        let s = try SyncHarness()
        let persistence = Gate()
        let saving = Gate()
        defer {
            s.syncer.detach()
            persistence.open()
        }
        await s.coordinator.play(itemID: "a")
        let key = s.h.key("a")
        try await acknowledge(s, key)
        s.service.state.withLock { $0.serverProgress[key] = server(key) }
        try await holding(s) {
            s.syncer.beforePositionPersistence = {
                saving.open()
                await persistence.wait()
            }
            s.h.clock.advance(by: 2)
            s.h.engine.currentTime = 80
            s.coordinator.stop()
            await saving.wait()
            if saveFails { await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }
            persistence.open()
            await s.syncer.waitForPendingWrites()
        }
        #expect(await s.store.needsConfirmationFetch == [key])
        #expect(try await s.store.progress(for: key)?.currentTime == (saveFails ? 50 : 80))
        #expect(s.service.patches.isEmpty)
        s.syncer.beforePositionPersistence = nil
        s.service.state.withLock { $0.fetchReplies = [server(key), server(key, time: 80, seconds: 3)] }
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(80)])
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(try await s.store.progress(for: key)?.currentTime == 80)
        await s.coordinator.waitForPendingCloses()
    }

    @Test(arguments: ["lookup", "save", "failure", "deleted", "recreated", "timed"])
    func onlyGenuineCommittedAckReplacesIdentity(outcome: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let first = try await acknowledge(s, key)
        let capture = await s.store.captureProgressFetch(for: key)
        try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(2))
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == first.token)
        let patch = try #require(try await s.store.beginSend(for: key))
        if outcome == "deleted" || outcome == "recreated" {
            try await s.store.deleteProgress(for: key)
            if outcome == "recreated" {
                try await s.store.recordEdit(edit(90), for: key, now: t0.addingTimeInterval(3))
            }
        }
        if outcome == "lookup" || outcome == "save" {
            if outcome == "lookup" {
                await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
            } else {
                await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
            }
            await #expect(throws: CocoaError.self) {
                try await s.store.completeSend(patch, serverLastUpdate: nil)
            }
            #expect(await s.store.captureProgressFetch(for: key).acknowledgement == first.token)
            #expect(try await s.store.progress(for: key)?.audioDirty == true)
        }
        if outcome == "failure" {
            #expect(try await s.store.failSend(patch, error: "rejected"))
        } else {
            let handled = try await s.store.completeSend(
                patch, serverLastUpdate: outcome == "timed" ? t0.addingTimeInterval(3) : nil)
            #expect(handled == (outcome != "save"))
        }
        let expected = outcome == "lookup" ? patch.token : first.token
        let snapshot = await s.store.captureProgressFetch(for: key)
        #expect(snapshot.generation > capture.generation)
        #expect(snapshot.acknowledgement == (["deleted", "recreated"].contains(outcome) ? nil : expected))
        #expect(try await s.store.completeSend(patch, serverLastUpdate: nil) == false)
        #expect(try await s.store.completeSend(first, serverLastUpdate: nil) == false)
        #expect(try await s.store.failSend(patch, error: "duplicate") == false)
        let duplicate = await s.store.captureProgressFetch(for: key)
        #expect(duplicate.generation == snapshot.generation && duplicate.acknowledgement == snapshot.acknowledgement)
        if outcome == "recreated" {
            #expect(try await s.store.progress(for: key)?.currentTime == 90)
            #expect(try await s.store.progress(for: key)?.audioDirty == true)
        }
    }

    @Test(arguments: ["fetch", "delete", "prune"])
    func confirmationCleanupIsTransactional(operation: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        let patch = try await acknowledge(s, key)
        let capture = await s.store.captureProgressFetch(for: key)
        func cleanup() async throws {
            switch operation {
            case "delete": _ = try await s.store.deleteProgress(for: key)
            case "prune": _ = try await s.store.pruneSynced()
            default:
                try await s.store.applyServerProgress(
                    [key: baseline(50, seconds: 1)], capturedAt: capture.generation, source: .fetch)
            }
        }
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await cleanup() }
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == patch.token)
        #expect(await s.store.needsConfirmationFetch == [key])
        try await cleanup()
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == nil)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
    }

    @Test(arguments: [false, true])
    func obsoleteSettlementRetryShieldsReplacementWithoutAcknowledgingIt(lookupFails: Bool) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        try await s.store.recordEdit(edit(50), for: key, now: t0)
        let patch = try #require(try await s.store.beginSend(for: key))
        try await s.store.deleteProgress(for: key)
        try await s.store.recordEdit(edit(80), for: key, now: t0.addingTimeInterval(2))
        let capture = await s.store.captureProgressFetch(for: key)
        if lookupFails {
            await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        } else {
            await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        await #expect(throws: CocoaError.self) {
            try await s.store.completeSend(patch, serverLastUpdate: nil)
        }
        #expect(await s.store.captureProgressFetch(for: key).generation == capture.generation)
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == nil)
        #expect(try await s.store.completeSend(patch, serverLastUpdate: nil))
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == nil)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        let fresh = await s.store.captureGeneration()
        try await s.store.applyServerProgress(
            [key: baseline(50, seconds: 3)], capturedAt: fresh, source: .fetch)
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.currentTime == 80 && row.audioDirty)
    }
}
