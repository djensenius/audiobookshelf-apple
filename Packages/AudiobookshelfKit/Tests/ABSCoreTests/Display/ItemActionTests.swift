import Testing

@testable import ABSCore

@Suite struct ItemActionTests {
    private func summary(
        kind: ItemKind = .book, missing: Bool = false, audio: Bool = true
    ) -> ItemSummary {
        ItemSummary(
            id: "i", itemID: "i", episodeID: kind == .episode ? "e" : nil, kind: kind, title: "T",
            isMissing: missing, hasAudio: audio)
    }

    private func kinds(
        _ item: ItemSummary, _ progress: ItemProgress? = nil, canEditPlaylists: Bool = false
    ) -> [ItemActionKind] {
        ItemAction.available(
            for: item, progress: progress, context: ItemActionContext(canEditPlaylists: canEditPlaylists)
        )
        .map(\.kind)
    }

    @Test func notStartedBookCanBePlayedAndMarkedFinished() {
        #expect(kinds(summary()) == [.play, .markFinished, .share, .openDetails])
        #expect(kinds(summary(), ItemProgress(fraction: 0)) == [.play, .markFinished, .share, .openDetails])
    }

    @Test func inProgressBookCanAlsoBeHiddenFromContinueListening() {
        #expect(
            kinds(summary(), ItemProgress(fraction: 0.4))
                == [.play, .markFinished, .hideFromContinueListening, .share, .openDetails])
    }

    @Test func hiddenBookOffersNoSecondHide() {
        let hidden = ItemProgress(fraction: 0.4, isHiddenFromContinue: true)
        #expect(kinds(summary(), hidden) == [.play, .markFinished, .share, .openDetails])
    }

    @Test func finishedBookOffersMarkNotFinishedAndNoHide() {
        let finished = ItemProgress(fraction: 1, isFinished: true)
        #expect(kinds(summary(), finished) == [.play, .markNotFinished, .share, .openDetails])
    }

    @Test func addToPlaylistNeedsThePlaylistContext() {
        #expect(!kinds(summary()).contains(.addToPlaylist))
        #expect(kinds(summary(), canEditPlaylists: true).contains(.addToPlaylist))
        #expect(!kinds(summary(kind: .series), canEditPlaylists: true).contains(.addToPlaylist))
    }

    @Test func itemWithoutAudioCannotBePlayedButCanBeMarked() {
        #expect(kinds(summary(audio: false)) == [.markFinished, .share, .openDetails])
    }

    @Test func missingItemOnlyOpens() {
        let item = summary(missing: true)
        #expect(kinds(item, ItemProgress(fraction: 0.5), canEditPlaylists: true) == [.openDetails])
    }

    @Test func podcastCanOnlyBeSharedAndOpened() {
        #expect(kinds(summary(kind: .podcast, audio: false), canEditPlaylists: true) == [.share, .openDetails])
    }

    @Test func episodeBehavesLikeABook() {
        #expect(
            kinds(summary(kind: .episode), ItemProgress(fraction: 0.2), canEditPlaylists: true)
                == [.play, .markFinished, .hideFromContinueListening, .addToPlaylist, .share, .openDetails])
    }

    @Test func collapsedSeriesOnlyOpens() {
        #expect(kinds(summary(kind: .series, audio: false), ItemProgress(fraction: 0.5)) == [.openDetails])
        #expect(
            kinds(summary(kind: .series, audio: false), ItemProgress(fraction: 1, isFinished: true)) == [.openDetails])
    }

    @Test func actionsAreInMenuOrderWithoutDuplicates() {
        let all = kinds(summary(kind: .episode), ItemProgress(fraction: 0.2), canEditPlaylists: true)
        #expect(all == ItemActionKind.allCases.filter(all.contains))
        #expect(Set(all).count == all.count)
    }
}
