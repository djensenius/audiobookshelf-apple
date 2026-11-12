import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let labels = CarPlayLabels(
    continueListening: "Continue", libraries: "Libraries", books: "Books", podcasts: "Podcasts", series: "Series",
    authors: "Authors", more: "More…")
private let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

private func builder(items: Int = 12, sections: Int = 12, depth: Int = 5) -> CarPlayContentBuilder {
    CarPlayContentBuilder(
        limits: CarPlayLimits(maximumItemCount: items, maximumSectionCount: sections, maximumDepth: depth),
        labels: labels, serverID: serverID)
}

private func book(_ index: Int, missing: Bool = false) -> ItemSummary {
    ItemSummary(
        id: "b\(index)", itemID: "b\(index)", kind: .book, title: "Book \(index)", subtitle: "Author",
        cover: CoverRef(entityID: "b\(index)"), isMissing: missing)
}

private func books(_ count: Int) -> [ItemSummary] { (0..<count).map { book($0) } }

private func section(_ id: String, rows count: Int) -> CarPlaySection {
    CarPlaySection(
        id: id,
        rows: (0..<count).map {
            CarPlayRow(id: "\(id)-\($0)", text: "\($0)", action: .play(itemID: "\($0)", episodeID: nil))
        })
}

private let library = Library(id: "lib", name: "Audiobooks", mediaType: .book)
private let books3 = CarPlayDestination.items(libraryID: "lib")

@Suite struct CarPlayContentBuilderTests {
    // MARK: Pagination

    @Test func aPageThatFitsAndReachedTheEndHasNoMoreRow() {
        let list = builder(items: 4).items(books(4), reachedEnd: true, in: books3, title: "Books")
        #expect(list.rows.map(\.id) == ["b0", "b1", "b2", "b3"])
    }

    @Test func aLongerListEndsWithMoreToTheNextRow() {
        let list = builder(items: 4).items(books(10), reachedEnd: true, in: books3, title: "Books")
        #expect(list.rows.map(\.id) == ["b0", "b1", "b2", "more-3"])
        #expect(list.rows.last?.text == "More…")
        #expect(list.rows.last?.action == .more(books3, offset: 3))
    }

    @Test func moreShowsTheNextRowsAndTheLastPageEndsWithoutMore() {
        let builder = builder(items: 4)
        let second = builder.items(books(10), reachedEnd: true, in: books3, title: "Books", offset: 3)
        #expect(second.offset == 3)
        #expect(second.rows.map(\.id) == ["b3", "b4", "b5", "more-6"])
        let last = builder.items(books(10), reachedEnd: true, in: books3, title: "Books", offset: 6)
        #expect(last.rows.map(\.id) == ["b6", "b7", "b8", "b9"])
    }

    @Test func aModelThatHasntReachedItsEndKeepsMoreEvenWhenTheRowsFit() {
        let builder = builder(items: 4)
        let list = builder.items(books(2), reachedEnd: false, in: books3, title: "Books")
        #expect(list.rows.map(\.id) == ["b0", "b1", "more-2"])
        #expect(builder.rowsNeeded(offset: 2) == 6)
    }

    // MARK: Item limits and trimming

    @Test func everyListStaysWithinTheItemLimit() {
        for limit in [2, 5, 12] {
            let builder = builder(items: limit)
            for offset in [0, 1, 7] {
                let list = builder.items(books(30), reachedEnd: false, in: books3, title: "Books", offset: offset)
                #expect(list.rows.count == limit)
            }
            let continueList = builder.continueListening(
                sections: [
                    HomeSection(
                        id: "continue-listening", titleKey: nil, label: "", kind: .book,
                        entries: books(30).map { .item($0) })
                ],
                progress: { _ in nil })
            #expect(continueList.rows.count == limit)
        }
    }

    @Test func trimmingKeepsTheSectionAndItemLimitsInOrder() {
        let trimmed = builder(items: 5, sections: 2).trimmed([
            section("a", rows: 3), section("empty", rows: 0), section("b", rows: 3), section("c", rows: 1),
        ])
        #expect(trimmed.map(\.id) == ["a", "b"])
        #expect(trimmed.flatMap(\.rows).map(\.id) == ["a-0", "a-1", "a-2", "b-0", "b-1"])
    }

    @Test func theStandardLimitTrimsListsToTwelve() {
        let builder = CarPlayContentBuilder(labels: labels, serverID: serverID)
        #expect(builder.trimmed([section("a", rows: 20)]).flatMap(\.rows).count == 12)
    }

