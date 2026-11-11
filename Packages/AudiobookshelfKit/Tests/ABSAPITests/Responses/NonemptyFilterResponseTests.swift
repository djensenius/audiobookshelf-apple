import ABSAPI
import ABSCore
import CoreFoundation
import CryptoKit
import Foundation
import Testing

/// Complete genuine HTTP bodies. #263's positive podcast-language requirement is NOT covered.
@Suite struct NonemptyFilterResponseTests {
    private let fixtureToken = "search0000000000000258"

    private func object(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    private func raw(_ data: Data) throws -> [String: Any] {
        try object(JSONSerialization.jsonObject(with: data))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func integer(_ value: Any?) throws -> Int {
        let number = try #require(value as? NSNumber)
        try #require(CFGetTypeID(number) != CFBooleanGetTypeID())
        try #require(number.doubleValue == Double(number.intValue))
        return number.intValue
    }

    private func boolean(_ value: Any?) throws -> Bool {
        let number = try #require(value as? NSNumber)
        try #require(CFGetTypeID(number) == CFBooleanGetTypeID())
        return number.boolValue
    }

    private func strings(_ value: Any?) throws -> [String] {
        let values = try #require(value as? [String])
        try #require(values.allSatisfy { !$0.isEmpty })
        try #require(values.count == Set(values).count)
        return values
    }

    private func members(_ values: [String], _ expected: [String]) throws {
        try #require(values.count == Set(values).count)
        try #require(values.count == expected.count)
        try #require(Set(values) == Set(expected))
    }

    private func names(_ token: String, _ kind: String, unique: Bool = true) -> [String] {
        ["\(token) Shared \(kind)"] + (unique ? ["\(token) Unique \(kind)"] : [])
    }

    private func fixture(_ version: String, _ kind: String, _ shape: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "filter-\(kind)-\(shape)-\(version)", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func strict(_ raw: [String: Any]) throws -> LibraryFilterData {
        try #require(
            Set(raw.keys) == [
                "authors", "series", "narrators", "genres", "tags", "languages", "publishers", "publishedDecades",
                "bookCount", "authorCount", "seriesCount", "podcastCount", "numIssues", "loadedAt",
            ])
        let result = try decode(LibraryFilterData.self, raw)
        let authors = try #require(raw["authors"] as? [[String: Any]])
        let series = try #require(raw["series"] as? [[String: Any]])
        for rows in [authors, series] {
            for row in rows {
                try #require(Set(row.keys) == ["id", "name"])
                try #require(!(try #require(row["id"] as? String)).isEmpty)
                try #require(!(try #require(row["name"] as? String)).isEmpty)
            }
            try #require(Set(try rows.map { try #require($0["id"] as? String) }).count == rows.count)
            try #require(Set(try rows.map { try #require($0["name"] as? String) }).count == rows.count)
        }
        #expect(result.authors == (try authors.map { try decode(Author.self, $0) }))
        #expect(result.series == (try series.map { try decode(Series.self, $0) }))
        for (key, values) in [
            ("narrators", result.narrators), ("genres", result.genres), ("tags", result.tags),
            ("languages", result.languages), ("publishers", result.publishers),
            ("publishedDecades", result.publishedDecades),
        ] {
            #expect(values == (try strings(raw[key])))  // Exact wire order and every valid element.
        }
        for key in ["bookCount", "authorCount", "seriesCount", "podcastCount", "numIssues"] {
            #expect(try integer(raw[key]) == 0)  // Observed scan-primed markers, not DB totals.
        }
        let loadedAt = try integer(raw["loadedAt"])
        try #require(loadedAt > 1_000_000_000_000)
        #expect(result.loadedAt == loadedAt)
        #expect(result.numIssues == (try integer(raw["numIssues"])))
        return result
    }

    private func library(
        _ raw: [String: Any], version: String, kind: String, token: String,
        libraryID: String, folderID: String, folderPath: String
    ) throws -> Library {
        try #require(
            Set(raw.keys) == [
                "id", "name", "folders", "displayOrder", "icon", "mediaType", "provider", "settings",
                "lastScan", "lastScanVersion", "createdAt", "lastUpdate",
            ])
        let decoded = try decode(Library.self, raw)
        #expect(decoded.id == libraryID)
        #expect(decoded.name == "\(token) \(kind)")
        #expect(raw["id"] as? String == libraryID)
        #expect(raw["name"] as? String == "\(token) \(kind)")
        #expect(raw["mediaType"] as? String == kind)
        #expect(decoded.mediaType == (kind == "book" ? .book : .podcast))
        #expect(raw["icon"] as? String == "database")
        #expect(raw["provider"] as? String == "google")
        #expect(try integer(raw["displayOrder"]) == (kind == "book" ? 3 : 4))
        #expect(decoded.icon == "database")
        #expect(decoded.provider == "google")
        #expect(decoded.displayOrder == (kind == "book" ? 3 : 4))
        let folders = try #require(raw["folders"] as? [[String: Any]])
        try #require(folders.count == 1)
        try #require(Set(folders[0].keys) == ["id", "libraryId", "fullPath", "addedAt"])
        #expect(folders[0]["id"] as? String == folderID)
        #expect(folders[0]["libraryId"] as? String == libraryID)
        #expect(folders[0]["fullPath"] as? String == folderPath)
        #expect(try integer(folders[0]["addedAt"]) > 1_000_000_000_000)
        #expect(decoded.folders == (try folders.map { try decode(LibraryFolder.self, $0) }))
        let settings = try object(raw["settings"])
        var keys: Set<String> = [
            "coverAspectRatio", "disableWatcher", "autoScanCronExpression",
            "markAsFinishedPercentComplete", "markAsFinishedTimeRemaining",
        ]
        if kind == "book" {
            let flags = [
                "skipMatchingMediaWithAsin", "skipMatchingMediaWithIsbn", "audiobooksOnly",
                "epubsAllowScriptedContent", "hideSingleBookSeries", "onlyShowLaterBooksInContinueSeries",
            ]
            keys.formUnion(flags + ["metadataPrecedence"])
            for flag in flags { #expect(try boolean(settings[flag]) == false) }
            #expect(
                try strings(settings["metadataPrecedence"]) == [
                    "folderStructure", "audioMetatags", "nfoFile", "txtFiles", "opfFile", "absMetadata",
                ])
        } else {
            keys.insert("podcastSearchRegion")
            #expect(settings["podcastSearchRegion"] as? String == "us")
        }
        try #require(Set(settings.keys) == keys)
        #expect(try integer(settings["coverAspectRatio"]) == 1)
        #expect(try boolean(settings["disableWatcher"]) == true)
        #expect(settings["autoScanCronExpression"] is NSNull)
        #expect(settings["markAsFinishedPercentComplete"] is NSNull)
        #expect(try integer(settings["markAsFinishedTimeRemaining"]) == 10)
        #expect(decoded.settings == (try decode(LibrarySettings.self, settings)))
        for (key, timestamp) in [
            ("lastScan", decoded.lastScan), ("createdAt", decoded.createdAt), ("lastUpdate", decoded.lastUpdate),
        ] {
            let wire = try integer(raw[key])
            #expect(wire > 1_000_000_000_000)
            #expect(timestamp == wire)
        }
        #expect(raw["lastScanVersion"] as? String == version)
        #expect(decoded.lastScanVersion == version)
        return decoded
    }

    private func positivePair(
        _ wrapper: Data, _ dedicated: Data, version: String, kind: String, token: String,
        libraryID: String, folderID: String, folderPath: String,
        authors: [String: String], series: [String: String]
    ) throws -> LibraryWithFilterData {
        let rawWrapper = try raw(wrapper)
        var keys: Set<String> = ["library", "filterdata", "issues", "numUserPlaylists"]
        if version == "2.26.0" { keys.insert("customMetadataProviders") }
        try #require(Set(rawWrapper.keys) == keys)
        if version == "2.26.0" {
            #expect(try #require(rawWrapper["customMetadataProviders"] as? [Any]).isEmpty)
        }
        let rawFilter = try object(rawWrapper["filterdata"])
        let value = try strict(rawFilter)
        let other = try strict(raw(dedicated))
        #expect(NSDictionary(dictionary: rawFilter) == NSDictionary(dictionary: try raw(dedicated)))
        #expect(value == other)
        let response = try JSONDecoder().decode(LibraryWithFilterData.self, from: wrapper)
        #expect(response.filterData == value)
        #expect(response.filterData != LibraryFilterData())  // Wrapper fallback cannot pass.
        #expect(response.issues == (try integer(rawWrapper["issues"])))
        #expect(response.numUserPlaylists == (try integer(rawWrapper["numUserPlaylists"])))
        #expect(response.issues == 0 && response.numUserPlaylists == 0)
        #expect(
            response.library
                == (try library(
                    object(rawWrapper["library"]), version: version, kind: kind, token: token,
                    libraryID: libraryID, folderID: folderID, folderPath: folderPath)))
        #expect(try #require(value.loadedAt) <= #require(response.library.lastScan))
        if kind == "book" {
            try members(value.authors.map(\.id), Array(authors.keys))
            try members(value.series.map(\.id), Array(series.keys))
            for author in value.authors { #expect(authors[author.id] == author.name) }
            for entry in value.series { #expect(series[entry.id] == entry.name) }
            try members(value.authors.map(\.name), names(token, "Author"))
            try members(value.series.map(\.name), names(token, "Series"))
            try members(value.narrators, names(token, "Narrator"))
            try members(value.genres, names(token, "Genre"))
            try members(value.tags, names(token, "Tag"))
            try members(value.languages, ["en", "fr"])
            try members(value.publishers, ["First Publisher", "Second Publisher"])
            try members(value.publishedDecades, ["1980", "2000"])
        } else {
            try members(value.genres, ["\(token) Podcast Genre"])
            try members(value.tags, ["\(token) Podcast Tag"])
            #expect(value.authors == [] && value.series == [] && value.narrators == [])
            #expect(value.publishers == [] && value.publishedDecades == [])
            // Language is structurally checked above, not claimed as a nonempty positive.
        }
        return response
    }

    @Test(arguments: ["2.26.0", "2.37.2"], ["book", "podcast"])
    func completeBodiesPreservePositiveGroupsAndOrderedDTOs(version: String, kind: String) throws {
        _ = try positivePair(
            fixture(version, kind, "wrapper"), fixture(version, kind, "dedicated"),
            version: version, kind: kind, token: fixtureToken,
            libraryID: "filter-library-\(kind)", folderID: "filter-folder-\(kind)",
            folderPath: "/search-fixtures/\(kind == "book" ? "books" : "casts")",
            authors: [
                "filter-author-shared": "\(fixtureToken) Shared Author",
                "filter-author-unique": "\(fixtureToken) Unique Author",
            ],
            series: [
                "filter-series-shared": "\(fixtureToken) Shared Series",
                "filter-series-unique": "\(fixtureToken) Unique Series",
            ])
        // Optional original verification supplements, never substitutes for the bundled assertions.
        if let root = ProcessInfo.processInfo.environment["ABS_FILTER_CAPTURE_DIR"] {
            try original(URL(fileURLWithPath: root).appendingPathComponent(version), version: version, kind: kind)
        }
    }

    @Test(
        "CHARACTERIZATION: stored scan-primed podcast languages omit declared de; #263 remains unmet",
        arguments: ["2.26.0", "2.37.2"])
    func scanPrimedPodcastLanguageDiscrepancy(version: String) throws {
        let wrapper = try raw(fixture(version, "podcast", "wrapper"))
        let cached = try strict(object(wrapper["filterdata"]))
        let dedicated = try strict(raw(fixture(version, "podcast", "dedicated")))
        #expect(cached == dedicated)
        let declaredItemLanguage = "de"  // Verified live and against original expanded reads during capture.
        #expect(cached.languages == [])
        #expect(!cached.languages.contains(declaredItemLanguage))
        // This is NOT a successful positive-language assertion, nor a cold-query/unsupported-dimension claim.
        if let root = ProcessInfo.processInfo.environment["ABS_FILTER_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: root).appendingPathComponent(version)
            let manifest = try raw(Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            let token = try #require(manifest["token"] as? String)
            for name in ["podcast-before", "podcast-after"] {
                let item = try originalItem(directory, name: name, manifest: manifest, token: token)
                #expect(item.podcast?.metadata.language == declaredItemLanguage)
            }
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func originalItem(
        _ directory: URL, name: String, manifest: [String: Any], token: String
    ) throws -> LibraryItem {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let proof = try object(object(manifest["items"])[name])
        #expect(digest(data) == proof["sha256"] as? String)
        let wire = try raw(data)
        let item = try JSONDecoder().decode(LibraryItem.self, from: data)
        let media = try object(wire["media"])
        let metadata = try object(media["metadata"])
        let podcast = name.hasPrefix("podcast")
        let before = name.hasSuffix("before")
        let unique = name.hasPrefix("first")
        let title =
            podcast
            ? (before ? "Owned Cast" : "\(token) Podcast")
            : (before ? (unique ? "First" : "Second") : "\(token) Book \(unique ? 1 : 2)")
        #expect(metadata["title"] as? String == title)
        let tags = podcast ? ["\(token) Podcast Tag"] : names(token, "Tag", unique: unique)
        try members(strings(media["tags"]), tags)
        try members(
            strings(metadata["genres"]), podcast ? ["\(token) Podcast Genre"] : names(token, "Genre", unique: unique))
        #expect(metadata["language"] as? String == (podcast ? "de" : (unique ? "en" : "fr")))
        if podcast {
            #expect(item.podcast == (try decode(Podcast.self, media)))
            let episodes = try #require(media["episodes"] as? [[String: Any]])
            try #require(episodes.count == 2)
            #expect(item.podcast?.episodes == (try episodes.map { try decode(PodcastEpisode.self, $0) }))
            for key in ["authors", "series", "narrators", "publisher", "publishedYear"] {
                #expect(metadata[key] == nil)
            }
        } else {
            #expect(item.book == (try decode(Book.self, media)))
            let authors = try #require(metadata["authors"] as? [[String: Any]])
            let series = try #require(metadata["series"] as? [[String: Any]])
            #expect(item.book?.metadata.authors == (try authors.map { try decode(Author.self, $0) }))
            #expect(item.book?.metadata.series == (try series.map { try decode(Series.self, $0) }))
            try members(
                try authors.map { try #require($0["name"] as? String) },
                names(token, "Author", unique: !before && unique))
            try members(
                try series.map { try #require($0["name"] as? String) },
                before ? [] : names(token, "Series", unique: unique))
            for entry in series {
                let shared = entry["name"] as? String == "\(token) Shared Series"
                #expect(entry["sequence"] as? String == (shared ? (unique ? "1" : "2") : "7"))
            }
            try members(strings(metadata["narrators"]), names(token, "Narrator", unique: unique))
            #expect(metadata["publisher"] as? String == (unique ? "First Publisher" : "Second Publisher"))
            #expect(metadata["publishedYear"] as? String == (unique ? "1984" : "2007"))
        }
        let files = try #require(wire["libraryFiles"] as? [[String: Any]])
        #expect(item.libraryFiles == (try files.map { try decode(LibraryFile.self, $0) }))
        let expected =
            podcast
            ? ["\(token) Episode 1.mp3", "\(token) Episode 2.mp3", "metadata.json"]
            : [unique ? "First.mp3" : "Second.mp3", "metadata.json"]
        try members(try files.map { try #require(object($0["metadata"])["filename"] as? String) }, expected)
        var size = 0
        var audioSize = 0
        for file in files {
            let fileMetadata = try object(file["metadata"])
            let bytes = try integer(fileMetadata["size"])
            size += bytes
            if fileMetadata["filename"] as? String == "metadata.json" {
                #expect(bytes == (podcast ? 114 : (unique ? 335 : 221)))
                #expect(file["fileType"] as? String == "metadata")
            } else {
                #expect(file["fileType"] as? String == "audio")
                audioSize += bytes
            }
        }
        #expect(try integer(wire["size"]) == size)
        #expect(try integer(media["size"]) == audioSize)
        return item
    }

    private func original(_ directory: URL, version: String, kind: String) throws {
        let manifest = try raw(Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let token = try #require(manifest["token"] as? String)
        var books: [LibraryItem] = []
        for name in ["first-before", "second-before", "first-after", "second-after"] {
            let item = try originalItem(directory, name: name, manifest: manifest, token: token)
            if name.hasSuffix("after") { books.append(item) }
        }
        _ = try originalItem(directory, name: "podcast-before", manifest: manifest, token: token)
        let podcast = try originalItem(directory, name: "podcast-after", manifest: manifest, token: token)
        var authors: [String: String] = [:]
        var series: [String: String] = [:]
        for book in books {
            for author in try #require(book.book?.metadata.authors) { authors[author.id] = author.name }
            for entry in try #require(book.book?.metadata.series) { series[entry.id] = entry.name }
        }
        let item = kind == "book" ? books[0] : podcast
        let path = try #require(item.path)
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let wrapper = try Data(contentsOf: directory.appendingPathComponent("\(kind)-wrapper.json"))
        let dedicated = try Data(contentsOf: directory.appendingPathComponent("\(kind)-dedicated.json"))
        _ = try positivePair(
            wrapper, dedicated, version: version, kind: kind, token: token, libraryID: item.libraryId,
            folderID: #require(item.folderId), folderPath: folder, authors: authors, series: series)
        for shape in ["wrapper", "dedicated"] {
            let source = shape == "wrapper" ? wrapper : dedicated
            let proof = try object(object(manifest["captures"])["\(kind)-\(shape)"])
            #expect(digest(source) == proof["sha256"] as? String)
            let substitutions = try object(proof["substitutions"])
            let prefix = shape == "wrapper" ? "/filterdata" : ""
            var allowed: Set<String> = []
            if kind == "book" {
                for group in ["authors", "series"] {
                    for index in 0..<2 {
                        allowed.insert("\(prefix)/\(group)/\(index)/id")
                        allowed.insert("\(prefix)/\(group)/\(index)/name")
                    }
                }
            }
            for group in (kind == "book" ? ["tags", "genres", "narrators"] : ["tags", "genres"]) {
                for index in 0..<(kind == "book" ? 2 : 1) { allowed.insert("\(prefix)/\(group)/\(index)") }
            }
            if shape == "wrapper" {
                allowed.formUnion([
                    "/library/id", "/library/name", "/library/folders/0/id", "/library/folders/0/libraryId",
                ])
            }
            try #require(Set(substitutions.keys) == allowed)
            let fixtureData = try fixture(version, kind, shape)
            #expect(digest(fixtureData) == proof["sanitizedSHA256"] as? String)
            let visited = try compare(
                JSONSerialization.jsonObject(with: source), JSONSerialization.jsonObject(with: fixtureData),
                substitutions: substitutions)
            #expect(visited == allowed)
        }
    }

    /// Full structural comparison: only the explicit identifying string leaves may change.
    private func compare(
        _ original: Any, _ fixture: Any, substitutions: [String: Any], path: String = ""
    ) throws -> Set<String> {
        if let value = substitutions[path] {
            let change = try object(value)
            let before = try #require(original as? String)
            let after = try #require(fixture as? String)
            #expect(before == change["original"] as? String)
            #expect(after == change["sanitized"] as? String)
            #expect(before != after)
            try #require(["identity", "query-token-prefix"].contains(try #require(change["category"] as? String)))
            return [path]
        }
        if let original = original as? [String: Any] {
            let fixture = try object(fixture)
            try #require(Set(original.keys) == Set(fixture.keys))
            return try original.reduce(into: []) { result, entry in
                result.formUnion(
                    try compare(
                        entry.value, fixture[entry.key]!, substitutions: substitutions,
                        path: path + "/" + entry.key))
            }
        }
        if let original = original as? [Any] {
            let fixture = try #require(fixture as? [Any])
            try #require(original.count == fixture.count)
            return try original.indices.reduce(into: []) { result, index in
                result.formUnion(
                    try compare(
                        original[index], fixture[index], substitutions: substitutions,
                        path: path + "/\(index)"))
            }
        }
        if let original = original as? NSNumber {
            let fixture = try #require(fixture as? NSNumber)
            #expect(CFGetTypeID(original) == CFGetTypeID(fixture))
            #expect(String(cString: original.objCType) == String(cString: fixture.objCType))
            #expect(original == fixture)
        } else if let original = original as? String {
            #expect(fixture as? String == original)
        } else {
            #expect(original is NSNull && fixture is NSNull)
        }
        return []
    }
}
