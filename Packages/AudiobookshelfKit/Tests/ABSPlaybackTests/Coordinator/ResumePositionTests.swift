import Foundation
import Testing

@testable import ABSPlayback

struct ResumePositionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func newestCandidateWinsAndIsRewound() {
        let candidates = [
            ProgressCandidate(currentTime: 100, updatedAt: now.addingTimeInterval(-60)),
            ProgressCandidate(currentTime: 900, updatedAt: now.addingTimeInterval(-7200)),
            ProgressCandidate(currentTime: 500, updatedAt: nil),
        ]
        let time = ResumePosition.startTime(
            explicit: nil, candidates: candidates, duration: 1000, now: now, autoRewind: true)
        #expect(time == 90)
    }

    @Test func undatedCandidateIsOldestAndTiesKeepFirst() {
        let date = now.addingTimeInterval(-10)
        let candidates = [
            ProgressCandidate(currentTime: 300, updatedAt: nil),
            ProgressCandidate(currentTime: 200, updatedAt: date),
            ProgressCandidate(currentTime: 250, updatedAt: date),
        ]
        let time = ResumePosition.startTime(
            explicit: nil, candidates: candidates, duration: 1000, now: now, autoRewind: false)
        #expect(time == 200)
    }

    @Test func explicitTimeIsClampedButNotRewound() {
        let candidates = [ProgressCandidate(currentTime: 10, updatedAt: now)]
        #expect(
            ResumePosition.startTime(explicit: 50, candidates: candidates, duration: 40, now: now, autoRewind: true)
                == 40)
        #expect(ResumePosition.startTime(explicit: -5, candidates: [], duration: 40, now: now, autoRewind: true) == 0)
        #expect(ResumePosition.startTime(explicit: 30, candidates: [], duration: 0, now: now, autoRewind: true) == 30)
    }

    @Test func finishedNoCandidatesAndInvalidTimesStartAtZero() {
        let finished = [ProgressCandidate(currentTime: 999, updatedAt: now, isFinished: true)]
        #expect(
            ResumePosition.startTime(explicit: nil, candidates: finished, duration: 1000, now: now, autoRewind: true)
                == 0)
        #expect(
            ResumePosition.startTime(explicit: nil, candidates: [], duration: 1000, now: now, autoRewind: true) == 0)
        let invalid = [ProgressCandidate(currentTime: .nan, updatedAt: now)]
        #expect(
            ResumePosition.startTime(explicit: nil, candidates: invalid, duration: 1000, now: now, autoRewind: true)
                == 0)
    }

    @Test func errorMapsEngineFailuresToPlayback() {
        let failure = PlaybackFailure(kind: .decode, domain: "AVFoundationErrorDomain", code: -11829, description: "x")
        #expect(PlaybackCoordinatorError(engineError: .itemFailed(trackIndex: 1, failure)) == .playback(failure))
        #expect(PlaybackCoordinatorError(engineError: .playerFailed(failure)) == .playback(failure))
        #expect(PlaybackCoordinatorError(engineError: .emptyTimeline) == .engine(.emptyTimeline))
    }
}

@MainActor
struct UserDefaultsLastPlayedStoreTests {
    @Test func roundTripsAndClears() throws {
        let suite = "LastPlayedStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLastPlayedStore(defaults: defaults)
        #expect(store.load() == nil)

        let record = LastPlayedRecord(
            serverConnectionID: UUID(), libraryItemID: "li_1", episodeID: "ep_1", position: 12.5, duration: 99,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(record)
        #expect(UserDefaultsLastPlayedStore(defaults: defaults).load() == record)
        #expect(record.key.episodeId == "ep_1")

        store.clear()
        #expect(store.load() == nil)
        defaults.set(Data("junk".utf8), forKey: UserDefaultsLastPlayedStore.defaultKey)
        #expect(store.load() == nil)
    }
}
