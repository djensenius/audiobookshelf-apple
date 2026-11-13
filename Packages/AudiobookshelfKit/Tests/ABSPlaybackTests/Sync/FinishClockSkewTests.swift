import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// #565: Mark finished (the server's PATCH, then `LocalProgressItemActionSync`'s edit) on a row
/// with an older unsent position, on a device whose clock is behind the server's or tied with it.
/// A fetch then brings the server's finish, dated no earlier than the local one. The finish stays
/// pending, so the drain sends the old position and then the finish again, and the item stays
/// finished on the server and locally. Control: a position the user played after the finish
/// still un-finishes the item, as before.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FinishClockSkewTests {
    /// How far the device clock is from the server's (the stub model's).
    enum Skew: Double, CaseIterable { case behind = -5, tied = 0 }

    @Test(arguments: Skew.allCases, [false, true])
    func aFinishOutlastsAnOlderPendingPosition(skew: Skew, playedAfterFinishing: Bool) async throws {
        let f = try CloseRetryFixture()
        let clock = f.s.h.clock
        var device: Date { clock.now.addingTimeInterval(skew.rawValue) }
        try await f.model.update(f.client, itemID: "a", episodeID: nil, SyncHarness.audio(15))
        let seed = try await serverBaseline(f)

        // Offline playback leaves a position the server hasn't seen.
        clock.advance(by: 10)
        let played = ProgressEdit.Audio(currentTime: 120, duration: 3600, progress: 120.0 / 3600)
        try await f.s.store.recordEdit(ProgressEdit(audio: played), for: f.key, serverProgress: seed, now: device)

        // Mark finished: the server takes it, then the item action records it locally.
        clock.advance(by: 10)
        let finishedAt = device
        try await f.model.update(f.client, itemID: "a", episodeID: nil, .finished(true, at: finishedAt))
        try await f.s.store.recordEdit(ProgressEdit(isFinished: true), for: f.key, now: finishedAt)
        if playedAfterFinishing {
            let later = ProgressEdit.Audio(currentTime: 130, duration: 3600, progress: 130.0 / 3600)
            try await f.s.store.recordEdit(ProgressEdit(audio: later), for: f.key, now: finishedAt + 1)
        }

        // The server's finish is dated no earlier than the local one.
        let fetched = try await f.mergeServerProgress()
        #expect(fetched.isFinished)
        #expect(try #require(fetched.lastUpdate) >= Int(finishedAt.timeIntervalSince1970 * 1000))
        let merged = try #require(try await f.s.store.progress(for: f.key))
        #expect(merged.isFinished)
        #expect(merged.audioDirty)
        #expect(merged.finishedDirty == !playedAfterFinishing)

        await f.drainWhenDue()

        let sent = f.s.service.patches.map(\.update)
        #expect(sent.first?.currentTime == (playedAfterFinishing ? 130 : 120))
        #expect(sent.map(\.isFinished) == (playedAfterFinishing ? [nil] : [nil, true]))
        let server = try #require(try await f.model.fetchProgress(f.client, itemID: "a", episodeID: nil))
        #expect(server.isFinished == !playedAfterFinishing)
        #expect(server.currentTime == (playedAfterFinishing ? 130 : 120))

        try await f.mergeServerProgress()
        let row = try #require(try await f.s.store.progress(for: f.key))
        #expect(row.isFinished == !playedAfterFinishing)
        #expect(!row.audioDirty && !row.finishedDirty)
    }

    /// The stub server's progress for "a", as a fetch gives it to the store.
    private func serverBaseline(_ f: CloseRetryFixture) async throws -> ProgressBaseline {
        let progress = try #require(try await f.model.fetchProgress(f.client, itemID: "a", episodeID: nil))
        return ProgressBaseline(
            currentTime: progress.currentTime, progress: progress.progress, duration: progress.duration,
            isFinished: progress.isFinished,
            finishedAt: progress.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(try #require(progress.lastUpdate)) / 1000))
    }
}
