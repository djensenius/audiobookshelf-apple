import ABSAPI
import ABSCore
import Foundation
import Testing

@Suite struct RecentEpisodesResponseTests {
    private func fixture(_ version: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "recent-episodes-\(version)", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Decode each raw row and expansion independently, so lossy decoding cannot hide a valid row.
    private func verify(_ data: Data, version: String) throws -> RecentEpisodesPage {
        let raw = try object(data)
        let rows = try #require(raw["episodes"] as? [[String: Any]])
        let page = try JSONDecoder().decode(RecentEpisodesPage.self, from: data)
        #expect(Set(raw.keys) == ["episodes", "limit", "page"])
        #expect(raw["limit"] as? Int == 50)
        #expect(raw["page"] as? Int == 0)
        #expect(raw["limit"] as? String == nil)
        #expect(raw["page"] as? String == nil)
        #expect(rows.count == 1)
        #expect(page.rawCount == rows.count)
        #expect(page.episodes.count == rows.count)
        #expect(page.limit == 50 && page.page == 0)
        let identities = try rows.map { try #require($0["id"] as? String) }
        #expect(page.episodes.map(\.id) == identities)
        for (row, decoded) in zip(rows, page.episodes) {
            let episode = try JSONDecoder().decode(
                PodcastEpisode.self, from: JSONSerialization.data(withJSONObject: row))
            let podcastRaw = try #require(row["podcast"] as? [String: Any])
            let podcast = try JSONDecoder().decode(
                Podcast.self, from: JSONSerialization.data(withJSONObject: podcastRaw))
            let trackRaw = try #require(row["audioTrack"] as? [String: Any])
            let track = try JSONDecoder().decode(
                AudioTrack.self, from: JSONSerialization.data(withJSONObject: trackRaw))
            #expect(decoded.episode == episode)
            #expect(decoded.podcast == podcast)
            #expect(decoded.libraryId == (try #require(row["libraryId"] as? String)))
            #expect(episode.libraryItemId == (try #require(row["libraryItemId"] as? String)))
            #expect(episode.podcastId == podcast.id)
            #expect(podcast.libraryItemId == episode.libraryItemId)
            #expect(podcast.metadata.title == "Synthetic Cast")
            #expect((podcastRaw["episodes"] as? [Any])?.isEmpty == true)
            #expect(podcast.episodes == [])
            #expect(episode.title == "Episode One")
            #expect(episode.duration == (try #require(row["duration"] as? Double)))
            #expect(episode.duration == (version == "2.26.0" ? 20.088 : 20))
            #expect(episode.audioTrack == track)
            #expect(track.index == 1 && track.startOffset == 0)
            #expect(track.duration == episode.duration)
            #expect(track.contentUrl == trackRaw["contentUrl"] as? String)
            let file = try #require(episode.audioFile)
            #expect(track.contentUrl == "/api/items/\(try #require(episode.libraryItemId))/file/\(file.ino)")
            #expect(file.mimeType == "audio/mpeg")
            #expect(file.duration == episode.duration)
            // The scanned seed has no feed publication date; do not invent one in captures.
            #expect(row["publishedAt"] is NSNull && row["pubDate"] is NSNull)
            #expect(episode.publishedAt == nil && episode.pubDate == nil)
            #expect(row["userMediaProgress"] == nil)
        }
        return page
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func genuineCapturesRetainEveryRowAndExpansion(version: String) throws {
        let page = try verify(fixture(version), version: version)
        #expect(page.episodes.map(\.id) == ["episode-fixture"])
        #expect(page.episodes.map(\.libraryId) == ["library-podcasts"])
        #expect(page.episodes.map(\.episode.libraryItemId) == ["item-podcast"])
        #expect(page.episodes.map(\.podcast?.id) == ["podcast-fixture"])
        // Optional unmodified local proof uses the same strict assertions, never instead of fixtures.
        if let root = ProcessInfo.processInfo.environment["ABS_RECENT_EPISODES_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(version).appendingPathComponent("normal.json")
            _ = try verify(Data(contentsOf: url), version: version)
        }
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func derivedMixedPageCountsWireRowsAndKeepsMalformedOptionalPodcast(version: String) throws {
        // Derived multi-row unit payload, NOT a live multi-episode page.
        let captured = try object(fixture(version))
        var good = try #require((captured["episodes"] as? [[String: Any]])?.first)
        good["publishedAt"] = 1_700_000_000_000
        good["pubDate"] = "Tue, 14 Nov 2023 22:13:20 GMT"
        var tolerant = good
        tolerant["id"] = "episode-malformed-podcast"
        tolerant["podcast"] = ["id": "missing-metadata"]
        var malformed = good
        malformed["id"] = 7
        let data = try JSONSerialization.data(
            withJSONObject: [
                "episodes": [good, malformed, NSNull(), tolerant], "limit": "4", "page": "3",
            ])
        let page = try JSONDecoder().decode(RecentEpisodesPage.self, from: data)
        #expect(page.episodes.map(\.id) == ["episode-fixture", "episode-malformed-podcast"])
        #expect(page.rawCount == 4 && page.limit == 4 && page.page == 3)
        #expect(page.episodes.first?.podcast?.id == "podcast-fixture")
        #expect(page.episodes.last?.podcast == nil)
        #expect(page.episodes.map(\.episode.publishedAt) == [1_700_000_000_000, 1_700_000_000_000])
        #expect(page.episodes.first?.episode.pubDate == good["pubDate"] as? String)
        let legacy = RecentEpisodesPage(episodes: page.episodes, limit: page.limit, page: page.page)
        #expect(legacy.rawCount == page.episodes.count)
        let explicit = RecentEpisodesPage(
            episodes: page.episodes, limit: page.limit, page: page.page, rawCount: page.rawCount)
        #expect(explicit == page)
        #expect(Set([explicit, page, legacy]).count == 2)
    }
}
