import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private let book = #"{"id":"li1","libraryId":"lib1","mediaType":"book","media":{"id":"b1","metadata":{"title":"One"}}}"#
private let podcast =
    #"{"id":"li2","libraryId":"lib2","mediaType":"podcast","media":{"id":"p1","metadata":{"title":"Pod"}}}"#
private let episodeMatch =
    #"{"id":"li2","libraryId":"lib2","mediaType":"podcast","media":{"id":"p1","metadata":{"title":"Pod"}},"#
    + #""recentEpisode":{"id":"ep7","libraryItemId":"li2","title":"Match"}}"#

@Suite struct LibraryResponseDecodingTests {
    @Test func librariesSkipMalformedEntries() throws {
        let response = try decode(
            LibrariesResponse.self,
            #"{"libraries":[{"id":"lib1","name":"Books","mediaType":"book"},{"id":"broken"}]}"#)
        #expect(response.libraries.map(\.id) == ["lib1"])
    }

    @Test func librariesRequireTheList() throws {
        #expect(throws: DecodingError.self) { try decode(LibrariesResponse.self, #"{}"#) }
        #expect(try decode(LibrariesResponse.self, #"{"libraries":[]}"#).libraries.isEmpty)
    }

    @Test func libraryWithFilterData() throws {
        let response = try decode(
            LibraryWithFilterData.self,
            #"""
            {"filterdata":{"authors":[{"id":"aut1","name":"Ann"}],"series":[{"id":"ser1","name":"Saga"}],
             "genres":["Fantasy"],"tags":[],"narrators":["Ned"],"languages":["en"],"publishers":["Pub"],
             "publishedDecades":["1990"],"bookCount":3,"numIssues":2,"loadedAt":1700000000000},
             "issues":2,"numUserPlaylists":1,"library":{"id":"lib1","name":"Books","mediaType":"book"}}
            """#)
        #expect(response.library.id == "lib1")
        #expect(response.issues == 2)
        #expect(response.numUserPlaylists == 1)
        #expect(response.filterData.authors.map(\.name) == ["Ann"])
        #expect(response.filterData.series.map(\.id) == ["ser1"])
        #expect(response.filterData.genres == ["Fantasy"])
        #expect(response.filterData.narrators == ["Ned"])
        #expect(response.filterData.publishedDecades == ["1990"])
        #expect(response.filterData.numIssues == 2)
        #expect(response.filterData.loadedAt == 1_700_000_000_000)
    }

    @Test func podcastFilterDataDefaultsMissingGroups() throws {
        let response = try decode(
            LibraryWithFilterData.self,
            #"{"filterdata":{"genres":["News"],"tags":["daily"]},"library":{"id":"lib2","name":"Pods","mediaType":"podcast"}}"#
        )
        #expect(response.filterData.tags == ["daily"])
        #expect(response.filterData.authors.isEmpty)
        #expect(response.issues == 0)
    }

    @Test(arguments: [
        ("issues", #""not-an-integer""#),
        ("numUserPlaylists", "true"),
        ("numIssues", "{}"),
        ("loadedAt", "[]"),
    ])
    func malformedFilterMetadataPreservesSiblings(field: String, value: String) throws {
        let issues = field == "issues" ? value : "2"
        let playlists = field == "numUserPlaylists" ? value : "1"
        let numIssues = field == "numIssues" ? value : "3"
        let loadedAt = field == "loadedAt" ? value : "1700000000000"
        let response = try decode(
            LibraryWithFilterData.self,
            #"""
            {"library":{"id":"lib1","name":"Books","mediaType":"book"},
             "issues":\#(issues),"numUserPlaylists":\#(playlists),
             "filterdata":{"authors":[{"id":"aut1","name":"Ann"}],"series":[{"id":"ser1","name":"Saga"}],
              "genres":["Fantasy"],"tags":["daily"],"numIssues":\#(numIssues),"loadedAt":\#(loadedAt)}}
            """#)
        #expect(response.library.id == "lib1")
        #expect(response.issues == (field == "issues" ? 0 : 2))
        #expect(response.numUserPlaylists == (field == "numUserPlaylists" ? 0 : 1))
        #expect(response.filterData.numIssues == (field == "numIssues" ? 0 : 3))
        #expect(response.filterData.loadedAt == (field == "loadedAt" ? nil : 1_700_000_000_000))
        #expect(response.filterData.authors.map(\.name) == ["Ann"])
        #expect(response.filterData.series.map(\.id) == ["ser1"])
        #expect(response.filterData.genres == ["Fantasy"])
        #expect(response.filterData.tags == ["daily"])
    }

    @Test func filterMetadataAcceptsNumericStrings() throws {
        let response = try decode(
            LibraryWithFilterData.self,
            #"""
            {"library":{"id":"lib1","name":"Books","mediaType":"book"},
             "issues":"2","numUserPlaylists":"1",
             "filterdata":{"genres":["Fantasy"],"numIssues":"3","loadedAt":"1700000000000"}}
            """#)
        #expect(response.library.id == "lib1")
        #expect(response.issues == 2)
        #expect(response.numUserPlaylists == 1)
        #expect(response.filterData.numIssues == 3)
        #expect(response.filterData.loadedAt == 1_700_000_000_000)
        #expect(response.filterData.genres == ["Fantasy"])
    }

    @Test(arguments: [
        "",
        #""filterdata":null,"#,
        #""filterdata":7,"#,
        #""filterdata":[],"#,
        #""filterdata":{"genres":7,"tags":["daily"]},"#,
    ])
    func unusableFilterDataDefaultsWholeObject(member: String) throws {
        let response = try decode(
            LibraryWithFilterData.self,
            #"""
            {\#(member)"library":{"id":"lib1","name":"Books","mediaType":"book"},
             "issues":2,"numUserPlaylists":1}
            """#)
        #expect(response.library.id == "lib1")
        #expect(response.issues == 2)
        #expect(response.numUserPlaylists == 1)
        #expect(response.filterData == LibraryFilterData())
    }

    @Test(arguments: [
        "",
        #""library":null,"#,
        #""library":[],"#,
        #""library":{"name":"Books","mediaType":"book"},"#,
        #""library":{"id":7,"name":"Books","mediaType":"book"},"#,
    ])
    func filterMetadataDoesNotHideInvalidRequiredLibrary(member: String) throws {
        #expect(throws: DecodingError.self) {
            try decode(
                LibraryWithFilterData.self,
                #"{\#(member)"filterdata":7,"issues":"invalid","numUserPlaylists":1}"#)
        }
    }

    @Test func pagedResultsAcceptStringPagingAndSkipBadResults() throws {
        let page = try decode(
            PagedResults<LibraryItem>.self,
            #"{"results":[\#(book),{"id":"bad"}],"total":40,"limit":"20","page":"1","sortBy":"addedAt"}"#)
        #expect(page.results.map(\.id) == ["li1"])
        #expect(page.rawCount == 2)
        #expect(page.total == 40)
        #expect(page.limit == 20)
        #expect(page.page == 1)
    }

    @Test func pagedResultsCountRowsThatFailToDecode() throws {
        let malformed = try decode(
            PagedResults<LibraryItem>.self, #"{"results":[{"id":"bad"},7,null],"total":40,"limit":3,"page":0}"#)
        #expect(malformed.results.isEmpty)
        #expect(malformed.rawCount == 3)
        let missing = try decode(PagedResults<LibraryItem>.self, #"{"total":0,"limit":3,"page":0}"#)
        #expect(missing.rawCount == 0)
    }

    @Test func pagedResultsWithoutTotalOrPaging() throws {
        let page = try decode(
            PagedResults<Series>.self, #"{"results":[{"id":"ser1","name":"Saga"}],"limit":0,"page":0}"#)
        #expect(page.results.map(\.name) == ["Saga"])
        #expect(page.rawCount == 1)
        #expect(page.total == nil)
        #expect(page.limit == 0)
    }

    @Test func pagedPlaylistsAndCollections() throws {
        let playlists = try decode(
            PagedResults<Playlist>.self,
            #"{"results":[{"id":"pl1","libraryId":"lib1","name":"Mine","items":[{"libraryItemId":"li1"}]}],"total":1,"limit":0,"page":0}"#
        )
        #expect(playlists.results.first?.items.map(\.libraryItemId) == ["li1"])
        let collections = try decode(
            PagedResults<LibraryCollection>.self,
            #"{"results":[{"id":"col1","libraryId":"lib1","name":"Faves","books":[\#(book)]}],"total":1,"limit":0,"page":0}"#
        )
        #expect(collections.results.first?.books?.map(\.id) == ["li1"])
    }

    @Test func personalizedShelvesAreLossy() throws {
        let shelves = try decode(
            LossyArray<Shelf>.self,
            #"[{"id":"continue-listening","label":"Continue Listening","type":"book","entities":[\#(book)]},{"id":"x"}]"#
        )
        #expect(shelves.elements.map(\.id) == ["continue-listening"])
    }

    @Test func authors() throws {
        let response = try decode(
            AuthorsResponse.self, #"{"authors":[{"id":"aut1","name":"Ann","numBooks":3,"lastFirst":"Ann"}]}"#)
        #expect(response.authors.first?.numBooks == 3)
    }

    @Test func recentEpisodes() throws {
        let page = try decode(
            RecentEpisodesPage.self,
            #"""
            {"episodes":[{"id":"ep1","libraryItemId":"li2","title":"Ep 1","libraryId":"lib2",
              "podcast":{"id":"p1","metadata":{"title":"Pod"},"episodes":[]}}],"limit":"50","page":"0"}
            """#)
        let episode = try #require(page.episodes.first)
        #expect(episode.id == "ep1")
        #expect(episode.episode.title == "Ep 1")
        #expect(episode.podcast?.metadata.title == "Pod")
        #expect(episode.libraryId == "lib2")
        #expect(page.limit == 50)
    }

    @Test func recentEpisodeKeepsEpisodeWhenPodcastIsMalformed() throws {
        let page = try decode(
            RecentEpisodesPage.self, #"{"episodes":[{"id":"ep1","title":"Ep 1","podcast":{"id":"p1"}}],"limit":50}"#)
        #expect(page.episodes.map(\.id) == ["ep1"])
        #expect(page.episodes.first?.podcast == nil)
        #expect(page.rawCount == 1)
    }

    @Test func recentEpisodesCountAnEntirelyMalformedFullPage() throws {
        // Derived unit payload, not a server capture: a full wire page must not look exhausted.
        let page = try decode(
            RecentEpisodesPage.self, #"{"episodes":[{"title":"Missing ID"},7,null],"limit":"3","page":"2"}"#)
        #expect(page.episodes.isEmpty)
        #expect(page.rawCount == 3)
        #expect(page.rawCount == page.limit)
        #expect(page.page == 2)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"episodes":null,"limit":null,"page":null}"#,
        #"{"episodes":[],"limit":"not-an-integer","page":{}}"#,
    ])
    func recentEpisodesDefaultMissingNullAndInvalidPaging(json: String) throws {
        let page = try decode(RecentEpisodesPage.self, json)
        #expect(page.episodes.isEmpty)
        #expect(page.rawCount == 0)
        #expect(page.limit == 0)
        #expect(page.page == 0)
    }

    @Test func bookSearchResults() throws {
        let results = try decode(
            LibrarySearchResults.self,
            #"""
            {"book":[{"libraryItem":\#(book)},{"libraryItem":{"id":"bad"}}],
             "narrators":[{"name":"Ned","numBooks":2}],"tags":[{"name":"epic","numItems":4}],"genres":[],
             "series":[{"series":{"id":"ser1","name":"Saga"},"books":[\#(book)]}],
             "authors":[{"id":"aut1","name":"Ann","numBooks":1}]}
            """#)
        #expect(results.books.map(\.id) == ["li1"])
        #expect(results.narrators == [LibrarySearchResults.NameMatch(name: "Ned", count: 2)])
        #expect(results.tags == [LibrarySearchResults.NameMatch(name: "epic", count: 4)])
        #expect(results.series.first?.series.name == "Saga")
        #expect(results.series.first?.books.map(\.id) == ["li1"])
        #expect(results.authors.map(\.id) == ["aut1"])
        #expect(results.podcasts.isEmpty)
    }

    @Test func podcastSearchResults() throws {
        let results = try decode(
            LibrarySearchResults.self,
            #"{"podcast":[{"libraryItem":\#(podcast)}],"episodes":[{"libraryItem":\#(episodeMatch)}],"tags":[],"genres":[]}"#
        )
        #expect(results.podcasts.map(\.id) == ["li2"])
        #expect(results.episodes.map(\.id) == ["li2"])
        #expect(results.episodes.first?.recentEpisode?.id == "ep7")
        #expect(results.episodes.first?.recentEpisode?.title == "Match")
        #expect(results.books.isEmpty)
        #expect(results.series.isEmpty)
    }
}
