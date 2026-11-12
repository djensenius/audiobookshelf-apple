import ABSAPI
import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// An ``ItemDetailService`` that returns one item.
private struct FakeItemDetailService: ItemDetailService {
    let item: LibraryItem

    func item(id: String) async throws -> LibraryItem { item }
}

/// A ``ProgressWriting`` whose writes succeed at once.
private struct AcceptingWriter: ProgressWriting {
    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {}
    func progressID(itemID: String, episodeID: String?) async throws -> String? { nil }
    func deleteProgress(id: String) async throws {}
}

private let episodes = [
    PodcastEpisode(id: "e1", title: "Old", publishedAt: 1000, duration: 600),
    PodcastEpisode(id: "e2", title: "Middle", publishedAt: 2000, duration: 600),
    PodcastEpisode(id: "e3", title: "New", publishedAt: 3000, duration: 600),
]

private func makePodcast(
    type: String? = "episodic", episodes: [PodcastEpisode] = episodes, isMissing: Bool = false
) -> LibraryItem {
    let metadata = PodcastMetadata(
        title: "The Show", author: "  Host  ", description: "<p>About</p>", genres: ["News", " "], explicit: true,
        type: type)
    let podcast = Podcast(
        id: "pod", libraryItemId: "li-pod", metadata: metadata, tags: ["Daily", ""], episodes: episodes)
    return LibraryItem(
        id: "li-pod", libraryId: "lib", isMissing: isMissing, mediaType: .podcast, media: .podcast(podcast))
}

private func progress(
    _ episodeID: String?, duration: Double = 600, currentTime: Double = 0, isFinished: Bool = false,
    lastUpdate: Int = 1
) -> MediaProgress {
    MediaProgress(
        id: "p-\(episodeID ?? "item")", libraryItemId: "li-pod", episodeId: episodeID, duration: duration,
        progress: duration > 0 ? currentTime / duration : 0, currentTime: currentTime, isFinished: isFinished,
        lastUpdate: lastUpdate)
}

@MainActor
private func makeModel(
    _ item: LibraryItem = makePodcast(), cache: ProgressCache = ProgressCache(), settings: AppSettings? = nil
) async -> PodcastDetailModel {
    let detail = ItemDetailModel(itemID: item.id, service: FakeItemDetailService(item: item), cache: cache)
    await detail.load()
    return PodcastDetailModel(
        detail: detail, cache: cache, settings: settings, locale: Locale(identifier: "en_US"))
}

@MainActor
@Suite struct PodcastDetailModelTests {
    @Test(
        arguments: [
            (nil, 600, .notStarted(duration: 600)),
            (nil, nil, .notStarted(duration: nil)),
            (nil, 0, .notStarted(duration: nil)),
            // A record with nothing listened still shows the duration.
            (progress("e", currentTime: 0), 600, .notStarted(duration: 600)),
            (progress("e", currentTime: 150), 600, .inProgress(remaining: 450)),
            // The progress's duration wins over the episode's.
            (progress("e", duration: 900, currentTime: 150), 600, .inProgress(remaining: 750)),
            // Without one, the episode's.
            (
                MediaProgress(id: "p", libraryItemId: "li-pod", progress: 0.5, currentTime: 100), 600,
                .inProgress(remaining: 500)
            ),
            (progress("e", currentTime: 700), 600, .inProgress(remaining: 0)),
            (progress("e", currentTime: 150, isFinished: true), 600, .finished),
            (progress("e", currentTime: 0, isFinished: true), nil, .finished),
        ] as [(MediaProgress?, Double?, PodcastDetailModel.EpisodeStatus)])
    func statusMapsProgress(progress: MediaProgress?, duration: Double?, expected: PodcastDetailModel.EpisodeStatus) {
        let episode = PodcastEpisode(id: "e", duration: duration)
        #expect(PodcastDetailModel.status(for: episode, progress: progress) == expected)
    }