    // MARK: Depth

    @Test func theTreeStaysWithinFiveLevels() {
        let builder = builder()
        let root = builder.libraries([library])
        #expect(root.depth == 1)
        guard case .open(let libraryDestination) = root.rows.first?.action else {
            Issue.record("The library row doesn't open the library")
            return
        }
        #expect(libraryDestination.depth == 2)
        let categories = builder.library(library)
        #expect(categories.rows.map(\.text) == ["Books", "Series", "Authors"])
        let series = ItemSummary(id: "series-s", itemID: "b0", seriesID: "s", kind: .series, title: "Saga")
        let list = builder.items([series, book(1)], reachedEnd: true, in: books3, title: "Books")
        #expect(list.rows.first?.action == .open(.seriesBooks(libraryID: "lib", seriesID: "s")))
        #expect(list.rows.last?.action == .play(itemID: "b1", episodeID: nil))
        let opened = categories.rows.compactMap { row -> CarPlayDestination? in
            guard case .open(let destination) = row.action else { return nil }
            return destination
        }
        #expect(opened.allSatisfy { $0.depth <= 3 })
    }

    @Test func rowsThatWouldOpenAListDeeperThanTheLimitAreLeftOut() {
        let builder = builder(depth: 3)
        let series = ItemSummary(id: "series-s", itemID: "b0", seriesID: "s", kind: .series, title: "Saga")
        let list = builder.items([series, book(1)], reachedEnd: true, in: books3, title: "Books")
        #expect(list.rows.map(\.id) == ["b1"])
        let seriesList = builder.series(
            [SeriesSummary(id: "s", name: "Saga", bookCount: 2)], reachedEnd: true, libraryID: "lib")
        #expect(seriesList.rows.isEmpty)
        let tooDeep = builder.items(
            books(2), reachedEnd: true, in: .seriesBooks(libraryID: "lib", seriesID: "s"), title: "Saga")
        #expect(tooDeep.sections.isEmpty)
    }

    // MARK: Rows

    @Test func rowsCarryTitleImageAndStateButNoDescriptiveText() {
        let list = builder().items([book(0), book(1, missing: true)], reachedEnd: true, in: books3, title: "Books")
        let row = list.rows[0]
        #expect(row.text == "Book 0")
        #expect(row.image == CoverRef(entityID: "b0").key(serverID: serverID, bucket: .small))
        #expect(row.isEnabled)
        #expect(!list.rows[1].isEnabled)
    }

    @Test func continueListeningPlaysTheShelfsItemsWithTheirProgress() {
        let podcast = ItemSummary(id: "p", itemID: "p", kind: .podcast, title: "Show")
        let sections = [
            HomeSection(id: "recently-added", titleKey: nil, label: "", kind: .book, entries: [.item(book(9))]),
            HomeSection(
                id: "continue-listening", titleKey: nil, label: "", kind: .book,
                entries: [.item(book(0)), .item(podcast), .item(book(1))]),
        ]
        let list = builder().continueListening(sections: sections) { item in
            item.id == "b0" ? ItemProgress(fraction: 0.45) : nil
        }
        #expect(list.depth == 1)
        #expect(list.rows.map(\.id) == ["b0", "b1"])
        #expect(list.rows.map(\.progress) == [0.45, nil])
        #expect(list.rows.allSatisfy { if case .play = $0.action { true } else { false } })
    }

    @Test func aPodcastLibraryShowsPodcastsThatOpenTheirEpisodes() {
        let podcasts = Library(id: "pods", name: "Podcasts", mediaType: .podcast)
        let builder = builder()
        #expect(builder.library(podcasts).rows.map(\.action) == [.open(.items(libraryID: "pods"))])
        let show = ItemSummary(id: "p", itemID: "p", kind: .podcast, title: "Show")
        let list = builder.items([show], reachedEnd: true, in: .items(libraryID: "pods"), title: "Podcasts")
        #expect(list.rows.first?.action == .open(.podcastEpisodes(libraryID: "pods", itemID: "p")))
    }

    @Test func authorsOpenTheirBooksWithTheirImage() {
        let author = AuthorSummary(id: "a", name: "Mary Shelley", hasImage: true, imageUpdatedAt: 3)
        let list = builder().authors([author], reachedEnd: true, libraryID: "lib")
        #expect(list.rows.first?.action == .open(.authorBooks(libraryID: "lib", authorID: "a")))
        #expect(list.rows.first?.image == author.imageKey(serverID: serverID, bucket: .small))
    }
}
