import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Records begins and ends, also into the session service's log so they order against `/play`.
@MainActor
final class RecordingBackgroundActivity: BackgroundActivity {
    private(set) var begun: [BackgroundActivityToken] = []
    private(set) var ended: [BackgroundActivityToken] = []
    var service: StubSessionService?

    /// Begun and not yet ended.
    var active: Int { begun.count - ended.count }

    func begin(name: String) -> BackgroundActivityToken {
        let token = BackgroundActivityToken()
        begun.append(token)
        service?.state.withLock { $0.log.append("begin activity") }
        return token
    }

    func end(_ token: BackgroundActivityToken) {
        #expect(begun.contains(token) && !ended.contains(token))
        ended.append(token)
        service?.state.withLock { $0.log.append("end activity") }
    }
}

/// Listings per podcast, counting fetches, with an optional gate on the next fetch.
final class StubEpisodeSource: PodcastEpisodeSource {
    struct State {
        var listings: [String: PodcastEpisodeListing] = [:]
        var fetches = 0
        var gate: Gate?
        var error: APIError?
    }

    let state = Mutex(State())

    var fetches: Int { state.withLock { $0.fetches } }

    func listing(podcastItemID: String) async throws -> PodcastEpisodeListing {
        let gate = state.withLock {
            $0.fetches += 1
            defer { $0.gate = nil }
            return $0.gate
        }
        await gate?.wait()
        return try state.withLock { state in
            if let error = state.error { throw error }
            return state.listings[podcastItemID]
                ?? PodcastEpisodeListing(
                    isSerial: false, episodes: [], finishedEpisodeIDs: [])
        }
    }

    /// Episodes `ids` of a serial podcast, in that order.
    func set(_ podcastID: String, episodes ids: [String], finished: Set<String> = []) {
        let episodes = ids.enumerated().map { PodcastEpisode(id: $0.element, publishedAt: $0.offset) }
        state.withLock {
            $0.listings[podcastID] = PodcastEpisodeListing(
                isSerial: true, episodes: episodes, finishedEpisodeIDs: finished)
        }
    }
}

@MainActor
final class AdvanceQueueStore: PlaybackQueueStoring {
    var saved: [UUID: [QueueItem]] = [:]

    func load(serverConnectionID: UUID) -> [QueueItem] { saved[serverConnectionID] ?? [] }
    func save(_ items: [QueueItem], serverConnectionID: UUID) { saved[serverConnectionID] = items }
    func removeQueue(serverConnectionID: UUID) { saved[serverConnectionID] = nil }
}

/// A coordinator with an attached advancer, a recording background activity and a stub podcast.
@MainActor
struct AdvanceHarness {
    let activity = RecordingBackgroundActivity()
    let episodes = StubEpisodeSource()
    let h: CoordinatorHarness
    let queue: PlaybackQueue
    let advancer: PlaybackQueueAdvancer
    var coordinator: PlaybackCoordinator { h.coordinator }
    var service: StubSessionService { h.service }

    init(podcastFallback: Bool = true) throws {
        h = try CoordinatorHarness(backgroundActivity: activity)
        activity.service = h.service
        queue = PlaybackQueue(serverConnectionID: h.connectionID, store: AdvanceQueueStore())
        advancer = PlaybackQueueAdvancer(queue: queue, episodes: podcastFallback ? episodes : nil)
        advancer.attach(to: h.coordinator)
    }

    func key(_ itemID: String, episode: String? = nil) -> MediaKey {
        MediaKey(serverConnectionID: h.connectionID, libraryItemId: itemID, episodeId: episode)
    }

    func enqueue(_ itemIDs: String...) {
        for id in itemIDs { queue.addToEnd(QueueItem(libraryItemID: id, episodeID: nil, title: id)) }
    }

    /// Plays and waits for the next item to be prepared.
    func play(_ itemID: String, episode: String? = nil) async {
        await coordinator.play(itemID: itemID, episodeID: episode)
        await advancer.waitForPreparation()
    }

    struct Fetches: Equatable {
        var progress: Int
        var policy: Int
        var listings: Int
    }

    /// Plays to the end and waits for the auto-advance; returns ``fetches`` as of the next item's
    /// `.loaded`, before it prepares its own successor.
    @discardableResult
    func finish() async -> Fetches? {
        var atLoad: Fetches?
        let token = coordinator.addObserver { [self] event in
            if case .loaded = event, atLoad == nil { atLoad = fetches }
        }
        h.engine.finish()
        await coordinator.waitForAutoAdvance()
        coordinator.removeObserver(token)
        return atLoad
    }

    /// Fetches of what a start needs before `/play`: server progress, the streaming policy and
    /// podcast listings.
    var fetches: Fetches {
        Fetches(
            progress: service.state.withLock { $0.progressReads.count }, policy: h.policy.checks,
            listings: episodes.fetches)
    }
}
