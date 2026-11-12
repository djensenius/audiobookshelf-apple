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
}
