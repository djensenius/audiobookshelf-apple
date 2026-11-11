import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private func progress(
    _ itemID: String, episode: String? = nil, hidden: Bool = false, finished: Bool = false
) -> MediaProgress {
    MediaProgress(
        id: "p-\(itemID)-\(episode ?? "")", libraryItemId: itemID, episodeId: episode, progress: finished ? 1 : 0.5,
        isFinished: finished, hideFromContinueListening: hidden, lastUpdate: 10)
}

/// Sections for `shelves` with `progress` as the only known progress.
private func sections(_ shelves: [Shelf], progress: [MediaProgress] = []) -> [HomeSection] {
    let byKey = Dictionary(uniqueKeysWithValues: progress.map { ($0.progressKey, $0) })
    return HomeSection.sections(from: shelves) { itemID, episodeID in
        byKey[MediaProgress.key(libraryItemID: itemID, episodeID: episodeID)]
    }
}

private func itemIDs(_ section: HomeSection?) -> [String] {
    section?.entries.map(\.id) ?? []
}

private let books = [SampleLibrary.frankenstein, SampleLibrary.sherlock, SampleLibrary.emma]

@Suite struct HomeSectionTests {
    @Test func mapsEveryShelfType() {
        let result = sections([
            Shelf(
                id: "continue-listening", label: "Continue Listening", labelStringKey: "LabelContinueListening",
                type: .book, entities: .libraryItems(books)),
            Shelf(
                id: "recently-added", label: "Recently Added", type: .podcast,
                entities: .libraryItems([SampleLibrary.podcast])),
            Shelf(
                id: "newest-episodes", label: "Newest Episodes", type: .episode,
                entities: .libraryItems(SampleLibrary.episodeItems)),
            Shelf(id: "recent-series", label: "Recent Series", type: .series, entities: .series(SampleLibrary.series)),
            Shelf(
                id: "newest-authors", label: "Newest Authors", type: .authors,
                entities: .authors(SampleLibrary.authors)),
        ])

        #expect(
            result.map(\.id) == [
                "continue-listening", "recently-added", "newest-episodes", "recent-series", "newest-authors",
            ])
        #expect(result.map(\.kind) == [.book, .podcast, .episode, .series, .authors])
        #expect(result[0].titleKey == "LabelContinueListening")
        #expect(result[0].label == "Continue Listening")
        #expect(result[1].titleKey == nil)
        #expect(result[0].entries == books.map { .item(ItemSummary(item: $0)) })
        #expect(result[1].entries == [.item(ItemSummary(item: SampleLibrary.podcast))])
        #expect(itemIDs(result[2]) == ["li_podcast-ep_2", "li_podcast-ep_1"])
        guard case .item(let episode) = result[2].entries.first else {
            Issue.record("expected an item")
            return
        }
        #expect(episode.kind == .episode)
        #expect(result[3].entries == SampleLibrary.series.map { .series(SeriesSummary(series: $0)) })
        #expect(result[4].entries == SampleLibrary.authors.map { .author(AuthorSummary(author: $0)) })
    }

    @Test func dropsUnknownMismatchedAndEmptyShelves() {
        let result = sections([
            Shelf(id: "future", label: "Future", type: .unknown("future"), entities: .unknown),
            Shelf(id: "empty", label: "Empty", type: .book, entities: .libraryItems([])),
            Shelf(id: "no-series", label: "No Series", type: .series, entities: .series([])),
            Shelf(id: "mismatched", label: "Mismatched", type: .authors, entities: .series(SampleLibrary.series)),
            Shelf(id: "recently-added", label: "Recently Added", type: .book, entities: .libraryItems(books)),
        ])
        #expect(result.map(\.id) == ["recently-added"])
    }

    @Test func hiddenAndFinishedItemsLeaveContinueShelvesOnly() {
        let shelves = [
            Shelf(id: "continue-listening", label: "", type: .book, entities: .libraryItems(books)),
            Shelf(id: "continue-reading", label: "", type: .book, entities: .libraryItems(books)),
            Shelf(id: "continue-series", label: "", type: .book, entities: .libraryItems(books)),
            Shelf(id: "recently-added", label: "", type: .book, entities: .libraryItems(books)),
        ]
        let result = sections(
            shelves,
            progress: [
                progress(SampleLibrary.frankenstein.id, hidden: true),
                progress(SampleLibrary.sherlock.id, finished: true),
                progress(SampleLibrary.emma.id),
            ])

        let all = books.map(\.id)
        #expect(itemIDs(result.first { $0.id == "continue-listening" }) == [SampleLibrary.emma.id])
        #expect(itemIDs(result.first { $0.id == "continue-reading" }) == [SampleLibrary.emma.id])
        #expect(itemIDs(result.first { $0.id == "continue-series" }) == all)
        #expect(itemIDs(result.first { $0.id == "recently-added" }) == all)
    }

    @Test func hiddenEpisodesLeaveContinueListening() {
        let shelves = [
            Shelf(
                id: "continue-listening", label: "", type: .episode, entities: .libraryItems(SampleLibrary.episodeItems)
            ),
            Shelf(
                id: "newest-episodes", label: "", type: .episode, entities: .libraryItems(SampleLibrary.episodeItems)),
        ]
        // Progress of the podcast as a whole doesn't hide its episodes.
        let result = sections(
            shelves,
            progress: [progress("li_podcast", episode: "ep_2", hidden: true), progress("li_podcast", hidden: true)])
        #expect(result.map(itemIDs) == [["li_podcast-ep_1"], ["li_podcast-ep_2", "li_podcast-ep_1"]])
    }

    @Test func aContinueShelfWithEveryItemHiddenIsDropped() {
        let shelf = Shelf(
            id: "continue-listening", label: "", type: .book, entities: .libraryItems([SampleLibrary.frankenstein]))
        #expect(sections([shelf], progress: [progress(SampleLibrary.frankenstein.id, finished: true)]).isEmpty)
        // Without progress in the cache (not seeded yet), the server's shelf is shown as is.
        #expect(sections([shelf]).map(\.id) == ["continue-listening"])
    }
}
