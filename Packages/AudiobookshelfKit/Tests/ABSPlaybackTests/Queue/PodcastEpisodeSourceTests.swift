import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// The podcast "next episode" rule ported from the legacy app (`pages/item/_id/index.vue`).
struct PodcastEpisodeSourceTests {
    private func episodes(_ dates: [(String, Int?)]) -> [PodcastEpisode] {
        dates.map { PodcastEpisode(id: $0.0, publishedAt: $0.1) }
    }

    @Test func serialPlaysOldestFirstAndEpisodicNewestFirst() {
        let list = episodes([("b", 200), ("undated", nil), ("a", 100), ("c", 300), ("c2", 300)])
        let serial = PodcastEpisodeListing(isSerial: true, episodes: list, finishedEpisodeIDs: [])
        let episodic = PodcastEpisodeListing(isSerial: false, episodes: list, finishedEpisodeIDs: [])

        // Undated counts as latest; ties keep the server's order.
        #expect(serial.playOrder.map(\.id) == ["a", "b", "c", "c2", "undated"])
        #expect(episodic.playOrder.map(\.id) == ["undated", "c", "c2", "b", "a"])
    }

    @Test func nextUnfinishedSkipsFinishedAndTheEndingEpisode() {
        var listing = PodcastEpisodeListing(
            isSerial: true, episodes: episodes([("e1", 1), ("e2", 2), ("e3", 3)]), finishedEpisodeIDs: ["e1"])

        // As the legacy rule: the first unfinished episode in order, not the one after the current.
        #expect(listing.nextUnfinished(after: "e2")?.id == "e3")
        #expect(listing.nextUnfinished(after: "e3")?.id == "e2")
        listing.finishedEpisodeIDs = ["e1", "e3"]
        #expect(listing.nextUnfinished(after: "e2") == nil)
    }

    @Test func listingFromItemAndProgressKeepsOnlyThisPodcastsFinishedEpisodes() {
        let item = LibraryItem(
            id: "P", libraryId: "lib", mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "pod", metadata: PodcastMetadata(title: "Pod", type: "serial"),
                    episodes: episodes([("e1", 1), ("e2", 2)]))))
        let listing = PodcastEpisodeListing(
            item: item,
            progress: [
                .init(libraryItemId: "P", episodeId: "e1", isFinished: true),
                .init(libraryItemId: "P", episodeId: "e2", isFinished: false),
                .init(libraryItemId: "Other", episodeId: "e2", isFinished: true),
                .init(libraryItemId: "P", isFinished: true),
            ])

        #expect(listing.isSerial)
        #expect(listing.episodes.map(\.id) == ["e1", "e2"])
        #expect(listing.finishedEpisodeIDs == ["e1"])
    }

    /// A finished change not yet synced wins over the server's flag.
    @Test func unsyncedLocalFinishOverridesServer() async throws {
        let connection = UUID()
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let key = { MediaKey(serverConnectionID: connection, libraryItemId: "P", episodeId: $0) }
        _ = try await store.recordEdit(ProgressEdit(isFinished: true), for: key("e1"))
        _ = try await store.recordEdit(ProgressEdit(isFinished: false), for: key("e2"))
        let item = LibraryItem(
            id: "P", libraryId: "lib", mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "pod", metadata: PodcastMetadata(title: "Pod", type: "serial"),
                    episodes: episodes([("e1", 1), ("e2", 2), ("e3", 3)]))))
        let source = APIPodcastEpisodeSource(
            serverConnectionID: connection, localProgress: store, fetchItem: { _ in item },
            fetchFinished: {
                UserFinishedMediaResponse(mediaProgress: [.init(libraryItemId: "P", episodeId: "e2", isFinished: true)])
            })

        let listing = try await source.listing(podcastItemID: "P", excluding: ["e3"])

        #expect(listing.finishedEpisodeIDs == ["e1"])
        #expect(listing.nextUnfinished(after: "e3")?.id == "e2")
    }

    /// L2: with e1 and e2 excluded (ended here, ending), e3's unsynced local finish is still read.
    @Test func localFinishBehindExcludedEpisodesIsRead() async throws {
        let connection = UUID()
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        _ = try await store.recordEdit(
            ProgressEdit(isFinished: true),
            for: MediaKey(serverConnectionID: connection, libraryItemId: "P", episodeId: "e3"))
        let item = LibraryItem(
            id: "P", libraryId: "lib", mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "pod", metadata: PodcastMetadata(title: "Pod", type: "serial"),
                    episodes: episodes([("e1", 1), ("e2", 2), ("e3", 3), ("e4", 4)]))))
        let source = APIPodcastEpisodeSource(
            serverConnectionID: connection, localProgress: store, fetchItem: { _ in item },
            fetchFinished: { UserFinishedMediaResponse(mediaProgress: []) })

        var listing = try await source.listing(podcastItemID: "P", excluding: ["e1", "e2"])
        listing.finishedEpisodeIDs.insert("e1")

        #expect(listing.nextUnfinished(after: "e2")?.id == "e4")
    }
}
