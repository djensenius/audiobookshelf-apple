import ABSCore
import Foundation
import Testing

@testable import ABSData

/// The persisted close queue and the position checks its admission rule reads (#382).
struct SessionCloseQueueTests {
    private let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "a")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func audio(_ time: Double) -> ProgressEdit.Audio {
        .init(currentTime: time, duration: 3600, progress: time / 3600)
    }

    private func close(_ sessionID: String, at date: Date, key: MediaKey? = nil) -> PendingSessionCloseDTO {
        PendingSessionCloseDTO(
            key: key ?? self.key, sessionID: sessionID, currentTime: 20, timeListened: 5, duration: 3600,
            positionEditedAt: t0, capturedAt: date)
    }

    private func commit(_ time: Double, to store: LocalProgressStore, at date: Date) async throws
        -> PlaybackPositionToken
    {
        let token = store.reservePlaybackPosition(for: key)
        _ = try await store.recordPlaybackPosition(audio(time), for: key, token: token, now: date)
        return token
    }

    /// A close survives a relaunch, oldest capture first and per connection, with what a 404's
    /// lookup reads (`ackedTotal`, `inFlightTotal`, `failedLookups`); saving again replaces it,
    /// and deleting a missing one isn't an error.
    @Test func closesPersistPerConnectionInCaptureOrder() async throws {
        let container = try DataStack(location: .inMemory).container
        let store = LocalProgressStore(modelContainer: container)
        let other = MediaKey(serverConnectionID: UUID(), libraryItemId: "a")
        var first = close("s-1", at: t0)
        first.ackedTotal = 15
        first.inFlightTotal = 15
        try await store.saveSessionClose(close("s-2", at: t0 + 1))
        try await store.saveSessionClose(first)
        try await store.saveSessionClose(close("s-1", at: t0, key: other))
        var retried = close("s-2", at: t0 + 1)
        retried.attempts = 2
        retried.lastAttemptAt = t0 + 5
        retried.ackedTotal = 12.5
        retried.inFlightTotal = 7.5
        retried.failedLookups = 1
        try await store.saveSessionClose(retried)

        let relaunched = LocalProgressStore(modelContainer: container)
        let closes = try await relaunched.sessionCloses(for: key.serverConnectionID)
        #expect(closes == [first, retried])
        #expect(closes.map(\.ackedTotal) == [15, 12.5] && closes.map(\.failedLookups) == [0, 1])
        #expect(closes.map(\.inFlightTotal) == [15, 7.5])
        #expect(try await relaunched.sessionCloses(for: other.serverConnectionID).map(\.key) == [other])

        try await relaunched.deleteSessionClose(serverConnectionID: key.serverConnectionID, sessionID: "s-1")
        try await relaunched.deleteSessionClose(serverConnectionID: key.serverConnectionID, sessionID: "s-1")
        #expect(try await relaunched.sessionCloses(for: key.serverConnectionID) == [retried])
        #expect(try await relaunched.sessionCloses(for: other.serverConnectionID).count == 1)
    }

    /// An attempt is claimed only from the close as read: one removed since isn't recreated, and
    /// one saved again since (kept to retry, or after a failed lookup) keeps what that save wrote.
    @Test(arguments: [nil, "removed", "kept", "lookup failed"])
    func anAttemptIsClaimedOnlyFromTheCloseAsRead(change: String?) async throws {
        let store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        var read = close("s-1", at: t0)
        read.lastAttemptAt = t0
        try await store.saveSessionClose(read)
        var kept = read
        kept.attempts = 1
        kept.lastAttemptAt = t0 + 30
        if change == "lookup failed" {
            kept = read
            kept.failedLookups = 1
        }
        switch change {
        case "removed": try await store.deleteSessionClose(serverConnectionID: key.serverConnectionID, sessionID: "s-1")
        case "kept", "lookup failed": try await store.saveSessionClose(kept)
        default: break
        }

        #expect(try await store.claimSessionCloseAttempt(read, at: t0 + 60) == (change == nil))

        var attempted = read
        attempted.lastAttemptAt = t0 + 60
        let closes = try await store.sessionCloses(for: key.serverConnectionID)
        #expect(closes == (change == "removed" ? [] : [change == nil ? attempted : kept]))
    }

    /// The edit time is the token's only while that token is the latest committed position.
    @Test func committedEditBelongsOnlyToTheLatestToken() async throws {
        let store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        let first = try await commit(20, to: store, at: t0)
        #expect(await store.committedPlaybackEdit(first, for: key) == t0)
        let unsaved = store.reservePlaybackPosition(for: key)
        #expect(await store.committedPlaybackEdit(unsaved, for: key) == nil)
        let other = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: "b")
        #expect(await store.committedPlaybackEdit(first, for: other) == nil)

        let second = try await commit(30, to: store, at: t0 + 1)
        #expect(await store.committedPlaybackEdit(first, for: key) == nil)
        #expect(await store.committedPlaybackEdit(second, for: key) == t0 + 1)
    }

    /// The position stays the report's own until a later edit or a newer server value replaces it;
    /// an older server value merges without replacing it.
    @Test(arguments: [nil, "older server", "newer server", "local edit"])
    func latestPositionMatchesOnlyTheUntouchedCommit(change: String?) async throws {
        let store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        #expect(try await !store.isLatestPlaybackPosition(currentTime: 20, editedAt: t0, for: key))
        _ = try await commit(20, to: store, at: t0)
        switch change {
        case "older server", "newer server":
            let generation = await store.captureGeneration()
            let server = ProgressBaseline(
                currentTime: 900, progress: 0.25, duration: 3600, isFinished: false, ebookProgress: 0,
                lastUpdate: change == "newer server" ? t0 + 2 : t0 - 2)
            _ = try await store.applyServerProgress([key: server], capturedAt: generation, source: .fetch)
        case "local edit":
            _ = try await commit(20, to: store, at: t0 + 1)
        default:
            break
        }
        let isLatest = try await store.isLatestPlaybackPosition(currentTime: 20, editedAt: t0, for: key)
        #expect(isLatest == (change == nil || change == "older server"))
        #expect(try await !store.isLatestPlaybackPosition(currentTime: 21, editedAt: t0, for: key))
    }

    /// The row's change stamp, read without awaiting the store, moves with a generic edit
    /// (marking not finished), a merged server value and a deletion, and never back; another
    /// row's edit and a saved close leave it.
    @Test(arguments: [nil, "edit", "merge", "delete", "other row", "close"])
    func rowChangeStampMovesOnlyWithItsRow(change: String?) async throws {
        let store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        #expect(store.rowChangeStamp(for: key) == 0)
        _ = try await commit(20, to: store, at: t0)
        let stamp = store.rowChangeStamp(for: key)
        #expect(stamp > 0)
        switch change {
        case "edit":
            try await store.recordEdit(ProgressEdit(audio: audio(0), isFinished: false), for: key, now: t0 + 1)
        case "merge":
            let generation = await store.captureGeneration()
            let server = ProgressBaseline(
                currentTime: 900, progress: 0.25, duration: 3600, isFinished: false, ebookProgress: 0,
                lastUpdate: t0 + 2)
            #expect(try await store.applyServerProgress([key: server], capturedAt: generation, source: .fetch) == [key])
        case "delete":
            #expect(try await store.deleteProgress(for: key))
        case "other row":
            let other = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: "b")
            try await store.recordEdit(ProgressEdit(audio: audio(5)), for: other, now: t0 + 1)
        case "close":
            try await store.saveSessionClose(close("s-1", at: t0))
        default:
            break
        }
        let moved = store.rowChangeStamp(for: key)
        #expect((moved > stamp) == ["edit", "merge", "delete"].contains(change))
        #expect(moved >= stamp)
    }
}
