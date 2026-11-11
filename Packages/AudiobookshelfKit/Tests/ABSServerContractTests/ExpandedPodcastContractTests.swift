import ABSAPI
import ABSCore
import Foundation
import Testing

@Suite("Server contract: expanded podcast", .requiresServer, .tags(.serverContract))
struct ExpandedPodcastContractTests {
    private func object(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        let value = try #require(value)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func chapters(_ value: Any?) throws -> [Chapter] {
        let rows = try #require(value as? [Any])
        return try rows.map { try decode(Chapter.self, $0) }
    }

    private func metadata(_ value: Any?, itemPath: String) throws -> FileMetadata {
        let metadata = try decode(FileMetadata.self, value)
        #expect(metadata.filename == "Episode One.mp3" && metadata.ext == ".mp3")
        #expect(metadata.relPath == "Episode One.mp3")
        #expect(metadata.path == "\(itemPath)/Episode One.mp3")
        #expect((metadata.size ?? 0) > 0)
        return metadata
    }

    @Test("expanded podcast retains the seeded episode, complete inventory and ordered playback data")
    func expandedPodcast() async throws {
        // Read-only seeded-admin GETs, like LibraryContractTests. No user/progress/RSS mutations.
        let client = try await ContractAdmin.shared.session().client
        let seed = try await ContractSeed.shared.data()
        // The independent library folder supplies the root on both Docker and Node.
        let libraries = try await client.send(LibraryEndpoints.libraries()).libraries
        let seededLibraries = libraries.filter { $0.id == seed.podcastLibraryID }
        try #require(seededLibraries.count == 1)
        #expect(seededLibraries[0].mediaType == .podcast)
        let folders = try #require(seededLibraries[0].folders)
        try #require(folders.count == 1)
        let itemPath = "\(folders[0].fullPath)/Synthetic Cast"
        let endpoint = ItemEndpoints.item(id: seed.podcastID)
        let data = try await client.send(Endpoint<Data>(endpoint.method, endpoint.path, query: endpoint.query))
        let item = try await client.send(endpoint)
        let raw = try object(JSONSerialization.jsonObject(with: data))
        #expect(item == (try JSONDecoder().decode(LibraryItem.self, from: data)))
        #expect(raw["id"] as? String == seed.podcastID && item.id == seed.podcastID)
        #expect(raw["libraryId"] as? String == seed.podcastLibraryID && item.libraryId == seed.podcastLibraryID)
        #expect(item.folderId == folders[0].id)
        #expect(item.path == itemPath && item.relPath == "Synthetic Cast")
        #expect(raw["mediaType"] as? String == "podcast" && item.mediaType == .podcast)
        #expect(!item.isMissing && !item.isInvalid && item.book == nil)
        let media = try object(raw["media"])
        let podcast = try #require(item.podcast)
        #expect(podcast == (try decode(Podcast.self, media)))
        #expect(podcast.libraryItemId == seed.podcastID)
        #expect(podcast.metadata == (try decode(PodcastMetadata.self, media["metadata"])))
        #expect(podcast.metadata.title == "Synthetic Cast" && podcast.metadata.author == "Synthetic Cast")
        #expect(podcast.metadata.genres == ["Podcast"] && podcast.metadata.type == "episodic")

        // SeedData has no media ID. Check it against a separate raw minified listing, not a lossy result.
        let listing = LibraryEndpoints.items(libraryID: seed.podcastLibraryID)
        let listedData = try await client.send(Endpoint<Data>(listing.method, listing.path, query: listing.query))
        let listed = try object(JSONSerialization.jsonObject(with: listedData))
        let listedRows = try #require(listed["results"] as? [[String: Any]])
        try #require(listedRows.count == 1)
        for row in listedRows {
            #expect(row["id"] as? String == seed.podcastID)
            #expect(row["libraryId"] as? String == seed.podcastLibraryID)
            let listedMedia = try object(row["media"])
            #expect(podcast.id == (try #require(listedMedia["id"] as? String)))
            #expect(listedMedia["numEpisodes"] as? Int == 1)
        }
        #expect(raw["rssFeed"] is NSNull)
        switch ContractServer.current?.version {
        case "2.26.0":
            #expect(!raw.keys.contains("numFiles") && !media.keys.contains("numEpisodes"))
            #expect(item.numFiles == nil && podcast.numEpisodes == nil)
        case "2.37.2":
            #expect(raw["numFiles"] as? Int == 1 && media["numEpisodes"] as? Int == 1)
            #expect(item.numFiles == 1 && podcast.numEpisodes == 1)
        default: break
        }
        for key in ["numTracks", "numAudioFiles", "numChapters"] {
            #expect(!media.keys.contains(key))
        }
        let fileRows = try #require(raw["libraryFiles"] as? [Any])
        let files = try fileRows.map { try decode(LibraryFile.self, $0) }
        #expect(fileRows.count == 1 && item.libraryFiles?.count == 1)
        #expect(item.libraryFiles == files)
        for (row, file) in zip(fileRows, files) {
            let rawFile = try object(row)
            #expect(file.metadata == (try metadata(rawFile["metadata"], itemPath: itemPath)))
            #expect(file.fileType == "audio")
            #expect(rawFile["isSupplementary"] is NSNull && file.isSupplementary == nil)
        }
        let rows = try #require(media["episodes"] as? [Any])
        let episodes = try rows.map { try decode(PodcastEpisode.self, $0) }
        // The script seeds ONE episode. Neither expected count is derived from the lossy decoder.
        #expect(rows.count == 1 && podcast.episodes?.count == 1)
        #expect(podcast.episodes == episodes)
        #expect(episodes.map(\.id) == [seed.episodeID])
        #expect(podcast.episodes?.map(\.id) == [seed.episodeID])
        for (row, episode) in zip(rows, episodes) {
            let rawEpisode = try object(row)
            #expect(episode.libraryItemId == seed.podcastID && episode.podcastId == podcast.id)
            #expect(episode.title == "Episode One" && approximately(episode.duration, 20))
            #expect(episode.duration == (try #require(rawEpisode["duration"] as? Double)))
            #expect(episode.chapters == (try chapters(rawEpisode["chapters"])))
            #expect(episode.chapters == [])
            let rawAudio = try object(rawEpisode["audioFile"])
            let audio = try decode(AudioFile.self, rawAudio)
            let rawTrack = try object(rawEpisode["audioTrack"])
            let track = try decode(AudioTrack.self, rawTrack)
            #expect(episode.audioFile == audio && episode.audioTrack == track)
            #expect(audio.metadata == (try metadata(rawAudio["metadata"], itemPath: itemPath)))
            #expect(track.metadata == (try metadata(rawTrack["metadata"], itemPath: itemPath)))
            #expect(files.map(\.ino) == [audio.ino])
            #expect(files.map(\.metadata) == [audio.metadata])
            #expect(audio.chapters == (try chapters(rawAudio["chapters"])))
            // AudioTrack omits these raw file fields: independently decode all of them, including chapters.
            #expect(try chapters(rawTrack["chapters"]) == [])
            #expect(try decode(AudioFile.self, rawTrack) == audio)
            #expect(audio.chapters == [] && audio.index == 1 && track.index == 1)
            #expect(audio.duration == episode.duration && track.duration == episode.duration)
            #expect(track.startOffset == 0 && track.title == "Episode One.mp3")
            #expect(audio.mimeType == "audio/mpeg" && track.mimeType == "audio/mpeg")
            #expect(audio.codec == "mp3" && track.codec == "mp3")
            #expect(track.contentUrl == "/api/items/\(seed.podcastID)/file/\(audio.ino)")
            #expect(episode.size == audio.metadata?.size && item.size == episode.size && podcast.size == episode.size)
            #expect(rawEpisode["publishedAt"] is NSNull && rawEpisode["pubDate"] is NSNull)
            #expect(episode.publishedAt == nil && episode.pubDate == nil)
            #expect(rawEpisode["index"] is NSNull && episode.index == nil)
            #expect(rawEpisode["userMediaProgress"] == nil)
            #expect(
                ItemSummary(item: item, episode: episode)
                    == ItemSummary(
                        id: "\(seed.podcastID)-\(seed.episodeID)", itemID: seed.podcastID, episodeID: seed.episodeID,
                        kind: .episode, title: "Episode One", subtitle: "Synthetic Cast", duration: episode.duration))
        }
        #expect(
            ItemSummary(item: item)
                == ItemSummary(
                    id: seed.podcastID, itemID: seed.podcastID, kind: .podcast, title: "Synthetic Cast",
                    subtitle: "Synthetic Cast", hasAudio: false))
    }
}
