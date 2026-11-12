import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// #382's 404 reconciliation (ADR 0007): a `/close` the server answered 404 is settled by its
/// session's stored record (`GET /api/me/item/listening-sessions/:itemId`). Applied, it's
/// dropped; never applied, its listening time is carried into the media's next session;
/// undecidable, it's dropped and logged. In ``CloseRetryFixture`` the server acknowledged 15 s
/// of session 1 and its close carries the last 5 s.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloseReconciliationTests {
    /// The first page of a media's stored sessions: `records` (ID, listening time) out of `total`.
    private static func page(_ records: [(String, Double)], total: Int) throws -> ListeningSessionsPage {
        let sessions = records.map { ["id": $0.0, "timeListening": $0.1, "currentTime": 0] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: [
            "sessions": sessions, "total": total, "page": 0, "itemsPerPage": 10,
        ])
        return try JSONDecoder().decode(ListeningSessionsPage.self, from: data)
    }

    /// Stored record (`nil`: not on the page), the close's acknowledged time, the time of a
    /// `/sync` still out at the close, stored sessions beyond the page, and the verdict.
    nonisolated static let records: [(Double?, Double, Double, Int, CloseReconciliation)] = [
        (20, 15, 0, 0, .applied),
        (19.6, 15, 0, 0, .applied),
        // Another report's time the client never learned of: still counted.
        (25, 15, 0, 0, .applied),
        (15, 15, 0, 0, .notApplied),
        (15.4, 15, 0, 0, .notApplied),
        (19.4, 15, 0, 0, .undecidable),
        (17, 15, 0, 0, .undecidable),
        (14.4, 15, 0, 0, .undecidable),
        // A `/sync` of 15 s was still out: the record counts the close only above both.
        (35, 15, 15, 0, .applied),
        (30, 15, 15, 0, .notApplied),
        (15, 15, 15, 0, .notApplied),
        (25, 15, 15, 0, .undecidable),
        (20, 15, 15, 0, .undecidable),
        // The `/sync` of 5 s or the close: either could have made 20.
        (20, 15, 5, 0, .undecidable),
        // No record: the server stores none before a session has listening time.
        (nil, 0, 0, 0, .notApplied),
        (nil, 0, 15, 0, .notApplied),
        (nil, 0, 0, 1, .undecidable),
        (nil, 15, 0, 0, .undecidable),
    ]

    /// Within the 0.5 s tolerance, a record with the close's 5 s above what was acknowledged and
    /// what was still out applied it, and one at what was acknowledged, with or without what was
    /// still out, didn't; anything else can't tell. A missing record says "not applied" only when
    /// nothing was acknowledged and every stored session of the media is on the page.
    @Test(arguments: records)
    func theStoredRecordDecides(
        record: Double?, ackedTotal: Double, inFlightTotal: Double, unlisted: Int, verdict: CloseReconciliation
    ) throws {
        let close = PendingSessionCloseDTO(
            key: MediaKey(serverConnectionID: UUID(), libraryItemId: "a"), sessionID: "session-1",
            currentTime: 20, timeListened: 5, duration: 3600, positionEditedAt: nil, capturedAt: .now,
            ackedTotal: ackedTotal, inFlightTotal: inFlightTotal)
        let listed = [("session-2", 30.0)] + (record.map { [("session-1", $0)] } ?? [])
        let page = try Self.page(listed, total: listed.count + unlisted)

        #expect(ProgressSyncer.reconcileClose(close, page: page) == verdict)
    }

    /// A resend the server answered 404 is settled by the stored record, once: applied with its
    /// response lost, the record counts the close, so it's dropped; never applied before a server
    /// restart, the record stands at 15 s, so the media's next session reports the 5 s; the item
    /// gone (the lookup's own 404), nothing tells, so it's dropped. Every second counts once.
    @Test(arguments: ["applied", "not applied", "item gone"])
    func aResendAnswered404IsSettledByTheStoredRecord(record: String) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(record == "applied" ? .appliedResponseLost : .unapplied)
        if record != "applied" { await f.model.restart() }
        if record == "item gone" { f.s.service.state.withLock { $0.recordsErrors = [APIError.notFound] } }

        await f.drainWhenDue()

        #expect(f.verdicts == [.send])
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(f.s.service.log.filter { $0 == "records a" }.count == 1)
        #expect(try await f.queued().isEmpty)
        #expect(try await f.listened("session-1") == (record == "applied" ? 20 : 15))
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == (record == "not applied" ? [5] : []))

        await f.s.coordinator.play(itemID: "a")
        #expect(f.s.syncer.closeQueue.carried.isEmpty)
        await f.s.play(for: 20)
        f.s.coordinator.stop()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.settle()
        await f.s.syncer.closeQueue.waitForCaptures()

        #expect(try await f.listened("session-2") == (record == "not applied" ? 25 : 20))
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(try await f.queued().isEmpty)
    }

    /// A lookup that fails keeps the close, and later drains look again once due, backing off
    /// as resends do, without resending: the 404 already said the session is gone. Once a lookup
    /// answers, the record decides; after `maxCloseLookups` failures the close is dropped.
    /// Offline or cancelled nothing is learned or counted: the close stays as it was, so the next
    /// drain resends it and meets the 404 again.
    @Test(arguments: ["recovers", "keeps failing", "offline", "cancelled"])
    func aFailedLookupIsRetriedWithoutAResend(lookup: String) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        await f.model.restart()
        let limit = ProgressSyncer.maxCloseLookups
        let learnsNothing = lookup == "offline" || lookup == "cancelled"
        let errors: [any Error] =
            switch lookup {
            case "recovers": [APIError.http(status: 503, message: nil), APIError.http(status: 500, message: nil)]
            case "keeps failing": Array(repeating: APIError.http(status: 500, message: nil), count: limit)
            case "cancelled": [CancellationError()]
            default: [APIError.network(.notConnectedToInternet)]
            }
        f.s.service.state.withLock { $0.recordsErrors = errors }

        await f.drainWhenDue()

        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        let kept = try #require(try await f.queued().first)
        #expect(kept.failedLookups == (learnsNothing ? 0 : 1))
        #expect(kept.attempts == (learnsNothing ? 1 : 2))
        #expect(kept.lastAttemptAt == f.s.h.clock.now)
        #expect(f.s.syncer.drainWake != nil)

        let lookups = lookup == "keeps failing" ? limit : lookup == "recovers" ? 3 : 2
        for _ in 1..<lookups {
            let close = try #require(try await f.queued().first)
            f.s.h.clock.advance(by: f.s.syncer.closeRetryDelay(afterAttempts: close.attempts) - 1)
            await f.s.syncer.drainPendingProgress()
            // Not due yet: nothing goes out.
            #expect(try await f.queued().first == close)
            f.s.h.clock.advance(by: 1)
            await f.s.syncer.drainPendingProgress()
        }

        #expect(f.s.service.log.filter { $0 == "records a" }.count == lookups)
        #expect(f.s.service.closes.map(\.id) == (learnsNothing ? ["session-1", "session-1"] : ["session-1"]))
        #expect(f.verdicts == (learnsNothing ? [.send, .send] : [.send]))
        #expect(try await f.queued().isEmpty)
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == (lookup == "keeps failing" ? [] : [5]))
        #expect(try await f.listened("session-1") == 15)
    }

    /// A lookup that fails once the syncer stopped saves nothing: a replacement scope's drain
    /// may have settled the close, and carried its time, meanwhile.
    @Test(arguments: ["detach", "quiesce"])
    func aLookupFailingAfterTheSyncerStopsSavesNothing(stop: String) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        await f.model.restart()
        let lookup = CloseRetryFixture.Request(.unapplied)
        defer { lookup.release() }
        await f.model.enqueue(lookup, for: .records)
        f.s.h.clock.advance(by: f.s.syncer.reconcileDelay)
        let drain = Task { await f.s.syncer.drainPendingProgress() }
        await lookup.arrived.wait()

        if stop == "detach" { f.s.syncer.detach() } else { f.s.syncer.quiesceTransport() }
        // The replacement scope settles the close.
        try await f.s.store.deleteSessionClose(serverConnectionID: f.s.h.connectionID, sessionID: "session-1")
        lookup.release()
        await drain.value

        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(f.s.service.log.filter { $0 == "records a" }.count == 1)
        #expect(try await f.queued().isEmpty)
        #expect(f.s.syncer.closeQueue.carried.isEmpty)
        #expect(f.s.syncer.drainWake == nil)
    }

    /// A `/sync` still out at the close may apply after it: its 15 s were applied, the close's
    /// 5 s weren't, so the record stands at 30 and the 5 s are carried. When an earlier report's
    /// outcome is unknown too, the record can't tell the `/sync` from that report and the close:
    /// here the lost 10 s and the applied close make the 15 s of a `/sync` that never applied,
    /// so only "applied" holds, and nothing is counted twice.
    @Test(arguments: [false, true])
    func aSyncStillOutAtTheCloseIsAllowedFor(earlierUnknown: Bool) async throws {
        let f = try CloseRetryFixture()
        let late = CloseRetryFixture.Request(earlierUnknown ? .unapplied : .acknowledged)
        defer { late.release() }
        await f.s.coordinator.play(itemID: "a")
        if earlierUnknown {
            let lost = CloseRetryFixture.Request(.appliedResponseLost)
            lost.release()
            await f.model.enqueue(lost, for: .sync)
            await f.s.play(for: 10)
            await f.s.syncer.flush()
        } else {
            await f.s.play(for: 15)
        }
        await f.model.enqueue(late, for: .sync)
        await f.s.play(for: 15, settling: false)
        await late.arrived.wait()
        // The server takes the `/sync` before the close; the client hears of it only after.
        late.enter.open()
        late.apply.open()
        await late.applicationFinished.wait()
        await f.s.play(for: 5, settling: false)
        let close = CloseRetryFixture.Request(earlierUnknown ? .appliedResponseLost : .unapplied)
        close.release()
        await f.model.enqueue(close, for: .close)
        f.s.coordinator.stop()
        late.respond.open()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.settle()
        await f.s.syncer.closeQueue.waitForCaptures()

        let kept = try #require(try await f.queued().first)
        #expect(kept.timeListened == 5)
        #expect(kept.ackedTotal == (earlierUnknown ? 0 : 15))
        #expect(kept.inFlightTotal == (earlierUnknown ? 0 : 15))
        #expect(try await f.listened("session-1") == (earlierUnknown ? 15 : 30))

        await f.model.restart()
        await f.drainWhenDue()

        #expect(f.verdicts == [.send])
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(f.s.service.log.filter { $0 == "records a" }.count == 1)
        #expect(try await f.queued().isEmpty)
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == (earlierUnknown ? [] : [5]))
    }

    /// A snapshot dropped after its lookup failed leaves its outcome unknown for good: here the
    /// lost 10 s were applied, so the stored 30 s also match 15 acked plus an unapplied 15 s
    /// `/sync` still out at the close. The `/sync` isn't allowed for, so only "applied" holds and
    /// the close's 5 s aren't carried a second time.
    @Test func aSyncStillOutIsNotAllowedForAfterAFailedLookup() async throws {
        let f = try CloseRetryFixture()
        let late = CloseRetryFixture.Request(.unapplied)
        defer { late.release() }
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 15)
        let lost = CloseRetryFixture.Request(.appliedResponseLost)
        lost.release()
        await f.model.enqueue(lost, for: .sync)
        await f.s.play(for: 10)
        await f.s.syncer.flush()
        f.s.h.clock.advance(by: f.s.syncer.reconcileDelay)
        let lookup = CloseRetryFixture.Request(.unapplied)
        lookup.release()
        await f.model.enqueue(lookup, for: .lookup)
        await f.s.syncer.flush()
        #expect(f.s.service.log.filter { $0.hasPrefix("lookup") }.count == 1)
        await f.model.enqueue(late, for: .sync)
        await f.s.play(for: 15, settling: false)
        await late.arrived.wait()
        late.enter.open()
        late.apply.open()
        await late.applicationFinished.wait()
        await f.s.play(for: 5, settling: false)
        let close = CloseRetryFixture.Request(.appliedResponseLost)
        close.release()
        await f.model.enqueue(close, for: .close)
        f.s.coordinator.stop()
        late.respond.open()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.settle()
        await f.s.syncer.closeQueue.waitForCaptures()

        let kept = try #require(try await f.queued().first)
        #expect(kept.timeListened == 5)
        #expect(kept.ackedTotal == 15)
        #expect(kept.inFlightTotal == 0)
        #expect(try await f.listened("session-1") == 30)

        await f.model.restart()
        await f.drainWhenDue()

        #expect(f.verdicts == [.send])
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(try await f.queued().isEmpty)
        #expect(f.s.syncer.closeQueue.carried.isEmpty)
    }

    /// A close whose resend admission keeps holding back (here, every read of the server's
    /// progress fails) stays until its session must have ended, `closeSessionLifetime` after its
    /// capture. Then the drain settles it by the stored record, resending nothing.
    @Test func aCloseOutlivingItsSessionIsSettledWithoutAResend() async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        let captured = try #require(try await f.queued().first?.capturedAt)
        f.s.syncer.closeQueue.reached = { step in
            // Admission's progress read is the pass's first request.
            guard step == .passStarted else { return }
            f.s.service.state.withLock { $0.fetchErrors = [.http(status: 500, message: nil)] }
        }

        await f.drainWhenDue()
        let beforeLifetime = captured.addingTimeInterval(ProgressSyncer.closeSessionLifetime - 1)
        f.s.h.clock.advance(by: beforeLifetime.timeIntervalSince(f.s.h.clock.now))
        await f.s.syncer.drainPendingProgress()

        #expect(f.verdicts == [.skip(.lookupFailed), .skip(.lookupFailed)])
        #expect(try await f.queued().count == 1)
        #expect(!f.s.service.log.contains("records a"))

        f.s.h.clock.advance(by: 1)
        await f.s.syncer.drainPendingProgress()

        #expect(f.verdicts.count == 2)
        #expect(f.s.service.log.filter { $0 == "records a" }.count == 1)
        #expect(f.s.service.closes.isEmpty)
        #expect(try await f.queued().isEmpty)
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == [5])
        #expect(try await f.listened("session-1") == 15)
    }

    /// Carried time waits for its media's next loaded session: another item's session doesn't
    /// take it.
    @Test func carriedTimeWaitsForItsMediasNextSession() async throws {
        let f = try CloseRetryFixture()
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 20)
        // The server forgets the session: the coordinator's close meets a 404, so nothing applied.
        await f.model.restart()
        f.s.coordinator.stop()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.settle()
        await f.s.syncer.closeQueue.waitForCaptures()
        #expect(f.s.syncer.closeQueue.carried.map(\.key) == [f.key])
        #expect(try await f.queued().isEmpty)

        for item in ["b", "a"] {
            await f.s.coordinator.play(itemID: item)
            #expect(f.s.syncer.closeQueue.carried.isEmpty == (item == "a"))
            await f.s.play(for: 10)
            f.s.coordinator.stop()
            await f.s.coordinator.waitForPendingCloses()
            await f.s.settle()
            await f.s.syncer.closeQueue.waitForCaptures()
        }

        #expect(try await f.listened("session-1") == 15)
        #expect(try await f.listened("session-2", itemID: "b") == 10)
        #expect(try await f.listened("session-3") == 15)
        #expect(f.s.service.closes.isEmpty)
        #expect(!f.s.service.log.contains("records a"))
    }

    /// Carried time merges per media, at most `unsavedLimit` media are held, the oldest dropped
    /// first, and detaching drops it all, as no session of this syncer follows.
    @Test func carriedTimeIsBoundedAndDroppedOnDetach() throws {
        let f = try CloseRetryFixture()
        let queue = f.s.syncer.closeQueue
        let limit = CloseRetryQueue.unsavedLimit
        for index in 0...limit {
            queue.carry(5, for: f.s.h.key("item-\(index)"))
        }
        queue.carry(2, for: f.s.h.key("item-\(limit)"))

        #expect(queue.carried.map(\.key) == (1...limit).map { f.s.h.key("item-\($0)") })
        #expect(queue.carried.map(\.seconds) == Array(repeating: 5, count: limit - 1) + [7])

        f.s.syncer.detach()

        #expect(queue.carried.isEmpty)
    }
}
