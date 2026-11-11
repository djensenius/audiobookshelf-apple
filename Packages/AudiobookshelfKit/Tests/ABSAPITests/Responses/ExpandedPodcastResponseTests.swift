import ABSAPI
import ABSCore
import Foundation
import Testing

@Suite struct ExpandedPodcastResponseTests {
    private func fixture(_ version: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "expanded-item-podcast-\(version)", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

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

    private func metadata(_ value: Any?) throws -> FileMetadata {
        let metadata = try decode(FileMetadata.self, value)
        #expect(metadata.filename == "Episode One.mp3" && metadata.ext == ".mp3")
        #expect(metadata.path == "/podcasts/Synthetic Cast/Episode One.mp3")
        #expect(metadata.relPath == "Episode One.mp3" && metadata.size == 40_494)
        return metadata
    }

    /// Strict independent decoding, not counts inferred from Podcast's lossy episode array.
    private func verify(_ data: Data, version: String) throws -> LibraryItem {
        let raw = try object(JSONSerialization.jsonObject(with: data))
        let item = try JSONDecoder().decode(LibraryItem.self, from: data)
        let media = try object(raw["media"])
        let podcast = try #require(item.podcast)
        #expect(item.id == (try #require(raw["id"] as? String)))
        #expect(item.libraryId == (try #require(raw["libraryId"] as? String)))
        #expect(raw["mediaType"] as? String == "podcast" && item.mediaType == .podcast)
        #expect(!item.isMissing && !item.isInvalid && item.book == nil)
        #expect(podcast == (try decode(Podcast.self, media)))
        #expect(podcast.libraryItemId == item.id)
        #expect(podcast.metadata == (try decode(PodcastMetadata.self, media["metadata"])))
        #expect(podcast.metadata.title == "Synthetic Cast" && podcast.metadata.author == "Synthetic Cast")
        #expect(podcast.metadata.genres == ["Podcast"] && podcast.metadata.type == "episodic")
        #expect(item.size == 40_494 && podcast.size == 40_494)
        #expect(raw["rssFeed"] is NSNull)
        if version == "2.26.0" {
            #expect(!raw.keys.contains("numFiles") && !media.keys.contains("numEpisodes"))
            #expect(item.numFiles == nil && podcast.numEpisodes == nil)
        } else {
            #expect(raw["numFiles"] as? Int == 1 && media["numEpisodes"] as? Int == 1)
            #expect(item.numFiles == 1 && podcast.numEpisodes == 1)
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
            #expect(file.metadata == (try metadata(rawFile["metadata"])))
            #expect(file.fileType == "audio")
            #expect(rawFile["isSupplementary"] is NSNull && file.isSupplementary == nil)
        }
        let rows = try #require(media["episodes"] as? [Any])
        let episodes = try rows.map { try decode(PodcastEpisode.self, $0) }
        #expect(rows.count == 1 && podcast.episodes?.count == 1)
        #expect(podcast.episodes == episodes)
        let duration = version == "2.26.0" ? 20.088 : 20.0
        for (row, episode) in zip(rows, episodes) {
            let rawEpisode = try object(row)
            #expect(episode.libraryItemId == item.id && episode.podcastId == podcast.id)
            #expect(episode.title == "Episode One" && episode.duration == duration)
            #expect(episode.size == 40_494)
            #expect(episode.chapters == (try chapters(rawEpisode["chapters"])))
            #expect(episode.chapters == [])
            let rawAudio = try object(rawEpisode["audioFile"])
            let audio = try decode(AudioFile.self, rawAudio)
            let rawTrack = try object(rawEpisode["audioTrack"])
            let track = try decode(AudioTrack.self, rawTrack)
            #expect(episode.audioFile == audio && episode.audioTrack == track)
            #expect(audio.metadata == (try metadata(rawAudio["metadata"])))
            #expect(track.metadata == (try metadata(rawTrack["metadata"])))
            #expect(files.map(\.ino) == [audio.ino])
            #expect(files.map(\.metadata) == [audio.metadata])
            #expect(audio.chapters == (try chapters(rawAudio["chapters"])))
            // AudioTrack does not model chapters or all file fields. Decode those independently too.
            #expect(try chapters(rawTrack["chapters"]) == [])
            #expect(try decode(AudioFile.self, rawTrack) == audio)
            #expect(audio.chapters == [] && audio.index == 1 && track.index == 1)
            #expect(audio.duration == duration && track.duration == duration && track.startOffset == 0)
            #expect(audio.mimeType == "audio/mpeg" && track.mimeType == "audio/mpeg")
            #expect(audio.codec == "mp3" && track.codec == "mp3")
            #expect(track.title == "Episode One.mp3")
            #expect(track.contentUrl == "/api/items/\(item.id)/file/\(audio.ino)")
            #expect(rawEpisode["publishedAt"] is NSNull && rawEpisode["pubDate"] is NSNull)
            #expect(episode.publishedAt == nil && episode.pubDate == nil)
            #expect(rawEpisode["index"] is NSNull && episode.index == nil)
            #expect(rawEpisode["userMediaProgress"] == nil)
            #expect(
                ItemSummary(item: item, episode: episode)
                    == ItemSummary(
                        id: "\(item.id)-\(episode.id)", itemID: item.id, episodeID: episode.id,
                        kind: .episode, title: "Episode One", subtitle: "Synthetic Cast", duration: duration))
        }
        #expect(
            ItemSummary(item: item)
                == ItemSummary(
                    id: item.id, itemID: item.id, kind: .podcast, title: "Synthetic Cast",
                    subtitle: "Synthetic Cast", hasAudio: false))
        return item
    }

    /// Only these exact JSON paths may change. Related identities must use the same source value.
    private func substitutions(_ raw: [String: Any]) throws -> [String: (String, String)] {
        let media = try object(raw["media"])
        let rows = try #require(media["episodes"] as? [[String: Any]])
        try #require(rows.count == 1)
        let episode = rows[0]
        let audio = try object(episode["audioFile"])
        let itemID = try #require(raw["id"] as? String)
        let podcastID = try #require(media["id"] as? String)
        let inode = try #require(audio["ino"] as? String)
        let prefix = "/media/episodes/0"
        return [
            "/id": (itemID, "item-podcast"),
            "/ino": (try #require(raw["ino"] as? String), "inode-podcast"),
            "/libraryId": (try #require(raw["libraryId"] as? String), "library-podcasts"),
            "/folderId": (try #require(raw["folderId"] as? String), "folder-podcasts"),
            "/media/id": (podcastID, "podcast-fixture"),
            "/media/libraryItemId": (itemID, "item-podcast"),
            "\(prefix)/libraryItemId": (itemID, "item-podcast"),
            "\(prefix)/podcastId": (podcastID, "podcast-fixture"),
            "\(prefix)/id": (try #require(episode["id"] as? String), "episode-fixture"),
            "\(prefix)/audioFile/ino": (inode, "inode-episode"),
            "\(prefix)/audioTrack/ino": (inode, "inode-episode"),
            "\(prefix)/audioTrack/contentUrl": (
                "/api/items/\(itemID)/file/\(inode)", "/api/items/item-podcast/file/inode-episode"
            ),
            "/libraryFiles/0/ino": (inode, "inode-episode"),
        ]
    }

    private func compare(
        _ original: Any, _ sanitized: Any, path: String = "",
        allowed: [String: (String, String)], visited: inout Set<String>
    ) throws {
        if let (before, after) = allowed[path] {
            #expect(original as? String == before, "Original relationship at \(path)")
            #expect(sanitized as? String == after, "Sanitized relationship at \(path)")
            visited.insert(path)
        } else if let lhs = original as? [String: Any] {
            let rhs = try object(sanitized)
            #expect(Set(lhs.keys) == Set(rhs.keys), "Keys at \(path)")
            for key in lhs.keys.sorted() {
                try compare(
                    try #require(lhs[key]), try #require(rhs[key]), path: "\(path)/\(key)",
                    allowed: allowed, visited: &visited)
            }
        } else if let lhs = original as? [Any] {
            let rhs = try #require(sanitized as? [Any])
            try #require(lhs.count == rhs.count, "Array length at \(path)")
            for index in lhs.indices {
                try compare(lhs[index], rhs[index], path: "\(path)/\(index)", allowed: allowed, visited: &visited)
            }
        } else if let lhs = original as? NSNumber {
            let rhs = try #require(sanitized as? NSNumber)
            #expect(String(cString: lhs.objCType) == String(cString: rhs.objCType), "Scalar type at \(path)")
            #expect(lhs == rhs, "Number at \(path)")
        } else if let lhs = original as? String {
            #expect(sanitized as? String == lhs, "String at \(path)")
        } else {
            #expect(original is NSNull && sanitized is NSNull, "Null at \(path)")
        }
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func completeCapturesPreserveEveryExpansion(version: String) throws {
        let data = try fixture(version)
        let item = try verify(data, version: version)
        #expect(item.id == "item-podcast" && item.libraryId == "library-podcasts")
        #expect(item.ino == "inode-podcast" && item.folderId == "folder-podcasts")
        #expect(item.podcast?.id == "podcast-fixture")
        #expect(item.podcast?.episodes?.map(\.id) == ["episode-fixture"])
        #expect(item.libraryFiles?.map(\.ino) == ["inode-episode"])
        // Optional local originals supplement, never replace, the always-executed fixture checks.
        if let root = ProcessInfo.processInfo.environment["ABS_EXPANDED_PODCAST_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(version).appendingPathComponent("podcast.json")
            let original = try Data(contentsOf: url)
            _ = try verify(original, version: version)
            let raw = try object(JSONSerialization.jsonObject(with: original))
            let allowed = try substitutions(raw)
            var visited: Set<String> = []
            try compare(raw, JSONSerialization.jsonObject(with: data), allowed: allowed, visited: &visited)
            #expect(visited == Set(allowed.keys))
        }
    }
}