    @Test func eachEpisodeReadsItsOwnProgressFromTheCache() async throws {
        let cache = ProgressCache()
        cache.apply(progress("e2", currentTime: 300))
        // The podcast's own entry belongs to no episode.
        cache.apply(progress(nil, currentTime: 100, isFinished: true))
        let model = await makeModel(cache: cache)
        let byID = Dictionary(uniqueKeysWithValues: model.allEpisodes.map { ($0.id, $0) })
        let e1 = try #require(byID["e1"])
        let e2 = try #require(byID["e2"])

        #expect(model.progress(for: e1) == nil)
        #expect(model.itemProgress(for: e1) == nil)
        #expect(model.status(for: e1) == .notStarted(duration: 600))
        #expect(model.progress(for: e2)?.currentTime == 300)
        #expect(model.itemProgress(for: e2) == ItemProgress(fraction: 0.5))
        #expect(model.status(for: e2) == .inProgress(remaining: 300))
        #expect(model.summary(for: e2)?.episodeID == "e2")
        #expect(model.summary(for: e2)?.itemID == "li-pod")
    }

    @Test func anEpisodesStatusChangesWithItsCacheEntryOnly() async throws {
        let cache = ProgressCache()
        let model = await makeModel(cache: cache)
        let e2 = try #require(model.allEpisodes.first { $0.id == "e2" })
        let changed = Locked(false)
        withObservationTracking {
            _ = model.status(for: e2)
        } onChange: {
            changed.value = true
        }

        cache.apply(progress("e1", currentTime: 10))
        cache.apply(progress(nil, currentTime: 10))
        #expect(!changed.value)
        cache.apply(progress("e2", currentTime: 10))
        #expect(changed.value)
        #expect(model.status(for: e2) == .inProgress(remaining: 590))
    }

    @Test func theListFollowsMarkFinishedAndNotFinished() async throws {
        let cache = ProgressCache()
        cache.apply(progress("e1", currentTime: 600, isFinished: true))
        cache.apply(progress("e2", currentTime: 300))
        let model = await makeModel(cache: cache)
        let actions = ProgressItemActions(cache: cache, writer: AcceptingWriter())

        // The default: incomplete, newest first for an episodic podcast.
        #expect(model.filter == .incomplete)
        #expect(model.episodes.map(\.id) == ["e3", "e2"])
        model.filter = .inProgress
        #expect(model.episodes.map(\.id) == ["e2"])

        try await actions.markFinished(ItemActionTarget(libraryItemID: "li-pod", episodeID: "e2", duration: 600))
        #expect(model.episodes.isEmpty)
        model.filter = .complete
        #expect(model.episodes.map(\.id) == ["e2", "e1"])

        try await actions.markNotFinished(ItemActionTarget(libraryItemID: "li-pod", episodeID: "e1"))
        #expect(model.episodes.map(\.id) == ["e2"])
        model.filter = .incomplete
        #expect(model.episodes.map(\.id) == ["e3", "e1"])
    }

    @Test func searchAndClearFilter() async {
        let model = await makeModel()
        model.filter = .complete
        #expect(model.canClearFilter)
        #expect(model.episodes.isEmpty)
        model.filter = .all
        #expect(!model.canClearFilter)
        model.searchText = "  "
        #expect(!model.canClearFilter)
        model.searchText = " mid"
        #expect(model.canClearFilter)
        #expect(model.episodes.map(\.id) == ["e2"])

        model.filter = .inProgress
        model.clearFilter()
        #expect(model.filter == .all)
        #expect(model.searchText.isEmpty)
        #expect(model.episodes.map(\.id) == ["e3", "e2", "e1"])
    }

    @Test func theDirectionDefaultsToThePodcastsType() async {
        #expect(await makeModel(makePodcast(type: "episodic")).isDescending)
        #expect(await makeModel(makePodcast(type: "serial")).isDescending == false)
        #expect(await makeModel(makePodcast(type: nil)).isDescending == false)

        let serial = await makeModel(makePodcast(type: "serial"))
        serial.filter = .all
        #expect(serial.episodes.map(\.id) == ["e1", "e2", "e3"])
        serial.isDescending = true
        #expect(serial.episodes.map(\.id) == ["e3", "e2", "e1"])
        serial.sort = .title
        #expect(serial.episodes.map(\.id) == ["e1", "e3", "e2"])
    }

