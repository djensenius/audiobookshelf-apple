import ABSAPI
import ABSCore
import CoreFoundation
import Foundation
import Testing

@Suite struct LibrarySearchResultsTests {
    private typealias Object = [String: Any]

    private func object(_ value: Any?) throws -> Object {
        try #require(value as? Object)
    }

    private func rows(_ value: Any?) throws -> [Object] {
        try #require(value as? [Object])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func equal<T: Decodable & Equatable>(_ raw: Any, _ expected: T) throws {
        #expect(try decode(T.self, raw) == expected)
    }

    private func array<T: Decodable & Equatable>(_ raw: Any?, _ expected: [T]?) throws -> [Object] {
        let entries = try rows(raw)
        let values = try #require(expected)
        try #require(entries.count == values.count)
        // map throws for every raw element; no lossy container, try?, compactMap or first-hit shortcut.
        #expect(try entries.map { try decode(T.self, $0) } == values)
        return entries
    }

    private func nulls(_ raw: Object, _ keys: [String]) {
        for key in keys { #expect(raw[key] is NSNull) }
    }

    private func integer(_ raw: Any?, _ expected: Int) throws {
        let number = try #require(raw as? NSNumber)
        #expect(CFGetTypeID(number) != CFBooleanGetTypeID())
        #expect(number.doubleValue == Double(expected))
    }

    private func audio(_ raw: Object, _ expected: AudioFile) throws {
        try equal(raw, expected)
        try equal(object(raw["metadata"]), #require(expected.metadata))
        _ = try array(raw["chapters"], expected.chapters)
        try integer(raw["index"], 1)
        try integer(raw["bitRate"], 16_000)
    }

    private func track(_ raw: Object, _ expected: AudioTrack) throws {
        try equal(raw, expected)
        try equal(object(raw["metadata"]), #require(expected.metadata))
        try integer(raw["index"], 1)
        try integer(raw["startOffset"], 0)
    }

    private func episode(_ raw: Object, _ expected: PodcastEpisode) throws {
        #expect(
            Set(raw.keys) == [
                "libraryItemId", "podcastId", "id", "oldEpisodeId", "index", "season", "episode", "episodeType",
                "title", "subtitle", "description", "enclosure", "guid", "pubDate", "chapters", "audioFile",
                "publishedAt", "addedAt", "updatedAt", "audioTrack", "size", "duration",
            ])
        try equal(raw, expected)
        nulls(
            raw,
            [
                "oldEpisodeId", "index", "season", "episode", "episodeType", "subtitle", "description",
                "enclosure", "guid", "pubDate", "publishedAt",
            ])
        _ = try array(raw["chapters"], expected.chapters)
        try audio(object(raw["audioFile"]), #require(expected.audioFile))
        try track(object(raw["audioTrack"]), #require(expected.audioTrack))
        try integer(raw["size"], #require(expected.size))
        try integer(raw["addedAt"], #require(expected.addedAt))
        try integer(raw["updatedAt"], #require(expected.updatedAt))
    }

    private func item(_ raw: Object, _ expected: LibraryItem) throws {
        try equal(raw, expected)
        var keys: Set<String> = [
            "id", "ino", "oldLibraryItemId", "libraryId", "folderId", "path", "relPath", "isFile", "mtimeMs",
            "ctimeMs", "birthtimeMs", "addedAt", "updatedAt", "lastScan", "scanVersion", "isMissing", "isInvalid",
            "mediaType", "media", "libraryFiles",
        ]
        if expected.size != nil { keys.insert("size") }
        if expected.recentEpisode != nil { keys.insert("recentEpisode") }
        #expect(Set(raw.keys) == keys)
        nulls(raw, ["oldLibraryItemId"])
        let files = try array(raw["libraryFiles"], expected.libraryFiles)
        for (row, file) in zip(files, try #require(expected.libraryFiles)) {
            try equal(object(row["metadata"]), #require(file.metadata))
            nulls(row, ["isSupplementary"])
        }
        let media = try object(raw["media"])
        let metadata = try object(media["metadata"])
        nulls(media, ["coverPath"])
        if let book = expected.book {
            try equal(media, book)
            try equal(metadata, book.metadata)
            _ = try array(metadata["authors"], book.metadata.authors)
            _ = try array(metadata["series"], book.metadata.series)
            _ = try array(media["chapters"], book.chapters)
            let audioFiles = try array(media["audioFiles"], book.audioFiles)
            for (row, file) in zip(audioFiles, try #require(book.audioFiles)) { try audio(row, file) }
            if let tracks = book.tracks {
                let entries = try array(media["tracks"], tracks)
                for (row, value) in zip(entries, tracks) { try track(row, value) }
            } else {
                #expect(media["tracks"] == nil && media["duration"] == nil && media["size"] == nil)
                #expect(metadata["titleIgnorePrefix"] == nil && metadata["authorName"] == nil)
                #expect(metadata["seriesName"] == nil && metadata["descriptionPlain"] == nil)
            }
            nulls(media, ["ebookFile"])
            nulls(
                metadata,
                [
                    "subtitle", "publishedYear", "publishedDate", "publisher", "description",
                    "isbn", "asin", "language",
                ])
            // These expanded 2.26.0 results have no minified/expanded count fields.
            for key in ["numTracks", "numAudioFiles", "numChapters", "ebookFormat"] { #expect(media[key] == nil) }
            #expect(raw["series"] == nil)
        } else {
            let podcast = try #require(expected.podcast)
            try equal(media, podcast)
            try equal(metadata, podcast.metadata)
            _ = try array(media["episodes"], podcast.episodes)
            #expect(podcast.episodes == [])
            #expect(media["numEpisodes"] == nil)
            nulls(media, ["lastEpisodeCheck"])
            nulls(
                metadata,
                [
                    "description", "releaseDate", "feedUrl", "imageUrl", "itunesPageUrl",
                    "itunesId", "itunesArtistId", "language",
                ])
            try integer(media["size"], 0)  // Empty wrapper media, not the item's 121046 bytes.
        }
        if let recent = expected.recentEpisode { try episode(object(raw["recentEpisode"]), recent) }
    }

    private func items(_ raw: Any?, _ expected: [LibraryItem]) throws {
        let entries = try rows(raw)
        try #require(entries.count == expected.count)
        for (row, value) in zip(entries, expected) {
            #expect(Set(row.keys) == ["libraryItem"])
            try item(object(row["libraryItem"]), value)
        }
    }

    private func names(_ raw: Any?, _ expected: [LibrarySearchResults.NameMatch], countKey: String) throws {
        let entries = try array(raw, expected)
        for (row, value) in zip(entries, expected) {
            #expect(Set(row.keys) == ["name", countKey])
            #expect(row["name"] as? String == value.name)
            try integer(row[countKey], value.count)
        }
    }

    private func verify(_ data: Data, podcast: Bool, expected e: SearchCaptureExpected) throws {
        let raw = try object(JSONSerialization.jsonObject(with: data))
        let expected = podcast ? e.podcastResults : e.bookResults
        let decoded = try JSONDecoder().decode(LibrarySearchResults.self, from: data)
        #expect(decoded == expected)  // FULL ordered values, including all nested typed fields.
        if podcast {
            #expect(Set(raw.keys) == ["podcast", "episodes", "tags", "genres"])
            try items(raw["podcast"], expected.podcasts)
            try items(raw["episodes"], expected.episodes)
        } else {
            #expect(Set(raw.keys) == ["book", "authors", "series", "narrators", "tags", "genres"])
            try items(raw["book"], expected.books)
            let authors = try array(raw["authors"], expected.authors)
            for (row, value) in zip(authors, expected.authors) {
                #expect(
                    Set(row.keys) == [
                        "id", "asin", "name", "description", "imagePath", "libraryId",
                        "addedAt", "updatedAt", "numBooks",
                    ])
                nulls(row, ["asin", "description", "imagePath"])
                try integer(row["numBooks"], #require(value.numBooks))
            }
            let series = try array(raw["series"], expected.series)
            for (row, value) in zip(series, expected.series) {
                #expect(Set(row.keys) == ["series", "books"])
                let metadata = try object(row["series"])
                #expect(
                    Set(metadata.keys) == [
                        "id", "name", "nameIgnorePrefix", "description",
                        "addedAt", "updatedAt", "libraryId",
                    ])
                nulls(metadata, ["description"])
                try equal(metadata, value.series)
                let members = try array(row["books"], value.books)
                for (member, book) in zip(members, value.books) { try item(member, book) }
            }
            try names(raw["narrators"], expected.narrators, countKey: "numBooks")
        }
        try names(raw["tags"], expected.tags, countKey: "numItems")
        try names(raw["genres"], expected.genres, countKey: "numItems")
    }

    @Test func complete226CapturesRetainEveryRowAndNestedValue() throws {
        for podcast in [false, true] {
            let kind = podcast ? "podcast" : "book"
            let url = try #require(
                Bundle.module.url(forResource: "search-\(kind)-2.26.0", withExtension: "json", subdirectory: "Fixtures")
            )
            try verify(Data(contentsOf: url), podcast: podcast, expected: SearchCaptureExpected())
        }
        // Optional ADDITIONAL evidence: never replaces the bundled fixture checks.
        if let path = ProcessInfo.processInfo.environment["ABS_SEARCH_RESPONSE_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: path).appendingPathComponent("2.26.0")
            let ledgerData = try Data(contentsOf: root.appendingPathComponent("26-verified-ledger.json"))
            let expected = try SearchCaptureExpected(originalLedger: ledgerData)
            for (podcast, name) in [(false, "27-book-search.json"), (true, "28-podcast-search.json")] {
                try verify(Data(contentsOf: root.appendingPathComponent(name)), podcast: podcast, expected: expected)
            }
        }
    }
}

/// Values transcribed from independent item/author/series detail reads and the verified ledger.
/// Only the wire projection/order comes from search. No production model is re-encoded as a fixture.
private struct SearchCaptureExpected {
    private var identities: [String: String] = [:]
    private var token = "Search Fixture"

    init() {}

    private func id(_ value: String) -> String { identities[value] ?? value }
    private func name(_ suffix: String) -> String { "\(token) \(suffix)" }

    private struct Ledger: Decodable {
        let books: [LibraryItem]
        let podcast: LibraryItem
        let authors: [Author]
        let series: [Series]
        let bookLibrary: String
        let podcastLibrary: String
        let token: String
    }

    init(originalLedger data: Data) throws {
        let ledger = try JSONDecoder().decode(Ledger.self, from: data)
        token = ledger.token
        try #require(ledger.books.count == 2 && ledger.authors.count == 2 && ledger.series.count == 2)
        identities = ["library-books": ledger.bookLibrary, "library-podcasts": ledger.podcastLibrary]
        for (offset, book) in ledger.books.enumerated() {
            identities["item-book-\(offset + 1)"] = book.id
            identities["book-\(offset + 1)"] = try #require(book.book?.id)
            let folderID: String = try #require(book.folderId)
            identities["folder-books"] = folderID
        }
        identities["item-podcast"] = ledger.podcast.id
        identities["podcast"] = try #require(ledger.podcast.podcast?.id)
        let podcastFolderID: String = try #require(ledger.podcast.folderId)
        identities["folder-podcasts"] = podcastFolderID
        let episodes = try #require(ledger.podcast.podcast?.episodes)
        try #require(episodes.count == 2)
        for (offset, episode) in episodes.enumerated() { identities["episode-\(offset + 1)"] = episode.id }
        for role in ["Shared", "Unique"] {
            identities["author-\(role.lowercased())"] = try #require(
                ledger.authors.first { $0.name == name("\(role) Author") }
            ).id
            identities["series-\(role.lowercased())"] = try #require(
                ledger.series.first { $0.name == name("\(role) Series") }
            ).id
        }
        #expect(ledger.books == [book(1, detail: true), book(2, detail: true)])
        #expect(ledger.podcast == podcast(detail: true))
        #expect(ledger.authors == [author("Shared", detail: true), author("Unique", detail: true)])
        #expect(ledger.series == [series("Unique"), series("Shared")])
    }

    private func file(_ index: Int) -> AudioFile {
        let names = ["First.mp3", "Second.mp3", name("Episode 1.mp3"), name("Episode 2.mp3")]
        let paths = ["books/First", "books/Second", "casts/Owned Cast", "casts/Owned Cast"]
        let inos = ["65036", "65034", "65030", "65031"]
        let sizes = [60498, 80516, 40507, 80539]
        let modified: [Double] = [1794362580494, 1794362580587, 1794362580651, 1794362580748]
        let added = [1794362655220, 1794362655139, 1794362655444, 1794362655444]
        return AudioFile(
            index: 1, ino: inos[index],
            metadata: FileMetadata(
                filename: names[index], ext: ".mp3", path: "/search-fixtures/\(paths[index])/\(names[index])",
                relPath: names[index], size: sizes[index], mtimeMs: modified[index], ctimeMs: modified[index],
                birthtimeMs: 0),
            addedAt: added[index], updatedAt: added[index], manuallyVerified: false, exclude: false,
            format: "MP2/3 (MPEG audio layer 2/3)", duration: [30.096, 40.104, 20.088, 40.104][index],
            bitRate: 16_000, codec: "mp3", channels: 1, channelLayout: "mono", chapters: [], mimeType: "audio/mpeg")
    }

    private func track(_ index: Int) -> AudioTrack {
        let file = file(index)
        let itemID = id(index < 2 ? "item-book-\(index + 1)" : "item-podcast")
        return AudioTrack(
            index: 1, startOffset: 0, duration: file.duration!, title: file.metadata!.filename,
            contentUrl: "/api/items/\(itemID)/file/\(file.ino)", mimeType: "audio/mpeg", codec: "mp3",
            metadata: file.metadata)
    }

    private func libraryFile(_ index: Int) -> LibraryFile {
        let file = file(index)
        let added = [1794362655007, 1794362655006, 1794362655412, 1794362655411][index]
        return LibraryFile(
            ino: file.ino, metadata: file.metadata, fileType: "audio", addedAt: added, updatedAt: added)
    }

    private func author(_ role: String, detail: Bool = false) -> Author {
        let time = role == "Shared" ? 1794362655146 : 1794362655569
        return Author(
            id: id("author-\(role.lowercased())"), name: name("\(role) Author"), libraryId: id("library-books"),
            addedAt: time, updatedAt: time, numBooks: detail ? nil : (role == "Shared" ? 2 : 1))
    }

    private func series(_ role: String) -> Series {
        let time = role == "Shared" ? 1794362655554 : 1794362655562
        return Series(
            id: id("series-\(role.lowercased())"), name: name("\(role) Series"),
            nameIgnorePrefix: name("\(role) Series"), libraryId: id("library-books"), addedAt: time, updatedAt: time)
    }

    private func book(_ number: Int, member: Bool = false, detail: Bool = false) -> LibraryItem {
        let first = number == 1
        // Detail series membership is shared/unique; expanded search series are unique/shared.
        let authorRoles = first ? ["Shared", "Unique"] : ["Shared"]
        let roles = first ? (detail ? ["Shared", "Unique"] : ["Unique", "Shared"]) : ["Shared"]
        let associations = roles.map {
            Series(
                id: id("series-\($0.lowercased())"), name: name("\($0) Series"),
                sequence: $0 == "Unique" ? "7" : "\(number)")
        }
        let narrators = (first ? ["Shared", "Unique"] : ["Shared"]).map { name("\($0) Narrator") }
        let metadata = BookMetadata(
            title: name("Book \(number)"), titleIgnorePrefix: member ? nil : name("Book \(number)"),
            authors: member
                ? [] : authorRoles.map { Author(id: id("author-\($0.lowercased())"), name: name("\($0) Author")) },
            narrators: narrators, series: member ? [] : associations,
            genres: (first ? ["Shared", "Unique"] : ["Shared"]).map { name("\($0) Genre") },
            explicit: false, abridged: false,
            authorName: member ? nil : authorRoles.map { name("\($0) Author") }.joined(separator: ", "),
            authorNameLF: member ? nil : authorRoles.map { "Author, \(token) \($0)" }.joined(separator: ", "),
            narratorName: member ? nil : narrators.joined(separator: ", "),
            seriesName: member ? nil : associations.map { "\($0.name) #\($0.sequence!)" }.joined(separator: ", "))
        let audio = file(number - 1)
        let media = Book(
            id: id("book-\(number)"), libraryItemId: id("item-book-\(number)"), metadata: metadata,
            tags: (first ? ["Shared", "Unique"] : ["Shared"]).map { name("\($0) Tag") },
            audioFiles: [audio], chapters: [], tracks: member ? nil : [track(number - 1)],
            duration: member ? nil : audio.duration, size: member ? nil : audio.metadata!.size)
        return LibraryItem(
            id: id("item-book-\(number)"), ino: first ? "65035" : "65033", libraryId: id("library-books"),
            folderId: id("folder-books"), path: "/search-fixtures/books/\(first ? "First" : "Second")",
            relPath: first ? "First" : "Second", isFile: false,
            mtimeMs: first ? 1794362580454 : 1794362580529, ctimeMs: first ? 1794362580454 : 1794362580529,
            birthtimeMs: 0, addedAt: first ? 1794362655222 : 1794362655140,
            updatedAt: first ? 1794362655578 : 1794362655599, lastScan: first ? 1794362655220 : 1794362655139,
            scanVersion: "2.26.0", mediaType: .book, media: .book(media), libraryFiles: [libraryFile(number - 1)],
            size: member ? nil : audio.metadata!.size)
    }

    private func episode(_ number: Int) -> PodcastEpisode {
        let audio = file(number + 1)
        let time = 1794362655450
        return PodcastEpisode(
            id: id("episode-\(number)"), libraryItemId: id("item-podcast"), podcastId: id("podcast"),
            title: name("Episode \(number)"), chapters: [], audioFile: audio, audioTrack: track(number + 1),
            addedAt: time, updatedAt: time, duration: audio.duration, size: audio.metadata!.size)
    }

    private func podcast(recent: Int? = nil, detail: Bool = false) -> LibraryItem {
        let media = Podcast(
            id: id("podcast"), libraryItemId: id("item-podcast"),
            metadata: PodcastMetadata(
                title: name("Podcast"), titleIgnorePrefix: name("Podcast"), author: "Owned Cast",
                genres: [name("Podcast Genre")], explicit: false, type: "episodic"),
            tags: [name("Podcast Tag")], episodes: detail ? [episode(1), episode(2)] : [],
            autoDownloadEpisodes: false, autoDownloadSchedule: "0 * * * *", maxEpisodesToKeep: 0,
            maxNewEpisodesToDownload: 3, size: detail ? 121046 : 0)
        return LibraryItem(
            id: id("item-podcast"), ino: "65029", libraryId: id("library-podcasts"), folderId: id("folder-podcasts"),
            path: "/search-fixtures/casts/Owned Cast", relPath: "Owned Cast", isFile: false,
            mtimeMs: 1794362580691, ctimeMs: 1794362580691, birthtimeMs: 0, addedAt: 1794362655445,
            updatedAt: 1794362655639, lastScan: 1794362655444, scanVersion: "2.26.0", mediaType: .podcast,
            media: .podcast(media), libraryFiles: [libraryFile(2), libraryFile(3)], size: 121046,
            recentEpisode: recent.map { episode($0) })
    }

    private func names(_ kind: String) -> [LibrarySearchResults.NameMatch] {
        [.init(name: name("Shared \(kind)"), count: 2), .init(name: name("Unique \(kind)"), count: 1)]
    }

    var bookResults: LibrarySearchResults {
        LibrarySearchResults(
            books: [book(2), book(1)],
            series: [
                .init(series: series("Shared"), books: [book(1, member: true), book(2, member: true)]),
                .init(series: series("Unique"), books: [book(1, member: true)]),
            ],
            authors: [author("Shared"), author("Unique")], narrators: names("Narrator"),
            tags: names("Tag"), genres: names("Genre"))
    }

    var podcastResults: LibrarySearchResults {
        LibrarySearchResults(
            podcasts: [podcast()], episodes: [podcast(recent: 1), podcast(recent: 2)],
            tags: [.init(name: name("Podcast Tag"), count: 1)],
            genres: [.init(name: name("Podcast Genre"), count: 1)])
    }
}
