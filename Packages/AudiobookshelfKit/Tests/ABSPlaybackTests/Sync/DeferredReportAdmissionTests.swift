import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// One test per verdict of #195's admission rule for a deferred report (#382), each with the
/// control that sends. The report is session 1's close, kept at 20 s after the server didn't
/// apply it; the server holds 15 s from session 1's last `/sync`, which is older.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeferredReportAdmissionTests {
    private static func retained() async throws -> (CloseRetryFixture, PendingSessionCloseDTO) {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        return (f, try #require(try await f.queued().first))
    }

    private static func admit(_ f: CloseRetryFixture, _ close: PendingSessionCloseDTO, editedAt: Date?)
        async -> DeferredReportAdmission
    {
        await f.s.syncer.admitDeferredReport(
            sessionID: close.sessionID, key: close.key, currentTime: close.currentTime, editedAt: editedAt)
    }

    private static func admit(_ f: CloseRetryFixture, _ close: PendingSessionCloseDTO) async
        -> DeferredReportAdmission
    {
        await admit(f, close, editedAt: close.positionEditedAt)
    }

    /// Requests made since `mark` log entries.
    private static func requests(_ f: CloseRetryFixture, since mark: Int) -> [String] {
        Array(f.s.service.log[mark...])
    }

    /// A detached or quiesced syncer skips before any request.
    @Test(arguments: [nil, "quiesce", "detach"])
    func anEndedAccountSkips(end: String?) async throws {
        let (f, close) = try await Self.retained()
        if end == "quiesce" { f.s.syncer.quiesceTransport() }
        if end == "detach" { f.s.syncer.detach() }
        let mark = f.s.service.log.count

        #expect(await Self.admit(f, close) == (end == nil ? .send : .skip(.quiesced)))
        #expect(Self.requests(f, since: mark) == (end == nil ? ["get a"] : []))
    }

    /// A newer session of the same media skips before any request; another item's doesn't.
    @Test(arguments: ["a", "b"])
    func aNewerSessionOfTheSameMediaSkips(item: String) async throws {
        let (f, close) = try await Self.retained()
        await f.s.coordinator.play(itemID: item)
        #expect(f.s.coordinator.session?.id == "session-2")
        await f.s.settle()
        let mark = f.s.service.log.count

        #expect(await Self.admit(f, close) == (item == "a" ? .skip(.newerSessionForMedia) : .send))
        #expect(Self.requests(f, since: mark) == (item == "a" ? [] : ["get a"]))
    }

    /// Offline, the lookup fails and nothing is sent: not the close, not a PATCH. The drain keeps
    /// the close for later; online, it resends it.
    @Test(arguments: [true, false])
    func aFailedLookupSkipsWithoutSending(offline: Bool) async throws {
        let (f, close) = try await Self.retained()
        // The position goes out first; the close isn't due yet.
        await f.s.syncer.drainPendingProgress()
        let patches = f.s.service.patches.count
        #expect(patches > 0)
        #expect(f.verdicts.isEmpty)
        let offlineError = APIError.network(.notConnectedToInternet)
        if offline { f.s.service.state.withLock { $0.fetchErrors = [offlineError] } }
        let mark = f.s.service.log.count

        #expect(await Self.admit(f, close) == (offline ? .skip(.lookupFailed) : .send))
        #expect(Self.requests(f, since: mark) == ["get a"])

        if offline { f.s.service.state.withLock { $0.fetchErrors = [offlineError] } }
        await f.drainWhenDue()
        #expect(f.verdicts == [offline ? .skip(.lookupFailed) : .send])
        #expect(f.s.service.closes.count == (offline ? 0 : 1))
        #expect(f.s.service.patches.count == patches)
        #expect(try await f.queued().count == (offline ? 1 : 0))
    }

    /// The stored position must still be the report's own. Older server progress at another
    /// position doesn't change that, so it sends; another device's newer progress, a later
    /// local edit (even at the same time) or a position that never committed skip.
    @Test(arguments: [nil, "tablet", "local edit", "never committed"])
    func aSupersededPositionSkips(change: String?) async throws {
        let (f, close) = try await Self.retained()
        let editedAt = try #require(close.positionEditedAt)
        let server = try #require(try await f.model.fetchProgress(f.client, itemID: "a", episodeID: nil))
        #expect(server.currentTime == 15)
        #expect(try #require(server.lastUpdate) < Int(editedAt.timeIntervalSince1970 * 1000))
        f.s.h.clock.advance(by: 10)
        switch change {
        case "tablet":
            let tablet = SessionModelClient(model: f.model, deviceID: "tablet")
            let session = try await f.model.start(tablet, itemID: "a", episodeID: nil)
            try await f.model.sync(
                tablet, id: session.id,
                report: #require(PlaybackSyncReport(currentTime: 900, timeListened: 30, duration: 3600)))
        case "local edit":
            try await f.s.store.recordEdit(
                ProgressEdit(audio: .init(currentTime: 20, duration: 3600, progress: 20.0 / 3600)), for: f.key,
                now: f.s.h.clock.now)
        default:
            break
        }

        let verdict = await Self.admit(f, close, editedAt: change == "never committed" ? nil : editedAt)

        #expect(verdict == (change == nil ? .send : .skip(.positionSuperseded)))
        #expect(try await f.s.store.progress(for: f.key)?.currentTime == (change == "tablet" ? 900 : 20))
        #expect(try await f.serverTime() == (change == "tablet" ? 900 : 15))
        #expect(f.s.service.closes.isEmpty)
    }

    /// A reply the merge doesn't take decides nothing, so it skips like a failed lookup: one
    /// without a date, another item's, or one older than the server progress already stored.
    /// The model's own reply sends.
    @Test(arguments: [nil, "undated", "other item", "older"])
    func anUnmergedReplySkips(reply: String?) async throws {
        let (f, close) = try await Self.retained()
        var server = try #require(try await f.model.fetchProgress(f.client, itemID: "a", episodeID: nil))
        switch reply {
        case "undated": server.lastUpdate = nil
        case "other item": server.libraryItemId = "b"
        case "older": server.lastUpdate = 1
        default: break
        }
        if reply != nil { f.s.service.state.withLock { $0.fetchReplies = [server] } }
        let mark = f.s.service.log.count

        #expect(await Self.admit(f, close) == (reply == nil ? .send : .skip(.lookupFailed)))
        #expect(Self.requests(f, since: mark) == ["get a"])
        #expect(try await f.s.store.progress(for: f.key)?.currentTime == 20)
        #expect(f.s.service.closes.isEmpty)
    }

    /// Admission reads the stored position last, and that read suspends: an account that ended,
    /// a newer session of the same media, a position saved meanwhile (even another item's), or
    /// the row reset (marked not finished) or deleted (progress discarded) in the store skips,
    /// though the position read said send.
    @Test(arguments: [nil, "quiesce", "newer session", "saved position", "mark not finished", "discard"])
    func aChangeDuringThePositionReadSkips(change: String?) async throws {
        let (f, close) = try await Self.retained()
        let read = Gate()
        f.s.syncer.closeQueue.reached = { step in
            guard step == .positionRead else { return }
            read.open()
            switch change {
            case "quiesce":
                f.s.syncer.quiesceTransport()
            case "newer session":
                await f.s.coordinator.play(itemID: "a")
            case "saved position":
                await f.s.coordinator.play(itemID: "b")
                await f.s.play(for: 20)
                #expect(f.s.syncer.pendingPositions.isEmpty)
            case "mark not finished", "discard":
                await f.applyItemAction(discard: change == "discard")
            default:
                break
            }
        }

        let verdict = await Self.admit(f, close)

        await read.wait()
        switch change {
        case nil: #expect(verdict == .send)
        case "quiesce": #expect(verdict == .skip(.quiesced))
        case "newer session": #expect(verdict == .skip(.newerSessionForMedia))
        default: #expect(verdict == .skip(.lookupFailed))
        }
        #expect(f.s.service.closes.isEmpty)
    }
}
