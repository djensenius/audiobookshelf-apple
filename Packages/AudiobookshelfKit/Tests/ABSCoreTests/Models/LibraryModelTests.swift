import ABSCore
import Foundation
import Testing

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Suite struct LibraryModelTests {
    @Test func decodesLibrary() throws {
        let library = try decode(Library.self, Fixtures.library)
        #expect(library.id == "lib-books")
        #expect(library.mediaType == .book)
        #expect(library.folders?.first?.fullPath == "/audiobooks")
        #expect(library.settings?.coverAspectRatio == 1)
        #expect(library.settings?.markAsFinishedTimeRemaining == 10)
        #expect(library.settings?.markAsFinishedPercentComplete == nil)
    }

    @Test func decodesExpandedSingleFileBook() throws {
        let item = try decode(LibraryItem.self, Fixtures.singleFileBook)
        #expect(item.mediaType == .book)
        #expect(item.isFile == true)
        #expect(item.size == 105_381_888)
        let book = try #require(item.book)
        #expect(book.metadata.title == "The First Book")
        #expect(book.metadata.authors?.map(\.name) == ["Author One"])
        #expect(book.metadata.series?.first?.sequence == "1")
        #expect(book.metadata.narrators == ["Narrator One"])
        #expect(book.audioFiles?.first?.id == "649644248522215260")
        #expect(book.audioFiles?.first?.metadata?.size == 104_857_600)
        #expect(book.ebookFile?.ebookFormat == .epub)
        #expect(book.ebookFile?.ebookFormat?.mimeType == "application/epub+zip")
        #expect(book.duration == 3725.5)
        #expect(item.libraryFiles?.first?.fileType == "audio")
    }

    @Test func decodesChaptersAndTracks() throws {
        let book = try #require(try decode(LibraryItem.self, Fixtures.singleFileBook).book)
        let chapters = try #require(book.chapters)
        #expect(chapters.map(\.id) == [0, 1])
        #expect(chapters[1].start == 1800.25)
        #expect(chapters[1].end == 3725.5)
        #expect(chapters[1].title == "Chapter 2")
        let track = try #require(book.tracks?.first)
        #expect(track.index == 1)
        #expect(track.id == "1-0.0")
        #expect(track.contentUrl == "/api/items/li-book-1/file/649644248522215260")
        #expect(track.endOffset == 3725.5)
    }

    @Test func decodesMultiFileBookWithOmittedFields() throws {
        let item = try decode(LibraryItem.self, Fixtures.multiFileBook)
        #expect(item.isFile == false)
        #expect(item.mtimeMs == nil)
        let book = try #require(item.book)
        #expect(book.coverPath == nil)
        #expect(book.ebookFile == nil)
        #expect(book.metadata.subtitle == nil)
        #expect(book.audioFiles?.count == 2)
        let tracks = try #require(book.tracks)
        #expect(tracks.map(\.startOffset) == [0, 600])
        #expect(tracks.map(\.endOffset) == [600, 1000.5])
    }

    @Test func decodesMinifiedBook() throws {
        let item = try decode(LibraryItem.self, Fixtures.minifiedBook)
        #expect(item.numFiles == 2)
        #expect(item.libraryFiles == nil)
        #expect(item.lastScan == nil)
        let book = try #require(item.book)
        #expect(book.libraryItemId == nil)
        #expect(book.audioFiles == nil)
        #expect(book.tracks == nil)
        #expect(book.metadata.authors == nil)
        #expect(book.metadata.authorName == "Author One")
        #expect(book.metadata.seriesName == "Saga #1")
        #expect(book.numTracks == 1)
        #expect(book.numChapters == 2)
        #expect(book.ebookFormat == .epub)
    }

    @Test func decodesPodcastWithEpisodes() throws {
        let item = try decode(LibraryItem.self, Fixtures.podcast)
        #expect(item.mediaType == .podcast)
        #expect(item.book == nil)
        let podcast = try #require(item.podcast)
        #expect(podcast.metadata.author == "Host")
        #expect(podcast.metadata.feedUrl == "https://feed.example.com/rss")
        #expect(podcast.autoDownloadEpisodes == true)
        let episodes = try #require(podcast.episodes)
        #expect(episodes.count == 2)
        let episode = episodes[0]
        #expect(episode.id == "ep-1")
        #expect(episode.episodeType == .full)
        #expect(episode.enclosure?.length == "3000000")
        #expect(episode.audioTrack?.contentUrl == "/api/items/li-pod-1/file/21")
        #expect(episode.chapters?.first?.title == "Intro")
        #expect(episode.publishedAt == 1_699_264_800_000)
        #expect(episode.duration == 1500)
        #expect(episodes[1].episodeType == .unknown("teaser"))
        #expect(episodes[1].audioFile == nil)
        #expect(episodes[1].title == "")
        #expect(episodes[1].chapters?.first?.title == "")
    }

    @Test func preservesUnknownMediaType() throws {
        let json = #"{"id":"li-x","libraryId":"lib-x","mediaType":"video","media":{"id":"v-1"}}"#
        let item = try decode(LibraryItem.self, json)
        #expect(item.mediaType == .unknown("video"))
        #expect(item.mediaType.rawValue == "video")
        #expect(item.media == nil)
        #expect(item.isMissing == false)
    }

    @Test func decodesShelves() throws {
        let shelves = try decode([Shelf].self, Fixtures.shelves)
        #expect(
            shelves.map(\.id) == [
                "continue-listening", "newest-episodes", "recent-series", "newest-authors", "future-shelf",
            ])

        guard case .libraryItems(let books) = shelves[0].entities else {
            Issue.record("Expected library items")
            return
        }
        #expect(books.map(\.id) == ["li-book-1"])
        #expect(books.first?.book?.metadata.title == "The First Book")
        #expect(shelves[0].labelStringKey == "LabelContinueListening")

        guard case .libraryItems(let episodes) = shelves[1].entities else {
            Issue.record("Expected library items")
            return
        }
        #expect(shelves[1].type == .episode)
        #expect(episodes.first?.recentEpisode?.id == "ep-1")
        #expect(episodes.first?.numEpisodesIncomplete == 1)
        #expect(episodes.first?.podcast?.numEpisodes == 2)

        guard case .series(let series) = shelves[2].entities else {
            Issue.record("Expected series")
            return
        }
        #expect(series.first?.books?.first?.id == "li-book-1")

        guard case .authors(let authors) = shelves[3].entities else {
            Issue.record("Expected authors")
            return
        }
        #expect(authors.first?.numBooks == 1)

        #expect(shelves[4].type == .unknown("carousel"))
        #expect(shelves[4].entities == .unknown)
    }

    @Test func decodesSeriesAndCollapsedSeries() throws {
        let item = try decode(LibraryItem.self, Fixtures.collapsedSeriesItem)
        #expect(item.series?.id == "se-1")
        #expect(item.series?.sequence == "1-3")
        let collapsed = try #require(item.collapsedSeries)
        #expect(collapsed.name == "The Subseries")
        #expect(collapsed.nameIgnorePrefix == "Subseries")
        #expect(collapsed.sequence == "4")
        #expect(collapsed.numBooks == 2)
        #expect(collapsed.libraryItemIds == ["li-book-4", "li-book-5"])
        #expect(try decode(LibraryItem.self, Fixtures.minifiedBook).collapsedSeries == nil)
    }

    @Test func lossyArraySkipsMalformedElements() throws {
        let json = #"[{"id":"au-1","name":"One"},{"id":2},"text",null,{"id":"au-3","name":"Three"}]"#
        let authors = try decode(LossyArray<Author>.self, json)
        #expect(authors.elements.map(\.id) == ["au-1", "au-3"])
    }

    @Test func buildsLocalSessionInMemory() {
        let track = AudioTrack(index: 1, startOffset: 0, duration: 60, contentUrl: "file:///a.m4b")
        var session = PlaybackSession(
            id: "local-1", libraryItemId: "li-1", mediaType: .book,
            mediaMetadata: .book(BookMetadata(title: "Book")), chapters: [Chapter(id: 0, start: 0, end: 60)],
            duration: 60, playMethod: .local, audioTracks: [track])
        session.currentTime = 30
        session.timeListening = 5
        session.updatedAt = 1_700_000_000_000
        #expect(session.playMethod == .local)
        #expect(session.currentTime == 30)
        #expect(session.audioTracks.first?.endOffset == 60)
        #expect(session.chapters.first?.title == "")
    }

    @Test func decodesPlaybackSession() throws {
        let session = try decode(PlaybackSession.self, Fixtures.session)
        #expect(session.id == "ps-1")
        #expect(session.playMethod == .directPlay)
        #expect(session.episodeId == nil)
        #expect(session.duration == 3725.5)
        #expect(session.currentTime == 120.5)
        #expect(session.timeListening == 0)
        #expect(session.startedAt == 1_700_000_100_000)
        #expect(session.chapters.count == 2)
        #expect(session.audioTracks.first?.contentUrl == "/public/session/ps-1/track/1")
        #expect(session.deviceInfo?.model == "iPhone18,1")
        guard case .book(let metadata) = session.mediaMetadata else {
            Issue.record("Expected book metadata")
            return
        }
        #expect(metadata.authors?.first?.name == "Author One")
        #expect(session.mediaMetadata?.title == "The First Book")
        #expect(session.libraryItem?.book?.tracks?.count == 1)
    }

    @Test func decodesNullTrackIndex() throws {
        let episode = try decode(PodcastEpisode.self, Fixtures.nullIndexEpisode)
        #expect(episode.audioTrack?.index == nil)
        #expect(episode.audioTrack?.id == "0-0.0")
        #expect(episode.audioFile?.index == nil)

        let session = try decode(PlaybackSession.self, Fixtures.nullIndexEpisodeSession)
        #expect(session.mediaType == .podcast)
        #expect(session.audioTracks.map(\.index) == [nil])
        #expect(session.audioTracks.first?.endOffset == 900)
        let episodes = try #require(session.libraryItem?.podcast?.episodes)
        #expect(episodes.map(\.id) == ["ep-3"])
        #expect(episodes.first?.audioTrack?.index == nil)
    }

    @Test func decodesSDKVersionAsStringOrNumber() throws {
        let android = try decode(PlaybackSession.self, Fixtures.androidSession)
        #expect(android.deviceInfo?.sdkVersion == "35")
        #expect(android.deviceInfo?.clientName == "Abs Android")
        #expect(android.deviceInfo?.deviceName == "Google Pixel 9")
        let numeric = try decode(PlaybackSession.self, Fixtures.numericSDKVersionSession)
        #expect(numeric.deviceInfo?.sdkVersion == "34")
        #expect(try decode(PlaybackSession.self, Fixtures.session).deviceInfo?.sdkVersion == nil)
        let reencoded = String(decoding: try JSONEncoder().encode(numeric), as: UTF8.self)
        #expect(try decode(PlaybackSession.self, reencoded).deviceInfo?.sdkVersion == "34")
    }

    @Test func preservesUnknownPlayMethod() throws {
        let json = #"{"id":"ps-2","libraryItemId":"li-1","mediaType":"book","playMethod":9}"#
        let session = try decode(PlaybackSession.self, json)
        #expect(session.playMethod == .unknown(9))
        #expect(session.mediaMetadata == nil)
        #expect(session.audioTracks.isEmpty)
    }

    @Test func decodesPlaylist() throws {
        let playlist = try decode(Playlist.self, Fixtures.playlist)
        #expect(playlist.name == "Commute")
        #expect(playlist.items.map(\.id) == ["li-pod-1-ep-1", "li-book-1"])
        #expect(playlist.items[0].episode?.title == "Episode Twelve")
        #expect(playlist.items[0].libraryItem?.podcast?.metadata.title == "The Show")
        #expect(playlist.items[1].episodeId == nil)
        #expect(playlist.items[1].libraryItem?.book?.numTracks == 1)
    }

    @Test func decodesCollection() throws {
        let collection = try decode(LibraryCollection.self, Fixtures.collection)
        #expect(collection.name == "Favourites")
        #expect(collection.books?.first?.book?.chapters?.count == 2)
    }

    @Test func roundTripsThroughEncoding() throws {
        let encoder = JSONEncoder()
        let item = try decode(LibraryItem.self, Fixtures.podcast)
        #expect(try decode(LibraryItem.self, String(decoding: encoder.encode(item), as: UTF8.self)) == item)
        let session = try decode(PlaybackSession.self, Fixtures.session)
        #expect(try decode(PlaybackSession.self, String(decoding: encoder.encode(session), as: UTF8.self)) == session)
        let shelves = try decode([Shelf].self, Fixtures.shelves)
        let reencoded = try decode([Shelf].self, String(decoding: encoder.encode(shelves), as: UTF8.self))
        #expect(reencoded == shelves)

        // Unknown values survive a round trip; items of an unknown media type re-encode without `media`.
        let unknownItem = try decode(
            LibraryItem.self, #"{"id":"li-x","libraryId":"lib-x","mediaType":"video","media":{"id":"v-1"}}"#)
        let unknownItemJSON = String(decoding: try encoder.encode(unknownItem), as: UTF8.self)
        #expect(try decode(LibraryItem.self, unknownItemJSON).mediaType == .unknown("video"))
        #expect(!unknownItemJSON.contains("\"media\""))
        let unknownSession = try decode(
            PlaybackSession.self, #"{"id":"ps-2","libraryItemId":"li-1","mediaType":"video","playMethod":9}"#)
        let unknownSessionJSON = String(decoding: try encoder.encode(unknownSession), as: UTF8.self)
        let decodedSession = try decode(PlaybackSession.self, unknownSessionJSON)
        #expect(decodedSession.playMethod == .unknown(9))
        #expect(decodedSession.mediaType == .unknown("video"))
    }
}
