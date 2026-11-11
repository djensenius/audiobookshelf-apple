import ABSAPI
import ABSCore
import Foundation
import Testing

@Suite("Server contract: recent episodes", .requiresServer, .tags(.serverContract))
struct RecentEpisodesContractTests {
    // Read as the seeded admin, like LibraryContractTests: no users, progress or other mutations.
    private func response(page: Int = 0, limit: Int = 50) async throws -> (Data, RecentEpisodesPage, SeedData) {
        let client = try await ContractAdmin.shared.session().client
        let seed = try await ContractSeed.shared.data()
        let endpoint = LibraryEndpoints.recentEpisodes(libraryID: seed.podcastLibraryID, page: page, limit: limit)
        let data = try await client.send(Endpoint<Data>(endpoint.method, endpoint.path, query: endpoint.query))
        let decoded = try await client.send(endpoint)
        return (data, decoded, seed)
    }

    @Test("normal page retains every raw episode and its nested expansion")
    func normalPage() async throws {
        let (data, page, seed) = try await response()
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(raw["episodes"] as? [[String: Any]])
        #expect(Set(raw.keys) == ["episodes", "limit", "page"])
        // Both actual official images echo numbers, despite the controller reading req.query.
        #expect(raw["limit"] as? Int == 50 && raw["page"] as? Int == 0)
        #expect(raw["limit"] as? String == nil && raw["page"] as? String == nil)
        #expect(rows.count == 1)
        #expect(page.rawCount == rows.count && page.episodes.count == rows.count)
        #expect(page.limit == 50 && page.page == 0)
        #expect(page.episodes.map(\.id) == [seed.episodeID])
        #expect(page.episodes.map(\.id) == (try rows.map { try #require($0["id"] as? String) }))
        for (row, recent) in zip(rows, page.episodes) {
            let episode = try JSONDecoder().decode(
                PodcastEpisode.self, from: JSONSerialization.data(withJSONObject: row))
            let podcastRaw = try #require(row["podcast"] as? [String: Any])
            let podcast = try JSONDecoder().decode(
                Podcast.self, from: JSONSerialization.data(withJSONObject: podcastRaw))
            let trackRaw = try #require(row["audioTrack"] as? [String: Any])
            let track = try JSONDecoder().decode(
                AudioTrack.self, from: JSONSerialization.data(withJSONObject: trackRaw))
            #expect(recent.episode == episode && recent.podcast == podcast)
            #expect(recent.libraryId == seed.podcastLibraryID)
            #expect(row["libraryId"] as? String == seed.podcastLibraryID)
            #expect(episode.libraryItemId == seed.podcastID)
            #expect(podcast.libraryItemId == seed.podcastID && podcast.id == episode.podcastId)
            #expect(podcast.metadata.title == "Synthetic Cast")
            #expect((podcastRaw["episodes"] as? [Any])?.isEmpty == true && podcast.episodes == [])
            #expect(episode.title == "Episode One")
            #expect(episode.duration == (try #require(row["duration"] as? Double)))
            #expect(approximately(episode.duration, 20))
            #expect(episode.audioTrack == track)
            #expect(track.index == 1 && track.startOffset == 0)
            #expect(track.duration == episode.duration)
            let audioFile = try #require(episode.audioFile)
            #expect(audioFile.mimeType == "audio/mpeg")
            #expect(audioFile.duration == episode.duration)
            #expect(track.contentUrl == "/api/items/\(seed.podcastID)/file/\(audioFile.ino)")
            #expect(row["publishedAt"] is NSNull && row["pubDate"] is NSNull)
            #expect(episode.publishedAt == nil && episode.pubDate == nil)
            #expect(row["userMediaProgress"] == nil)
        }
    }

    @Test("page one is empty for the one-episode seed, without a total")
    func emptyPage() async throws {
        let (data, page, _) = try await response(page: 1, limit: 1)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(raw["episodes"] as? [Any])
        #expect(Set(raw.keys) == ["episodes", "limit", "page"])
        #expect(raw["limit"] as? Int == 1 && raw["page"] as? Int == 1)
        #expect(raw["limit"] as? String == nil && raw["page"] as? String == nil)
        #expect(rows.isEmpty)
        #expect(page.rawCount == rows.count && page.episodes.isEmpty)
        #expect(page.limit == 1 && page.page == 1)
    }

    @Test("a book library rejects recent episodes with 404")
    func bookLibrary() async throws {
        let client = try await ContractAdmin.shared.session().client
        let seed = try await ContractSeed.shared.data()
        await expectNotFound {
            try await client.send(LibraryEndpoints.recentEpisodes(libraryID: seed.bookLibraryID))
        }
    }
}
