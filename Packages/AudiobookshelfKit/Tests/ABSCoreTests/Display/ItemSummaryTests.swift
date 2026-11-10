import Foundation
import Testing

@testable import ABSCore

@Suite struct ItemSummaryTests {
    private func book(
        id: String = "li_1", title: String = "Dune", metadata: (String) -> BookMetadata = { BookMetadata(title: $0) },
        coverPath: String? = "/metadata/items/li_1/cover.jpg", duration: Double? = 3_600, numTracks: Int? = 1,
        series: Series? = nil, collapsed: CollapsedSeries? = nil, isMissing: Bool = false, isInvalid: Bool = false
    ) -> LibraryItem {
        LibraryItem(
            id: id, libraryId: "lib", updatedAt: 99, isMissing: isMissing, isInvalid: isInvalid, mediaType: .book,
            media: .book(
                Book(
                    id: "b", metadata: metadata(title), coverPath: coverPath, duration: duration,
                    numTracks: numTracks)),
            series: series, collapsedSeries: collapsed)
    }

    @Test func bookMapsTitleAuthorDurationAndCover() throws {
        let item = book(metadata: { BookMetadata(title: $0, authorName: "Frank Herbert") })
        let summary = ItemSummary(item: item)
        #expect(summary.id == "li_1" && summary.itemID == "li_1" && summary.episodeID == nil)
        #expect(summary.kind == .book)
        #expect(summary.title == "Dune")
        #expect(summary.subtitle == "Frank Herbert")
        #expect(summary.duration == 3_600)
        #expect(summary.hasAudio)
        let serverID = UUID()
        let key = try #require(summary.coverKey(serverID: serverID))
        #expect(key == ImageKey(serverID: serverID, kind: .itemCover, entityID: "li_1", updatedAt: 99))
    }

    @Test func authorFallsBackToTheAuthorsList() {
        let item = book(metadata: {
            BookMetadata(title: $0, authors: [Author(id: "a", name: "A"), Author(id: "b", name: "B")])
        })
        #expect(ItemSummary(item: item).subtitle == "A, B")
    }

    @Test func seriesTextPrefersTheListContextThenMetadataThenSeriesName() {
        let context = Series(id: "s1", name: "Dune Chronicles", sequence: "2")
        let inMetadata = Series(id: "s2", name: "Own", sequence: "1")
        let withContext = book(
            metadata: { BookMetadata(title: $0, series: [inMetadata], seriesName: "Flat #9") }, series: context)
        #expect(ItemSummary(item: withContext).seriesText == "Dune Chronicles #2")
        let withMetadata = book(metadata: { BookMetadata(title: $0, series: [inMetadata], seriesName: "Flat #9") })
        #expect(ItemSummary(item: withMetadata).seriesText == "Own #1")
        let flat = book(metadata: { BookMetadata(title: $0, seriesName: "Flat #9") })
        #expect(ItemSummary(item: flat).seriesText == "Flat #9")
        let noSequence = book(series: Series(id: "s3", name: "Standalone Saga"))
        #expect(ItemSummary(item: noSequence).seriesText == "Standalone Saga")
        #expect(ItemSummary(item: book()).seriesText == nil)
    }

    @Test func unnamedSeriesShowsOnlyItsSequenceOrNothing() {
        #expect(ItemSummary(item: book(series: Series(id: "s", name: "", sequence: "2"))).seriesText == "#2")
        #expect(ItemSummary(item: book(series: Series(id: "s", name: ""))).seriesText == nil)
    }

    @Test func explicitAndAbridgedFlagsCarryOver() {
        let item = book(metadata: { BookMetadata(title: $0, explicit: true, abridged: true) })
        let summary = ItemSummary(item: item)
        #expect(summary.isExplicit && summary.isAbridged)
        let plain = ItemSummary(item: book())
        #expect(!plain.isExplicit && !plain.isAbridged)
    }

    @Test func noCoverPathMeansNoCover() {
        let summary = ItemSummary(item: book(coverPath: nil))
        #expect(summary.cover == nil)
        #expect(summary.coverKey(serverID: UUID()) == nil)
        #expect(ItemSummary(item: book(coverPath: "")).cover == nil)
    }

