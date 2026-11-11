import ABSAPI
import ABSCore
import CoreFoundation
import CryptoKit
import Foundation
import Testing

@Suite struct ExpandedBookResponseTests {
    private func object(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    private func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
    }

    /// Decode EVERY element, independently of the containing model; compare complete ordered values.
    private func array<T: Decodable & Equatable>(
        _ raw: [String: Any], _ key: String, matching decoded: [T]?
    ) throws -> [T] {
        let rows = try #require(raw[key] as? [Any])
        let values = try rows.map { try decode($0, as: T.self) }
        let decoded = try #require(decoded)
        #expect(values.count == decoded.count)
        #expect(values == decoded)
        return values
    }

    private func arrayPaths(_ value: Any, at path: String = "") -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: []) { $0.formUnion(arrayPaths($1.value, at: path + "/" + $1.key)) }
        }
        if let rows = value as? [Any] {
            return rows.enumerated().reduce(into: [path]) {
                $0.formUnion(arrayPaths($1.element, at: path + "/\($1.offset)"))
            }
        }
        return []
    }

    private func verify(
        _ data: Data, version: String, kind: String, itemID: String, libraryID: String, mediaID: String
    ) throws {
        let raw = try object(JSONSerialization.jsonObject(with: data))
        let item = try JSONDecoder().decode(LibraryItem.self, from: data)
        let book = try #require(item.book)
        let media = try object(raw["media"])
        let metadata = try object(media["metadata"])
        let single = kind == "m4b"
        let count = single ? 1 : 2
        let title = single ? "Single File Tale" : "The Synthetic Tale"
        let names = single ? ["Single File Tale.m4b"] : ["01 - Part One.mp3", "02 - Part Two.mp3"]
        let durations: [Double] = single ? [40] : (version == "2.26.0" ? [30.096, 20.088] : [30, 20])
        let offsets: [Double] = single ? [0] : [0, durations[0]]
        let chapters: [Chapter] =
            single
            ? [
                Chapter(id: 0, start: 0, end: 10, title: "Opening"),
                Chapter(id: 1, start: 10, end: 25, title: "Middle"),
                Chapter(id: 2, start: 25, end: 40, title: "Ending"),
            ]
            : [
                Chapter(id: 0, start: 0, end: durations[0], title: "Part One"),
                Chapter(id: 1, start: durations[0], end: durations.reduce(0, +), title: "Part Two"),
            ]
        #expect(item.id == itemID && item.libraryId == libraryID && item.mediaType == .book)
        #expect(book.id == mediaID && book.libraryItemId == itemID)
        #expect(raw["id"] as? String == itemID && raw["libraryId"] as? String == libraryID)
        #expect(raw["mediaType"] as? String == "book")
        #expect(book == (try decode(media, as: Book.self)))
        #expect(book.metadata == (try decode(metadata, as: BookMetadata.self)))
        #expect(book.metadata.title == title)
        #expect(item.path == "/audiobooks/Ada Fixture/\(title)" && item.relPath == "Ada Fixture/\(title)")
        #expect(!item.isMissing && !item.isInvalid && item.isFile == false)
        #expect(raw["rssFeed"] is NSNull && raw["oldLibraryItemId"] is NSNull)
        #expect(media["ebookFile"] is NSNull && media["coverPath"] is NSNull)
        let authors = try array(metadata, "authors", matching: book.metadata.authors)
        #expect(authors.map(\.name) == ["Ada Fixture"])
        #expect(try array(metadata, "narrators", matching: book.metadata.narrators) == [])
        #expect(try array(metadata, "series", matching: book.metadata.series) == [])
        #expect(try array(metadata, "genres", matching: book.metadata.genres) == [])
        #expect(try array(media, "tags", matching: book.tags) == [])
        let files = try array(media, "audioFiles", matching: book.audioFiles)
        let tracks = try array(media, "tracks", matching: book.tracks)
        let inventory = try array(raw, "libraryFiles", matching: item.libraryFiles)
        #expect(try array(media, "chapters", matching: book.chapters) == chapters)
        try #require(files.count == count && tracks.count == count && inventory.count == count)
        #expect(files.map(\.index) == (1...count).map { Optional($0) })
        #expect(tracks.map(\.index) == (1...count).map { Optional($0) })
        #expect(files.map(\.duration) == durations.map { Optional($0) })
        #expect(tracks.map(\.duration) == durations && tracks.map(\.startOffset) == offsets.map { Optional($0) })
        #expect(inventory.map(\.ino) == files.map(\.ino))
        #expect(Set(files.map(\.ino)).count == count)
        #expect(book.duration == durations.reduce(0, +))
        let fileRows = try #require(media["audioFiles"] as? [[String: Any]])
        let trackRows = try #require(media["tracks"] as? [[String: Any]])
        let libraryRows = try #require(raw["libraryFiles"] as? [[String: Any]])
        var paths: Set<String> = [
            "/libraryFiles", "/media/audioFiles", "/media/tracks", "/media/chapters", "/media/tags",
            "/media/metadata/authors", "/media/metadata/narrators", "/media/metadata/series", "/media/metadata/genres",
        ]
        for i in 0..<count {
            let file = files[i]
            let track = tracks[i]
            let fileMetadata = try #require(file.metadata)
            #expect(fileMetadata.filename == names[i] && fileMetadata.relPath == names[i])
            #expect(fileMetadata.path == "/audiobooks/Ada Fixture/\(title)/\(names[i])")
            #expect(fileMetadata.ext == (single ? ".m4b" : ".mp3"))
            #expect(try #require(fileMetadata.size) > 0)
            #expect(fileMetadata.mtimeMs != nil && fileMetadata.ctimeMs != nil && fileMetadata.birthtimeMs != nil)
            #expect(inventory[i].fileType == "audio")
            #expect(file.mimeType == (single ? "audio/mp4" : "audio/mpeg"))
            #expect(file.codec == (single ? "aac" : "mp3") && file.channels == 1)
            #expect(file.exclude == false && file.manuallyVerified == false && file.error == nil)
            #expect(track.title == names[i] && track.mimeType == file.mimeType && track.codec == file.codec)
            #expect(track.contentUrl == "/api/items/\(itemID)/file/\(file.ino)")
            #expect(trackRows[i]["ino"] as? String == file.ino)
            #expect(try decode(trackRows[i], as: AudioFile.self) == file)
            for (row, decoded) in [
                (fileRows[i], file.metadata), (trackRows[i], track.metadata), (libraryRows[i], inventory[i].metadata),
            ] {
                let nested = try decode(object(row["metadata"]), as: FileMetadata.self)
                #expect(nested == decoded && nested == fileMetadata)
            }
            let embedded = single ? chapters : []
            #expect(try array(fileRows[i], "chapters", matching: file.chapters) == embedded)
            // AudioTrack has no chapters property; independently decode its complete raw chapter expansion.
            #expect(try array(trackRows[i], "chapters", matching: file.chapters) == embedded)
            paths.formUnion(["/media/audioFiles/\(i)/chapters", "/media/tracks/\(i)/chapters"])
        }
        // A newly present array must be given an explicit strict check, not silently ignored.
        #expect(arrayPaths(raw) == paths)
        let sizes = try files.map { try #require($0.metadata?.size) }
        #expect(book.size == sizes.reduce(0, +) && item.size == book.size)
        for (row, key, expected, decoded) in [
            (raw, "numFiles", count, item.numFiles), (media, "numAudioFiles", count, book.numAudioFiles),
            (media, "numTracks", count, book.numTracks), (media, "numChapters", chapters.count, book.numChapters),
        ] {
            if version == "2.26.0" {
                #expect(row[key] == nil && decoded == nil)  // absent, not null
            } else {
                let number = try #require(row[key] as? NSNumber)
                #expect(CFGetTypeID(number) != CFBooleanGetTypeID())
                #expect(number == NSNumber(value: expected) && decoded == expected)
            }
        }
        let summary = ItemSummary(item: item)
        #expect(summary.id == itemID && summary.itemID == itemID && summary.kind == .book)
        #expect(summary.title == title && summary.hasAudio && !summary.isMissing)
    }

    /// Only these exact JSON paths may change. Synthetic seed paths, all dates and probe fields stay intact.
    private func substitutions(kind: String) -> [String: String] {
        let base = kind == "multifile" ? 1000 : 2000
        var result = [
            "/id": "item-\(kind)", "/ino": "\(base)", "/libraryId": "library-books",
            "/folderId": "folder-books", "/media/id": "book-\(kind)", "/media/libraryItemId": "item-\(kind)",
            "/media/metadata/authors/0/id": "author-fixture",
        ]
        for i in 0..<(kind == "multifile" ? 2 : 1) {
            for prefix in ["/media/audioFiles", "/media/tracks", "/libraryFiles"] {
                result["\(prefix)/\(i)/ino"] = "\(base + i + 1)"
            }
            result["/media/tracks/\(i)/contentUrl"] = "/api/items/item-\(kind)/file/\(base + i + 1)"
        }
        return result
    }

    private func compare(
        _ original: Any, _ fixture: Any, substitutions: [String: String], path: String = ""
    ) throws -> Set<String> {
        if let replacement = substitutions[path] {
            _ = try #require(original as? String)
            #expect(fixture as? String == replacement)
            return [path]
        }
        if let original = original as? [String: Any] {
            let fixture = try object(fixture)
            try #require(Set(original.keys) == Set(fixture.keys))
            return try original.reduce(into: []) {
                $0.formUnion(
                    try compare($1.value, fixture[$1.key]!, substitutions: substitutions, path: path + "/" + $1.key))
            }
        }
        if let original = original as? [Any] {
            let fixture = try #require(fixture as? [Any])
            try #require(original.count == fixture.count)
            return try original.indices.reduce(into: []) {
                $0.formUnion(
                    try compare(original[$1], fixture[$1], substitutions: substitutions, path: path + "/\($1)"))
            }
        }
        if let original = original as? NSNumber {
            let fixture = try #require(fixture as? NSNumber)
            #expect(CFGetTypeID(original) == CFGetTypeID(fixture))
            #expect(original == fixture)
        } else if let original = original as? String {
            #expect(fixture as? String == original)
        } else {
            #expect(original is NSNull && fixture is NSNull)
        }
        return []
    }

    @Test(arguments: ["2.26.0", "2.37.2"], ["multifile", "m4b"])
    func completeCaptures(version: String, kind: String) throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "expanded-item-\(kind)-\(version)", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        try verify(
            fixture, version: version, kind: kind, itemID: "item-\(kind)", libraryID: "library-books",
            mediaID: "book-\(kind)")
        // Optional original-byte verification supplements, never replaces, fixture assertions.
        if let root = ProcessInfo.processInfo.environment["ABS_EXPANDED_BOOK_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: root).appendingPathComponent(version)
            let original = try Data(contentsOf: directory.appendingPathComponent("\(kind).json"))
            let manifest = try object(
                JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))))
            let proof = try object(object(manifest["captures"])[kind])
            #expect(
                proof["sha256"] as? String == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
            let listing = try object(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("listing-book.json"))))
            let rows = try #require(listing["results"] as? [[String: Any]])
            try #require(rows.count == 2)
            let title = kind == "m4b" ? "Single File Tale" : "The Synthetic Tale"
            let matches = try rows.filter { try object(object($0["media"])["metadata"])["title"] as? String == title }
            let listed = try #require(matches.count == 1 ? matches.first : nil)
            try verify(
                original, version: version, kind: kind, itemID: #require(listed["id"] as? String),
                libraryID: #require(listed["libraryId"] as? String),
                mediaID: #require(object(listed["media"])["id"] as? String))
            let changes = substitutions(kind: kind)
            let visited = try compare(
                JSONSerialization.jsonObject(with: original), JSONSerialization.jsonObject(with: fixture),
                substitutions: changes)
            #expect(visited == Set(changes.keys))
        }
    }
}