    @Test func theFilterAndSortAreSavedForEveryPodcast() async throws {
        try await withLibrarySettings { settings in
            let first = await makeModel(settings: settings)
            #expect(settings.podcastEpisodeListPreferences == nil)
            first.searchText = "old"
            #expect(settings.podcastEpisodeListPreferences == nil)

            first.filter = .complete
            first.sort = .title
            first.isDescending = false
            #expect(
                settings.podcastEpisodeListPreferences == #"{"descending":false,"filter":"complete","sort":"title"}"#)

            let serial = await makeModel(makePodcast(type: "serial"), settings: settings)
            #expect(serial.preferences == EpisodeListPreferences(filter: .complete, sort: .title, descending: false))
            #expect(serial.searchText.isEmpty)
            #expect(!serial.isDescending)
        }
    }

    /// Two windows on one podcast, and a settings reset: each change starts from what is saved now.
    @Test func everyModelReadsTheSavedPreferencesLive() async throws {
        try await withLibrarySettings { settings in
            let first = await makeModel(settings: settings)
            let second = await makeModel(settings: settings)
            #expect(first.filter == .incomplete && second.sort == .publishedAt)
            let changed = Locked(false)
            withObservationTracking {
                _ = second.filter
            } onChange: {
                changed.value = true
            }

            first.filter = .complete
            #expect(changed.value)
            second.sort = .title
            #expect(first.preferences == EpisodeListPreferences(filter: .complete, sort: .title))
            #expect(second.filter == .complete)
            #expect(settings.podcastEpisodeListPreferences == #"{"filter":"complete","sort":"title"}"#)

            settings.resetAll()
            #expect(first.preferences == EpisodeListPreferences())
            #expect(second.filter == .incomplete)
        }
    }

    @Test func progressAndSearchChangesReuseTheSortedOrder() async {
        let cache = ProgressCache()
        let model = await makeModel(cache: cache)
        #expect(model.episodes.map(\.id) == ["e3", "e2", "e1"])
        #expect(model.sortCount == 1)

        cache.apply(progress("e2", currentTime: 600, isFinished: true))
        #expect(model.episodes.map(\.id) == ["e3", "e1"])
        model.searchText = "d"
        #expect(model.episodes.map(\.id) == ["e1"])
        model.filter = .all
        #expect(model.episodes.map(\.id) == ["e2", "e1"])
        #expect(model.sortCount == 1)

        model.isDescending = false
        #expect(model.episodes.map(\.id) == ["e1", "e2"])
        model.sort = .title
        #expect(model.episodes.map(\.id) == ["e2", "e1"])
        #expect(model.sortCount == 3)
    }

    @Test func unreadableSavedPreferencesFallBackToTheDefaults() async throws {
        try await withLibrarySettings { settings in
            settings.podcastEpisodeListPreferences = "not json"
            let model = await makeModel(settings: settings)
            #expect(model.preferences == EpisodeListPreferences())
            // Reading doesn't rewrite them.
            #expect(settings.podcastEpisodeListPreferences == "not json")
        }
    }

    @Test func theHeaderShowsThePodcastsMetadata() async {
        let model = await makeModel()
        #expect(model.title == "The Show")
        #expect(model.author == "Host")
        #expect(model.podcastType == "episodic")
        #expect(model.genres == ["News"])
        #expect(model.tags == ["Daily"])
        #expect(model.descriptionHTML == "<p>About</p>")
        #expect(model.isExplicit)
        #expect(model.summary?.itemID == "li-pod")
    }

    @Test func nextEpisodeNeedsAPlayablePodcast() async {
        let cache = ProgressCache()
        cache.apply(progress("e3", currentTime: 600, isFinished: true))
        let model = await makeModel(cache: cache)
        #expect(model.canPlay)
        #expect(model.nextEpisode?.id == "e2")

        #expect(await makeModel(makePodcast(isMissing: true)).nextEpisode == nil)
        let empty = await makeModel(makePodcast(episodes: []))
        #expect(!empty.canPlay)
        #expect(empty.nextEpisode == nil)
        #expect(empty.episodes.isEmpty)
    }
}