    @Test func absoluteCoverPathBecomesAnExternalURL() throws {
        let summary = ItemSummary(item: book(coverPath: "https://example.com/c.jpg"))
        let key = try #require(summary.coverKey(serverID: UUID()))
        #expect(key.externalURL == URL(string: "https://example.com/c.jpg"))
        #expect(ItemSummary(item: book()).cover?.externalURL == nil)
    }

    @Test func missingAndInvalidItemsAreUnplayable() {
        #expect(ItemSummary(item: book(isMissing: true)).isMissing)
        #expect(ItemSummary(item: book(isInvalid: true)).isMissing)
        #expect(!ItemSummary(item: book()).isMissing)
    }

    @Test func audioPresenceComesFromCountsThenDuration() {
        #expect(!ItemSummary(item: book(duration: nil, numTracks: 0)).hasAudio)
        #expect(ItemSummary(item: book(duration: nil, numTracks: 3)).hasAudio)
        #expect(!ItemSummary(item: book(duration: 0, numTracks: nil)).hasAudio)
        #expect(ItemSummary(item: book(duration: 10, numTracks: nil)).hasAudio)
        #expect(ItemSummary(item: book(duration: nil, numTracks: nil)).hasAudio)
    }

    private let podcastMetadata = PodcastMetadata(title: "Classic Tales", author: "Players", explicit: true)

    private func podcast(recent: PodcastEpisode? = nil) -> LibraryItem {
        LibraryItem(
            id: "li_pod", libraryId: "lib", updatedAt: 5, mediaType: .podcast,
            media: .podcast(Podcast(id: "p", metadata: podcastMetadata, coverPath: "/c.jpg")), recentEpisode: recent)
    }

    @Test func podcastMapsToItsTitleAndAuthorWithoutPlayback() {
        let summary = ItemSummary(item: podcast())
        #expect(summary.kind == .podcast)
        #expect(summary.id == "li_pod" && summary.episodeID == nil)
        #expect(summary.title == "Classic Tales" && summary.subtitle == "Players")
        #expect(summary.isExplicit)
        #expect(!summary.hasAudio)
    }

    @Test func episodeUsesItsOwnTitleAndTheIdsAndCoverOfThePodcast() throws {
        let episode = PodcastEpisode(id: "ep_1", title: "The League", duration: 1_800)
        for summary in [ItemSummary(item: podcast(recent: episode)), ItemSummary(item: podcast(), episode: episode)] {
            #expect(summary.kind == .episode)
            #expect(summary.id == "li_pod-ep_1")
            #expect(summary.itemID == "li_pod" && summary.episodeID == "ep_1")
            #expect(summary.title == "The League" && summary.subtitle == "Classic Tales")
            #expect(summary.duration == 1_800)
            #expect(summary.cover?.entityID == "li_pod")
            #expect(summary.progressKey == "li_pod-ep_1")
        }
    }

    @Test func collapsedSeriesStandsForTheSeriesWithTheFirstBooksCover() {
        let collapsed = CollapsedSeries(id: "ser_1", name: "Barsoom", numBooks: 3, libraryItemIds: ["a", "b"])
        let summary = ItemSummary(item: book(id: "li_first", title: "A Princess of Mars", collapsed: collapsed))
        #expect(summary.kind == .series)
        #expect(summary.id == "series-ser_1" && summary.seriesID == "ser_1" && summary.itemID == "li_first")
        #expect(summary.title == "Barsoom")
        #expect(summary.bookCount == 3)
        #expect(summary.cover?.entityID == "li_first")
        #expect(summary.seriesText == nil)
        let counted = CollapsedSeries(id: "ser_2", name: "Two", libraryItemIds: ["a", "b"])
        #expect(ItemSummary(item: book(collapsed: counted)).bookCount == 2)
    }

    @Test func aCollapsedSeriesIsNeverMissingEvenWhenItsFirstBookIs() {
        let collapsed = CollapsedSeries(id: "ser_1", name: "Barsoom", numBooks: 3)
        #expect(ItemSummary(item: book(collapsed: collapsed, isMissing: true)).isMissing == false)
        #expect(ItemSummary(item: book(collapsed: collapsed, isInvalid: true)).isMissing == false)
        #expect(ItemSummary(item: book(isMissing: true)).isMissing)
    }

    @Test func seriesSummaryKeepsTheFirstFourCovers() {
        let books = (1...6).map { book(id: "li_\($0)") }
        let summary = SeriesSummary(series: Series(id: "s", name: "Long", books: books, totalDuration: 7_200))
        #expect(summary.bookCount == 6)
        #expect(summary.covers.map(\.entityID) == ["li_1", "li_2", "li_3", "li_4"])
        #expect(summary.totalDuration == 7_200)
    }

