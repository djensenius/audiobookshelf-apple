import ABSCore
import Foundation
import Testing

@testable import ABSData

struct PlaybackPositionCommitTests {
    private let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "a")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> LocalProgressStore {
        LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    private func audio(_ time: Double) -> ProgressEdit.Audio {
        .init(currentTime: time, duration: 3600, progress: time / 3600)
    }

    @Test(arguments: [10.0, 100.0])
    func laterCommitSupersedesHeldTokenDespiteBackwardClock(target: Double) async throws {
        let store = try store()
        let old = store.reservePlaybackPosition(for: key)
        let newer = store.reservePlaybackPosition(for: key)
        #expect(
            try await store.recordPlaybackPosition(audio(target), for: key, token: newer, now: now - 1) == .committed)
        let committed = try #require(try await store.progress(for: key))
        #expect(
            try await store.recordPlaybackPosition(audio(50), for: key, token: old, now: now)
                == .supersededByCommittedPosition)
        #expect(try await store.progress(for: key) == committed)
        #expect(committed.currentTime == target && committed.needsServerSync)
    }

    @Test func reservationAloneDoesNotSupersedeARealCommit() async throws {
        let store = try store()
        let old = store.reservePlaybackPosition(for: key)
        _ = store.reservePlaybackPosition(for: key)
        #expect(try await store.progress(for: key) == nil)
        #expect(try await store.recordPlaybackPosition(audio(50), for: key, token: old, now: now) == .committed)
        #expect(try await store.progress(for: key)?.currentTime == 50)
    }

    @Test func failedNewerWriteDoesNotAdvanceWatermarkAndMayRetry() async throws {
        let store = try store()
        let old = store.reservePlaybackPosition(for: key)
        let newer = store.reservePlaybackPosition(for: key)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) {
            try await store.recordPlaybackPosition(audio(100), for: key, token: newer, now: now - 1)
        }
        #expect(try await store.progress(for: key) == nil)
        #expect(try await store.recordPlaybackPosition(audio(50), for: key, token: old, now: now) == .committed)
        #expect(try await store.progress(for: key)?.currentTime == 50)
        #expect(try await store.recordPlaybackPosition(audio(100), for: key, token: newer, now: now - 1) == .committed)
        #expect(try await store.progress(for: key)?.currentTime == 100)
        #expect(
            try await store.recordPlaybackPosition(audio(50), for: key, token: old, now: now)
                == .supersededByCommittedPosition)
    }

    @Test func wrongWriterAndKeyAreRejectedWithoutMutatingEitherStore() async throws {
        let store = try store()
        let other = try self.store()
        let otherKey = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: "a", episodeId: "episode")
        let token = store.reservePlaybackPosition(for: key)
        await #expect(throws: PlaybackPositionCommitError.wrongWriter) {
            try await other.recordPlaybackPosition(audio(50), for: key, token: token, now: now)
        }
        await #expect(throws: PlaybackPositionCommitError.wrongKey) {
            try await store.recordPlaybackPosition(audio(50), for: otherKey, token: token, now: now)
        }
        #expect(try await store.progress(for: key) == nil)
        #expect(try await store.progress(for: otherKey) == nil)
        #expect(try await other.progress(for: key) == nil)
        #expect(try await store.recordPlaybackPosition(audio(50), for: key, token: token, now: now) == .committed)
    }

    @Test(arguments: [50.0, 100.0])
    func latestCommittedTokenCannotBeReusedWithSameOrDifferentIntent(time: Double) async throws {
        let store = try store()
        let token = store.reservePlaybackPosition(for: key)
        _ = try await store.recordPlaybackPosition(audio(50), for: key, token: token, now: now)
        let saved = try await store.progress(for: key)
        await #expect(throws: PlaybackPositionCommitError.tokenAlreadyCommitted) {
            try await store.recordPlaybackPosition(audio(time), for: key, token: token, now: now + 1)
        }
        #expect(try await store.progress(for: key) == saved)
        let newer = store.reservePlaybackPosition(for: key)
        _ = try await store.recordPlaybackPosition(audio(200), for: key, token: newer, now: now + 2)
        let latest = try await store.progress(for: key)
        #expect(
            try await store.recordPlaybackPosition(audio(time), for: key, token: token, now: now + 3)
                == .supersededByCommittedPosition)
        #expect(try await store.progress(for: key) == latest)
    }

    @Test func watermarkIsPerKeyAndGenericRecordEditRemainsUnconditional() async throws {
        let store = try store()
        let other = MediaKey(serverConnectionID: UUID(), libraryItemId: "a")
        let old = store.reservePlaybackPosition(for: key)
        let newer = store.reservePlaybackPosition(for: other)
        _ = try await store.recordPlaybackPosition(audio(100), for: other, token: newer, now: now)
        #expect(try await store.recordPlaybackPosition(audio(50), for: key, token: old, now: now) == .committed)
        // This API does not change the generic edit/time policy into a reconciler.
        let edited = try await store.recordEdit(ProgressEdit(audio: audio(10)), for: key, now: now - 1)
        #expect(edited.currentTime == 10)
        #expect(edited.audioEditedAt == Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextUp))
        #expect(try await store.progress(for: other)?.currentTime == 100)
    }

    @Test func supersededCallDoesNotConsumeCommitFailureOrWrite() async throws {
        let store = try store()
        let old = store.reservePlaybackPosition(for: key)
        let newer = store.reservePlaybackPosition(for: key)
        _ = try await store.recordPlaybackPosition(audio(100), for: key, token: newer, now: now)
        let saved = try await store.progress(for: key)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        #expect(
            try await store.recordPlaybackPosition(audio(50), for: key, token: old, now: now + 1)
                == .supersededByCommittedPosition)
        #expect(try await store.progress(for: key) == saved)
        let latest = store.reservePlaybackPosition(for: key)
        await #expect(throws: CocoaError.self) {
            try await store.recordPlaybackPosition(audio(200), for: key, token: latest, now: now + 2)
        }
        #expect(try await store.progress(for: key) == saved)
    }
}
