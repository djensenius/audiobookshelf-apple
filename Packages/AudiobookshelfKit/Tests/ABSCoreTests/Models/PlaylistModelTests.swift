import ABSCore
import Foundation
import Testing

@Suite struct PlaylistModelTests {
    @Test func malformedMembersAreLossyButValidIdentitiesSurviveBadExpansions() throws {
        let data = Data(
            """
            {"id":"p","libraryId":"l","name":"Playlist","unknown":true,"items":[
              {"libraryItemId":"book","libraryItem":42},
              {"libraryItemId":"podcast","episodeId":"episode","episode":{"index":"bad"},"libraryItem":{}},
              null, 12, {}, {"libraryItemId":false}, {"libraryItemId":"bad","episodeId":42},
              {"libraryItemId":"last","episode":null,"libraryItem":null}
            ]}
            """.utf8)
        let playlist = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(playlist.items.map(\.libraryItemId) == ["book", "podcast", "last"])
        #expect(playlist.items.map(\.id) == ["book", "podcast-episode", "last"])
        #expect(playlist.items.allSatisfy { $0.libraryItem == nil && $0.episode == nil })
        #expect(try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist)) == playlist)
    }

    @Test(arguments: [
        #"{"episodeId":"episode"}"#, #"{"libraryItemId":null}"#,
        #"{"libraryItemId":"podcast","episodeId":false}"#,
    ])
    func invalidIdentityFailsStrictItemDecode(_ json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PlaylistItem.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: ["null", "{}", "42"])
    func malformedItemsContainerStillFails(_ items: String) {
        let data = Data(#"{"id":"p","libraryId":"l","name":"P","items":\#(items)}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Playlist.self, from: data) }
    }

    @Test func initializerAndEncodingRemainCompatible() throws {
        let item = PlaylistItem(
            libraryItemId: "podcast", episodeId: "episode",
            episode: PodcastEpisode(id: "episode", title: "Episode"),
            libraryItem: LibraryItem(id: "podcast", libraryId: "l", mediaType: .podcast))
        let value = Playlist(
            id: "p", libraryId: "l", userId: "u", name: "P", description: "D", coverPath: "/cover",
            items: [item], lastUpdate: 12, createdAt: 10)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(Playlist.self, from: data) == value)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(raw.keys) == [
                "id", "libraryId", "userId", "name", "description", "coverPath", "items", "lastUpdate", "createdAt",
            ])
        #expect(raw["items"] is [[String: Any]])
        #expect(Playlist(id: "p", libraryId: "l", name: "P").items.isEmpty)
    }
}
