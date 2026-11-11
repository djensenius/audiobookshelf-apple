import ABSAPI
import ABSCore
import CoreFoundation
import Foundation
import Testing

/// Checks the complete captured response before trusting any element-lossy production container.
enum SearchRaw {
    static func object(_ data: Data) throws -> [String: Any] {
        try dictionary(JSONSerialization.jsonObject(with: data))
    }

    static func dictionary(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    static func rows(_ value: Any?) throws -> [[String: Any]] {
        try #require(value as? [[String: Any]])
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        let value = try #require(object[key] as? String)
        try #require(!value.isEmpty)
        return value
    }

    static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        let number = try #require(object[key] as? NSNumber)
        try #require(CFGetTypeID(number) != CFBooleanGetTypeID())
        try #require(number.doubleValue == Double(number.intValue))
        return number.intValue
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    static func equalJSON(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: lhs), options: .sortedKeys)
        let right = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: rhs), options: .sortedKeys)
        return left == right
    }

    static func item(_ raw: [String: Any]) throws -> LibraryItem {
        let value = try decode(LibraryItem.self, raw)
        let media = try dictionary(raw["media"])
        if value.mediaType == .book {
            let strict = try decode(Book.self, media)
            #expect(value.book == strict)
            let metadata = try dictionary(media["metadata"])
            if let authors = metadata["authors"] {
                #expect(try rows(authors).map { try decode(Author.self, $0) } == strict.metadata.authors)
            }
            if let series = metadata["series"] {
                #expect(try rows(series).map { try decode(Series.self, $0) } == strict.metadata.series)
            }
        } else {
            try #require(value.mediaType == .podcast)
            let strict = try decode(Podcast.self, media)
            #expect(value.podcast == strict)
            if let episodes = media["episodes"] {
                let complete = try rows(episodes).map { try decode(PodcastEpisode.self, $0) }
                #expect(strict.episodes == complete)
            }
        }
        if let episode = raw["recentEpisode"] {
            #expect(try decode(PodcastEpisode.self, episode) == value.recentEpisode)
        }
        return value
    }

    static func search(
        _ data: Data, ledger: SearchLedger, podcast: Bool, limit: Int? = nil, empty: Bool = false
    ) throws -> LibrarySearchResults {
        let raw = try object(data)
        let keys: Set<String> =
            podcast
            ? ["podcast", "tags", "genres", "episodes"]
            : ["book", "narrators", "tags", "genres", "series", "authors"]
        try #require(Set(raw.keys) == keys)
        let decoded = try JSONDecoder().decode(LibrarySearchResults.self, from: data)
        let maximum = empty ? 0 : (limit == nil || limit == 0 ? 12 : limit!)
        func count(_ actual: Int, _ full: Int) {
            #expect(actual == min(full, maximum))
        }
        func items(_ key: String, _ values: [LibraryItem], _ expected: [LibraryItem]) throws {
            let entries = try rows(raw[key])
            count(entries.count, expected.count)
            #expect(values.count == entries.count)
            let strict = try entries.map { entry in
                try #require(Set(entry.keys) == ["libraryItem"])
                return try item(dictionary(entry["libraryItem"]))
            }
            #expect(values == strict)  // Includes response order, not an invented cross-group tie order.
            #expect(Set(strict.map(\.id)).isSubset(of: Set(expected.map(\.id))))
            if maximum >= expected.count { #expect(Set(strict.map(\.id)) == Set(expected.map(\.id))) }
            for value in strict {
                let original = try #require(expected.first { $0.id == value.id })
                #expect(value.libraryId == original.libraryId)
                #expect(value.mediaType == original.mediaType)
                if let book = value.book {
                    let originalBook = try #require(original.book)
                    #expect(book.id == originalBook.id)
                    #expect(book.metadata.title == originalBook.metadata.title)
                    #expect(Set(book.metadata.authors ?? []) == Set(originalBook.metadata.authors ?? []))
                    #expect(Set(book.metadata.series ?? []) == Set(originalBook.metadata.series ?? []))
                    #expect(book.metadata.narrators == originalBook.metadata.narrators)
                    #expect(book.metadata.genres == originalBook.metadata.genres)
                    #expect(book.tags == originalBook.tags)
                    #expect(book.audioFiles == originalBook.audioFiles)
                    #expect(book.tracks == originalBook.tracks)
                    #expect(book.chapters == originalBook.chapters)
                    #expect(book.duration == originalBook.duration)
                    #expect(book.size == originalBook.size)
                } else {
                    let cast = try #require(value.podcast)
                    let originalCast = try #require(original.podcast)
                    #expect(cast.id == originalCast.id)
                    #expect(cast.metadata == originalCast.metadata)
                    #expect(cast.tags == originalCast.tags)
                    #expect(cast.episodes == [])
                }
            }
        }
        func names(_ key: String, _ values: [LibrarySearchResults.NameMatch], _ expected: [String: Int]) throws {
            let entries = try rows(raw[key])
            count(entries.count, expected.count)
            #expect(entries.count == values.count)
            let countKey = key == "narrators" ? "numBooks" : "numItems"
            for (entry, value) in zip(entries, values) {
                #expect(Set(entry.keys) == ["name", countKey])
                let name = try string(entry, "name")
                let number = try integer(entry, countKey)
                #expect(expected[name] == number)
                #expect(value.name == name)
                #expect(value.count == number)
            }
            #expect(Set(values.map(\.name)).count == values.count)
        }
        if podcast {
            try items("podcast", decoded.podcasts, [ledger.podcast])
            let episodes = try #require(ledger.podcast.podcast?.episodes)
            let entries = try rows(raw["episodes"])
            count(entries.count, episodes.count)
            #expect(decoded.episodes.count == entries.count)
            var ids: [String] = []
            for (entry, value) in zip(entries, decoded.episodes) {
                try #require(Set(entry.keys) == ["libraryItem"])
                let rawItem = try dictionary(entry["libraryItem"])
                let strict = try item(rawItem)
                #expect(value == strict)
                #expect(value.id == ledger.podcast.id)
                #expect(value.libraryId == ledger.podcastLibrary)
                #expect(value.podcast?.metadata == ledger.podcast.podcast?.metadata)
                #expect(value.podcast?.episodes == [])
                let rawEpisode = try dictionary(rawItem["recentEpisode"])
                #expect(
                    Set(rawEpisode.keys) == [
                        "libraryItemId", "podcastId", "id", "oldEpisodeId", "index", "season", "episode", "episodeType",
                        "title", "subtitle", "description", "enclosure", "guid", "pubDate", "chapters", "audioFile",
                        "publishedAt", "addedAt", "updatedAt", "audioTrack", "size", "duration",
                    ])
                let episode = try #require(value.recentEpisode)
                let expected = try #require(episodes.first { $0.id == episode.id })
                #expect(episode == expected)  // All fields, including file/track, dates, duration and size.
                #expect(episode.libraryItemId == ledger.podcast.id)
                #expect(episode.title.contains(ledger.token))
                #expect(episode.duration == rawEpisode["duration"] as? Double)
                #expect(episode.publishedAt == rawEpisode["publishedAt"] as? Int)
                #expect(episode.pubDate == rawEpisode["pubDate"] as? String)
                #expect(episode.addedAt == rawEpisode["addedAt"] as? Int)
                #expect(episode.updatedAt == rawEpisode["updatedAt"] as? Int)
                #expect((episode.duration ?? 0) > 0)
                // Locally scanned files have no RSS publication date (PodcastScanner sets both
                // fields to null). Pin present JSON null, not merely an optional decoder default.
                #expect(rawEpisode["publishedAt"] is NSNull)
                #expect(rawEpisode["pubDate"] is NSNull)
                #expect(episode.publishedAt == nil && episode.pubDate == nil)
                #expect(try integer(rawEpisode, "addedAt") > 0)
                #expect(try integer(rawEpisode, "updatedAt") > 0)
                let track = try #require(episode.audioTrack)
                let rawTrack = try dictionary(rawEpisode["audioTrack"])
                #expect(try decode(AudioTrack.self, rawTrack) == track)
                #expect(try integer(rawTrack, "index") == 1)
                #expect(try integer(rawTrack, "startOffset") == 0)
                #expect(track.index == 1)
                #expect(track.duration == episode.duration)
                #expect(track.mimeType == "audio/mpeg")
                #expect(try #require(track.contentUrl).isEmpty == false)
                ids.append(episode.id)
            }
            #expect(Set(ids).count == ids.count)
            #expect(Set(ids).isSubset(of: Set(episodes.map(\.id))))
            try names("tags", decoded.tags, ["\(ledger.token) Podcast Tag": 1])
            try names("genres", decoded.genres, ["\(ledger.token) Podcast Genre": 1])
            #expect(
                decoded.books.isEmpty && decoded.authors.isEmpty && decoded.series.isEmpty && decoded.narrators.isEmpty)
        } else {
            try items("book", decoded.books, ledger.books)
            for (key, values, kind) in [
                ("narrators", decoded.narrators, "Narrator"), ("tags", decoded.tags, "Tag"),
                ("genres", decoded.genres, "Genre"),
            ] {
                try names(key, values, ["\(ledger.token) Shared \(kind)": 2, "\(ledger.token) Unique \(kind)": 1])
            }
            let authors = try rows(raw["authors"])
            count(authors.count, ledger.authors.count)
            #expect(decoded.authors.count == authors.count)
            for (entry, author) in zip(authors, decoded.authors) {
                #expect(
                    Set(entry.keys) == [
                        "id", "asin", "name", "description", "imagePath", "libraryId", "addedAt", "updatedAt",
                        "numBooks",
                    ])
                #expect(try decode(Author.self, entry) == author)
                let expected = try #require(ledger.authors.first { $0.id == author.id })
                #expect(author.name == expected.name)
                #expect(author.libraryId == ledger.bookLibrary)
                let members = ledger.books.filter { $0.book?.metadata.authors?.contains { $0.id == author.id } == true }
                #expect(try integer(entry, "numBooks") == members.count)
                #expect(author.numBooks == members.count)
            }
            #expect(Set(decoded.authors.map(\.id)).count == decoded.authors.count)
            let series = try rows(raw["series"])
            count(series.count, ledger.series.count)
            #expect(decoded.series.count == series.count)
            for (entry, match) in zip(series, decoded.series) {
                #expect(Set(entry.keys) == ["series", "books"])
                let rawSeries = try dictionary(entry["series"])
                #expect(
                    Set(rawSeries.keys) == [
                        "id", "name", "nameIgnorePrefix", "description", "addedAt", "updatedAt", "libraryId",
                    ])
                #expect(try decode(Series.self, rawSeries) == match.series)
                let original = try #require(ledger.series.first { $0.id == match.id })
                #expect(match.series.name == original.name)
                #expect(match.series.libraryId == ledger.bookLibrary)
                #expect(match.series.sequence == nil)
                let members = try rows(entry["books"])
                let expected = ledger.books.filter { $0.book?.metadata.series?.contains { $0.id == match.id } == true }
                #expect(members.count == expected.count)
                #expect(match.books.count == members.count)
                #expect(Set(match.books.map(\.id)) == Set(expected.map(\.id)))
                for (member, book) in zip(members, match.books) {
                    #expect(try item(member) == book)
                    #expect(book.libraryId == ledger.bookLibrary)
                    let metadata = try dictionary(dictionary(member["media"])["metadata"])
                    #expect(try rows(metadata["authors"]).isEmpty)
                    #expect(try rows(metadata["series"]).isEmpty)
                    #expect(book.book?.metadata.authors == [])
                    #expect(book.book?.metadata.series == [])
                    #expect(book.series == nil)
                    #expect(member["series"] == nil)
                    #expect(book.book?.tracks == nil)  // Full/nonexpanded members, not expanded search books.
                }
            }
            #expect(Set(decoded.series.map(\.id)).count == decoded.series.count)
            #expect(decoded.podcasts.isEmpty && decoded.episodes.isEmpty)
        }
        return decoded
    }
}
