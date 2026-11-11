import ABSAPI
import ABSCore
import Foundation
import Testing

/// #258 positives are distinct from the scan-primed discrepancy; #263 remains unmet.
enum SearchFilterRaw {
    static func names(_ token: String, _ kind: String, unique: Bool = true) -> [String] {
        ["\(token) Shared \(kind)"] + (unique ? ["\(token) Unique \(kind)"] : [])
    }

    static func members(_ actual: [String], _ expected: [String]) throws {
        try #require(actual.count == Set(actual).count)
        try #require(expected.count == Set(expected).count)
        try #require(actual.count == expected.count)
        try #require(Set(actual) == Set(expected))
    }

    static func strict(_ raw: [String: Any]) throws -> LibraryFilterData {
        try #require(
            Set(raw.keys) == [
                "authors", "series", "narrators", "genres", "tags", "languages", "publishers",
                "publishedDecades", "bookCount", "authorCount", "seriesCount", "podcastCount", "numIssues", "loadedAt",
            ])
        let value = try SearchRaw.decode(LibraryFilterData.self, raw)
        let authors = try SearchRaw.rows(raw["authors"])
        let series = try SearchRaw.rows(raw["series"])
        for rows in [authors, series] {
            for row in rows {
                try #require(Set(row.keys) == ["id", "name"])
                _ = try SearchRaw.string(row, "id")
                _ = try SearchRaw.string(row, "name")
            }
            try #require(Set(try rows.map { try SearchRaw.string($0, "id") }).count == rows.count)
            try #require(Set(try rows.map { try SearchRaw.string($0, "name") }).count == rows.count)
        }
        // Every raw element, complete modeled values, exact original order. No lossy oracle.
        #expect(value.authors == (try authors.map { try SearchRaw.decode(Author.self, $0) }))
        #expect(value.series == (try series.map { try SearchRaw.decode(Series.self, $0) }))
        for (key, decoded) in [
            ("narrators", value.narrators), ("genres", value.genres), ("tags", value.tags),
            ("languages", value.languages), ("publishers", value.publishers),
            ("publishedDecades", value.publishedDecades),
        ] {
            let complete = try #require(raw[key] as? [String])
            try #require(complete.allSatisfy { !$0.isEmpty })
            try #require(Set(complete).count == complete.count)
            #expect(decoded == complete)
        }
        for key in ["bookCount", "authorCount", "seriesCount", "podcastCount", "numIssues"] {
            #expect(try SearchRaw.integer(raw, key) == 0)  // Cache markers, not DB totals.
        }
        let loadedAt = try SearchRaw.integer(raw, "loadedAt")
        try #require(loadedAt > 1_000_000_000_000)
        #expect(value.loadedAt == loadedAt)  // Int? in milliseconds, not Date/seconds.
        #expect(value.numIssues == (try SearchRaw.integer(raw, "numIssues")))
        return value
    }

    static func declared(_ ledger: SearchLedger) throws {
        try #require(ledger.books.count == 2)
        for (offset, item) in ledger.books.enumerated() {
            let book = try #require(item.book)
            let unique = offset == 0
            let metadata = book.metadata
            #expect(metadata.title == "\(ledger.token) Book \(offset + 1)")
            try members(try #require(metadata.authors).map(\.name), names(ledger.token, "Author", unique: unique))
            try members(try #require(metadata.series).map(\.name), names(ledger.token, "Series", unique: unique))
            try members(try #require(metadata.narrators), names(ledger.token, "Narrator", unique: unique))
            try members(try #require(metadata.genres), names(ledger.token, "Genre", unique: unique))
            try members(try #require(book.tags), names(ledger.token, "Tag", unique: unique))
            #expect(metadata.publisher == (unique ? "First Publisher" : "Second Publisher"))
            #expect(metadata.language == (unique ? "en" : "fr"))
            #expect(metadata.publishedYear == (unique ? "1984" : "2007"))
        }
        try members(ledger.authors.map(\.name), names(ledger.token, "Author"))
        try members(ledger.series.map(\.name), names(ledger.token, "Series"))
        let podcast = try #require(ledger.podcast.podcast)
        #expect(podcast.metadata.language == "de")
        #expect(podcast.metadata.genres == ["\(ledger.token) Podcast Genre"])
        #expect(podcast.tags == ["\(ledger.token) Podcast Tag"])
    }

    static func positivePair(
        wrapper: Data, dedicated: Data, ledger: SearchLedger, podcast: Bool, version: String, folder: String
    ) throws -> LibraryWithFilterData {
        try declared(ledger)
        let raw = try SearchRaw.object(wrapper)
        var keys: Set<String> = ["library", "filterdata", "issues", "numUserPlaylists"]
        if version == "2.26.0" { keys.insert("customMetadataProviders") }
        try #require(Set(raw.keys) == keys)
        if version == "2.26.0" {
            #expect(try SearchRaw.rows(raw["customMetadataProviders"]).isEmpty)
        }
        let filters = try SearchRaw.dictionary(raw["filterdata"])
        let value = try strict(filters)
        let other = try strict(SearchRaw.object(dedicated))
        #expect(try SearchRaw.equalJSON(JSONSerialization.data(withJSONObject: filters), dedicated))
        #expect(value == other)
        let decoded = try JSONDecoder().decode(LibraryWithFilterData.self, from: wrapper)
        #expect(decoded.filterData == value)
        #expect(decoded.filterData != LibraryFilterData())
        #expect(decoded.issues == (try SearchRaw.integer(raw, "issues")))
        #expect(decoded.numUserPlaylists == (try SearchRaw.integer(raw, "numUserPlaylists")))
        #expect(decoded.issues == 0 && decoded.numUserPlaylists == 0)
        let library = try SearchRaw.dictionary(raw["library"])
        #expect(decoded.library == (try SearchRaw.decode(Library.self, library)))
        #expect(decoded.library.id == (podcast ? ledger.podcastLibrary : ledger.bookLibrary))
        #expect(decoded.library.name == "\(ledger.token) \(podcast ? "podcast" : "book")")
        #expect(decoded.library.mediaType == (podcast ? .podcast : .book))
        let folders = try #require(decoded.library.folders)
        try #require(folders.count == 1)
        #expect(folders[0].fullPath == folder)  // Harness-visible root, Docker or Node.
        #expect(folders[0].libraryId == decoded.library.id)
        #expect(decoded.library.lastScanVersion == version)
        #expect(try #require(value.loadedAt) <= SearchRaw.integer(library, "lastScan"))
        if podcast {
            try members(value.tags, ["\(ledger.token) Podcast Tag"])
            try members(value.genres, ["\(ledger.token) Podcast Genre"])
            #expect(value.authors == [] && value.series == [] && value.narrators == [])
            #expect(value.publishers == [] && value.publishedDecades == [])
            // Deliberately no positive-language success assertion here. #263 stays open.
        } else {
            try members(value.authors.map(\.id), ledger.authors.map(\.id))
            try members(value.authors.map(\.name), names(ledger.token, "Author"))
            try members(value.series.map(\.id), ledger.series.map(\.id))
            try members(value.series.map(\.name), names(ledger.token, "Series"))
            try members(value.narrators, names(ledger.token, "Narrator"))
            try members(value.genres, names(ledger.token, "Genre"))
            try members(value.tags, names(ledger.token, "Tag"))
            try members(value.languages, ["en", "fr"])
            try members(value.publishers, ["First Publisher", "Second Publisher"])
            try members(value.publishedDecades, ["1980", "2000"])
        }
        return decoded
    }

    static func inventory(_ raw: [String: Any], item: LibraryItem, token: String) throws {
        let rows = try SearchRaw.rows(raw["libraryFiles"])
        #expect(item.libraryFiles == (try rows.map { try SearchRaw.decode(LibraryFile.self, $0) }))
        let expected: [String]
        let sidecarSize: Int
        if item.mediaType == .book {
            let name = try #require(item.relPath)
            try #require(name == "First" || name == "Second")
            expected = ["\(name).mp3", "metadata.json"]
            sidecarSize = name == "First" ? 335 : 221
        } else {
            try #require(item.mediaType == .podcast)
            expected = ["\(token) Episode 1.mp3", "\(token) Episode 2.mp3", "metadata.json"]
            sidecarSize = 114
        }
        var filenames: [String] = []
        var total = 0
        var audioSize = 0
        for row in rows {
            let metadata = try SearchRaw.dictionary(row["metadata"])
            let filename = try SearchRaw.string(metadata, "filename")
            filenames.append(filename)
            let size = try SearchRaw.integer(metadata, "size")
            try #require(size > 0)
            total += size
            if filename == "metadata.json" {
                #expect(row["fileType"] as? String == "metadata")
                #expect(size == sidecarSize)
            } else {
                #expect(row["fileType"] as? String == "audio")
                audioSize += size
            }
        }
        try members(filenames, expected)
        #expect(try SearchRaw.integer(raw, "size") == total)
        #expect(try SearchRaw.integer(SearchRaw.dictionary(raw["media"]), "size") == audioSize)
    }
}