    @Test func authorSummaryHasAnImageKeyOnlyWithAnImage() {
        let with = AuthorSummary(author: Author(id: "a", name: "N", imagePath: "/x.jpg", updatedAt: 4, numBooks: 2))
        let serverID = UUID()
        #expect(
            with.imageKey(serverID: serverID)
                == ImageKey(serverID: serverID, kind: .authorImage, entityID: "a", updatedAt: 4))
        #expect(with.bookCount == 2)
        #expect(AuthorSummary(author: Author(id: "b", name: "M")).imageKey(serverID: serverID) == nil)
    }

    @Test func theSameItemMapsIdenticallyFromServerJSONAndALocalFixture() throws {
        let minified = """
            {"id":"li_1","libraryId":"lib","updatedAt":99,"mediaType":"book","numFiles":1,"size":10,
             "media":{"id":"b","coverPath":"/metadata/items/li_1/cover.jpg","numTracks":1,
              "metadata":{"title":"Dune","authorName":"Frank Herbert","seriesName":"Dune Chronicles #1","explicit":false}}}
            """
        let expanded = """
            {"id":"li_1","libraryId":"lib","updatedAt":99,"mediaType":"book","path":"/books/dune","isMissing":false,
             "libraryFiles":[],"media":{"id":"b","libraryItemId":"li_1","coverPath":"/metadata/items/li_1/cover.jpg",
              "tracks":[],"audioFiles":[],"duration":0,
              "metadata":{"title":"Dune","authorName":"Frank Herbert","seriesName":"Dune Chronicles #1","abridged":false,
               "authors":[{"id":"a","name":"Frank Herbert"}]}}}
            """
        let local = LibraryItem(
            id: "li_1", libraryId: "lib", updatedAt: 99, mediaType: .book,
            media: .book(
                Book(
                    id: "b",
                    metadata: BookMetadata(
                        title: "Dune", authorName: "Frank Herbert", seriesName: "Dune Chronicles #1"),
                    coverPath: "/metadata/items/li_1/cover.jpg", numTracks: 1)))
        let decoder = JSONDecoder()
        let fromMinified = ItemSummary(item: try decoder.decode(LibraryItem.self, from: Data(minified.utf8)))
        let fromExpanded = ItemSummary(item: try decoder.decode(LibraryItem.self, from: Data(expanded.utf8)))
        #expect(fromMinified == ItemSummary(item: local))
        // The expanded form has no audio files, so only its audio flag may differ.
        #expect(fromExpanded.title == fromMinified.title && fromExpanded.subtitle == fromMinified.subtitle)
        #expect(fromExpanded.seriesText == fromMinified.seriesText && fromExpanded.cover == fromMinified.cover)
    }

    @Test func progressMapsFinishedInProgressAndHidden() {
        let finished = ItemProgress(MediaProgress(id: "1", libraryItemId: "li", progress: 0.3, isFinished: true))
        #expect(finished.isFinished && finished.fraction == 1 && !finished.isInProgress)
        let partial = ItemProgress(
            MediaProgress(id: "2", libraryItemId: "li", progress: 0.4, hideFromContinueListening: true))
        #expect(partial.isInProgress && partial.fraction == 0.4 && partial.isHiddenFromContinue)
        #expect(ItemProgress(fraction: 7).fraction == 1)
        #expect(ItemProgress(fraction: -1).fraction == 0)
        #expect(ItemProgress(fraction: .nan).fraction == 0)
        #expect(!ItemProgress(fraction: 0).isInProgress)
    }

    @Test func sampleLibraryIsDeterministicAndMapsEveryItem() {
        #expect(SampleLibrary.books.count == 8)
        for item in SampleLibrary.books + SampleLibrary.episodeItems + [SampleLibrary.podcast] {
            #expect(!ItemSummary(item: item).title.isEmpty)
        }
        #expect(SampleLibrary.shelves.count == 5)
        #expect(ItemSummary(item: SampleLibrary.noCover).cover == nil)
        #expect(ItemSummary(item: SampleLibrary.missing).isMissing)
        #expect(ItemSummary(item: SampleLibrary.princessOfMars).seriesText == "Barsoom #1")
    }
}
