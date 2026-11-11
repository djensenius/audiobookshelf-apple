import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct SearchResultGroupsTests {
    @Test func bookLibrarySectionsAndRoutes() throws {
        let results = try decodeSearch(
            #"""
            {"book":[{"libraryItem":\#(searchBook)}],
             "series":[{"series":{"id":"ser1","name":"Saga"},"books":[\#(searchBook)]}],
             "authors":[{"id":"aut1","name":"Ann","numBooks":3}],
             "narrators":[{"name":"Ned","numBooks":2}],"tags":[{"name":"epic","numItems":4}],
             "genres":[{"name":"Fantasy","numItems":5}]}
            """#)

        let groups = SearchResultGroups(results)

        #expect(groups.sections.map(\.kind) == [.books, .series, .authors, .narrators, .tags])
        let book = try #require(groups.rows(.books).first)
        let summary = try #require(book.item)
        #expect(summary.kind == .book)
        #expect(summary.title == "One")
        #expect(book.route == .item(id: "li1"))

        let series = try #require(groups.rows(.series).first)
        #expect(series.content == .series(SeriesSummary(id: "ser1", name: "Saga", bookCount: 1)))
        #expect(series.route == .series(id: "ser1"))

        let author = try #require(groups.rows(.authors).first)
        #expect(author.content == .author(AuthorSummary(id: "aut1", name: "Ann", bookCount: 3)))
        #expect(author.route == .author(id: "aut1"))

        #expect(groups.rows(.narrators).map(\.content) == [.name("Ned", count: 2)])
        #expect(groups.rows(.narrators).map(\.route) == [.libraryFilter(kind: .narrators, value: "Ned")])
        #expect(groups.rows(.tags).map(\.content) == [.name("epic", count: 4)])
        #expect(groups.rows(.tags).map(\.route) == [.libraryFilter(kind: .tags, value: "epic")])
    }

    @Test func podcastLibrarySectionsAndRoutes() throws {
        let noEpisode =
            #"{"id":"li3","libraryId":"pods","mediaType":"podcast","media":{"id":"p3","metadata":{"title":"X"}}}"#
        let results = try decodeSearch(
            #"""
            {"podcast":[{"libraryItem":\#(searchPodcast)}],
             "episodes":[{"libraryItem":\#(searchEpisode)},{"libraryItem":\#(noEpisode)}],
             "tags":[{"name":"news","numItems":1}],"genres":[]}
            """#)

        let groups = SearchResultGroups(results)

        #expect(groups.sections.map(\.kind) == [.podcasts, .episodes, .tags])
        let podcast = try #require(groups.rows(.podcasts).first)
        let show = try #require(podcast.item)
        #expect(show.kind == .podcast)
        #expect(podcast.route == .item(id: "li2"))

        // A match without its episode can't open one, so it's skipped.
        let episodes = groups.rows(.episodes)
        #expect(episodes.map(\.route) == [.episode(itemID: "li2", episodeID: "ep7")])
        let episode = try #require(episodes.first?.item)
        #expect(episode.kind == .episode)
        #expect(episode.title == "Match")
        #expect(episode.subtitle == "Pod")
        #expect(groups.rows(.tags).map(\.route) == [.libraryFilter(kind: .tags, value: "news")])
    }

    @Test func noMatchesAreEmpty() throws {
        #expect(SearchResultGroups(try decodeSearch(#"{"book":[],"genres":[{"name":"G","numItems":1}]}"#)).isEmpty)
    }
}

extension SearchResultRow {
    fileprivate var item: ItemSummary? {
        guard case .item(let item) = content else { return nil }
        return item
    }
}
