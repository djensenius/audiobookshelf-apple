import ABSAPI
import ABSCore
import Foundation
import Testing

// Independent genuine creates on each pinned official image; see server-contracts.md.
// Only synthetic IDs/dates and representative expanded fields are retained in bundled fixtures.
func playlistWriteFixture(_ version: String, kind: String = "book") throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "playlist-writes-\(version)", withExtension: "json", subdirectory: "Fixtures"))
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return try JSONSerialization.data(withJSONObject: #require(raw[kind]))
}

@Suite struct PlaylistResponseTests {
    /// Strict nested decoding is independent of PlaylistItem's intentionally lenient expansions.
    private func verify(_ data: Data, count: Int) throws -> Playlist {
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let members = try #require(raw["items"] as? [[String: Any]])
        let playlist = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(members.count == count)
        #expect(playlist.items.count == members.count)
        for (member, decoded) in zip(members, playlist.items) {
            #expect(decoded.libraryItemId == member["libraryItemId"] as? String)
            #expect(decoded.episodeId == member["episodeId"] as? String)
            let libraryData = try JSONSerialization.data(withJSONObject: #require(member["libraryItem"]))
            let library = try JSONDecoder().decode(LibraryItem.self, from: libraryData)
            #expect(decoded.libraryItem == library)
            #expect(library.id == decoded.libraryItemId)
            #expect(library.media != nil)
            if let episodeID = decoded.episodeId {
                let episodeData = try JSONSerialization.data(withJSONObject: #require(member["episode"]))
                let episode = try JSONDecoder().decode(PodcastEpisode.self, from: episodeData)
                #expect(decoded.episode == episode)
                #expect(episode.id == episodeID)
                #expect(episode.libraryItemId == decoded.libraryItemId)
                #expect(episode.audioTrack != nil)
            }
        }
        #expect(try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist)) == playlist)
        return playlist
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func actualResponsesRetainIdentitiesAndStrictExpansions(version: String) throws {
        // Optional local untrimmed capture verification, never substituted for fixture assertions.
        if let root = ProcessInfo.processInfo.environment["ABS_PLAYLIST_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: root).appendingPathComponent(version)
            for kind in ["book", "podcast"] {
                let count = kind == "book" ? 2 : 1
                let captured = try verify(
                    Data(contentsOf: directory.appendingPathComponent("\(kind)-create.json")), count: count)
                let listData = try Data(contentsOf: directory.appendingPathComponent("\(kind)-list.json"))
                let rawList = try #require(JSONSerialization.jsonObject(with: listData) as? [String: Any])
                let entries = try #require(rawList["results"] as? [[String: Any]])
                let page = try JSONDecoder().decode(PagedResults<Playlist>.self, from: listData)
                #expect(page.rawCount == entries.count)
                #expect(page.results.count == entries.count)
                let rawEntry = try #require(entries.first { $0["id"] as? String == captured.id })
                let listed = try verify(JSONSerialization.data(withJSONObject: rawEntry), count: count)
                #expect(listed.items == captured.items)
            }
        }
        let books = try verify(playlistWriteFixture(version), count: 2)
        #expect(books.items.map(\.libraryItemId) == ["item-book0", "item-book1"])
        #expect(books.items.map(\.libraryItem?.book?.metadata.title) == ["Single File Tale", "The Synthetic Tale"])
        #expect(books.items.last?.libraryItem?.book?.duration == (version == "2.26.0" ? 50.184 : 50))
        let podcast = try verify(playlistWriteFixture(version, kind: "podcast"), count: 1)
        #expect(podcast.items.first?.id == "item-podcast0-episode-fixture")
        #expect(podcast.items.first?.episode?.duration == (version == "2.26.0" ? 20.088 : 20))
    }

    @Test func outerRawCountCountsPlaylistsNotMembers() throws {
        let good = try #require(JSONSerialization.jsonObject(with: playlistWriteFixture("2.37.2")) as? [String: Any])
        var damaged = good
        damaged["items"] = [NSNull(), ["libraryItemId": "valid", "libraryItem": false]]
        let data = try JSONSerialization.data(
            withJSONObject: ["results": [good, damaged, ["id": "invalid"]], "total": 3, "limit": "10", "page": "0"])
        let page = try JSONDecoder().decode(PagedResults<Playlist>.self, from: data)
        #expect(page.rawCount == 3)
        #expect(page.results.count == 2)
        #expect(page.results.map(\.items.count) == [2, 1])
        #expect(page.limit == 10)
        #expect(page.page == 0)
    }
}
