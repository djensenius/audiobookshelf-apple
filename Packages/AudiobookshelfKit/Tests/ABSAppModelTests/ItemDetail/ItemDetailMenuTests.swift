import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// An ``ItemDetailService`` that answers with the item until `fails` holds an error.
private struct MenuItemService: ItemDetailService {
    let item: LibraryItem
    let fails = Locked<APIError?>(nil)

    func item(id: String) async throws -> LibraryItem {
        if let error = fails.value { throw error }
        return item
    }
}

private func makeBook(isMissing: Bool = false, isInvalid: Bool = false) -> LibraryItem {
    let book = Book(
        id: "book", libraryItemId: "li-1", metadata: BookMetadata(title: "The Book"),
        tracks: [AudioTrack(index: 1, duration: 600)], duration: 600)
    return LibraryItem(
        id: "li-1", libraryId: "lib", isMissing: isMissing, isInvalid: isInvalid, mediaType: .book,
        media: .book(book))
}

private func progress(
    _ fraction: Double = 0, finished: Bool = false, hidden: Bool = false, ebook: Double? = nil
) -> MediaProgress {
    MediaProgress(
        id: "mp-1", libraryItemId: "li-1", duration: 600, progress: fraction, currentTime: fraction * 600,
        isFinished: finished, hideFromContinueListening: hidden, ebookProgress: ebook, lastUpdate: 1)
}

@MainActor
private func loadedModel(
    _ item: LibraryItem = makeBook(), progress: MediaProgress? = nil
) async -> ItemDetailModel {
    let cache = ProgressCache()
    if let progress { cache.apply(progress) }
    let model = ItemDetailModel(itemID: item.id, service: MenuItemService(item: item), cache: cache)
    await model.load()
    return model
}

@MainActor
@Suite struct ItemDetailMenuTests {
    @Test func notLoadedHasNoActions() async {
        let model = ItemDetailModel(itemID: "li-1", service: MenuItemService(item: makeBook()), cache: ProgressCache())
        #expect(model.menuActions(canEditPlaylists: true, canShare: true, isGone: false).isEmpty)

        let podcast = LibraryItem(
            id: "li-1", libraryId: "lib", mediaType: .podcast,
            media: .podcast(Podcast(id: "pod", metadata: PodcastMetadata(title: "Show"))))
        #expect(await loadedModel(podcast).menuActions(canEditPlaylists: true, canShare: true, isGone: false).isEmpty)
    }

    @Test func unstartedOffersMarkFinishedDetailsHistory() async {
        let model = await loadedModel()
        #expect(
            model.menuActions(canEditPlaylists: false, canShare: false, isGone: false) == [
                .markFinished, .details, .history,
            ])
    }

    @Test func inProgressAddsDiscardAndHide() async {
        let model = await loadedModel(progress: progress(0.4))
        #expect(
            model.menuActions(canEditPlaylists: false, canShare: false, isGone: false) == [
                .markFinished, .discardProgress, .hideFromContinueListening, .details, .history,
            ])
    }

    @Test func finishedOffersMarkNotFinishedAndDiscard() async {
        let model = await loadedModel(progress: progress(1, finished: true))
        #expect(
            model.menuActions(canEditPlaylists: false, canShare: false, isGone: false) == [
                .markNotFinished, .discardProgress, .details, .history,
            ])
    }

    @Test func hiddenProgressOmitsHide() async {
        let model = await loadedModel(progress: progress(0.4, hidden: true))
        #expect(
            !model.menuActions(canEditPlaylists: false, canShare: false, isGone: false).contains(
                .hideFromContinueListening))
        #expect(model.menuActions(canEditPlaylists: false, canShare: false, isGone: false).contains(.discardProgress))
    }

    @Test func ebookOnlyProgressOffersDiscard() async {
        let model = await loadedModel(progress: progress(0, ebook: 0.25))
        #expect(model.menuActions(canEditPlaylists: false, canShare: false, isGone: false).contains(.discardProgress))
        #expect(model.confirmationMessageKey(for: .markFinished) == "MessageConfirmMarkAsFinished")
    }

    @Test func missingItemOffersNoProgressActions() async {
        for item in [makeBook(isMissing: true), makeBook(isInvalid: true)] {
            let model = await loadedModel(item, progress: progress(0.4))
            #expect(
                model.menuActions(canEditPlaylists: true, canShare: true, isGone: false) == [
                    .share, .details, .history,
                ])
        }

        // Deleted on the server since it loaded: the reload answered 404.
        let service = MenuItemService(item: makeBook())
        let cache = ProgressCache()
        cache.apply(progress(0.4))
        let model = ItemDetailModel(itemID: "li-1", service: service, cache: cache)
        await model.load()
        service.fails.value = .notFound
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.menuActions(canEditPlaylists: true, canShare: false, isGone: false) == [.details, .history])

        // A retry that fails another way leaves the model's 404 behind, so the screen passes the
        // 404 it remembers (`ItemDetailGoneState`): still only Share, More info and History.
        service.fails.value = .timedOut
        await model.load()
        #expect(
            model.menuActions(canEditPlaylists: true, canShare: true, isGone: true) == [.share, .details, .history])

        // Loaded again: the actions come back.
        service.fails.value = nil
        await model.load()
        #expect(model.menuActions(canEditPlaylists: false, canShare: false, isGone: false).first == .markFinished)
    }

    @Test func playlistOnlyWhenEditable() async {
        let model = await loadedModel()
        #expect(!model.menuActions(canEditPlaylists: false, canShare: true, isGone: false).contains(.addToPlaylist))
        #expect(
            model.menuActions(canEditPlaylists: true, canShare: true, isGone: false) == [
                .markFinished, .addToPlaylist, .share, .details, .history,
            ])
    }

    @Test func shareOnlyWhenAvailable() async {
        let model = await loadedModel()
        #expect(!model.menuActions(canEditPlaylists: false, canShare: false, isGone: false).contains(.share))
        #expect(model.menuActions(canEditPlaylists: false, canShare: true, isGone: false).contains(.share))
    }

    @Test func confirmationKeys() async {
        // Nothing to overwrite: no question.
        #expect(await loadedModel().confirmationMessageKey(for: .markFinished) == nil)
        #expect(await loadedModel().confirmationMessageKey(for: .discardProgress) == "MessageConfirmDiscardProgress")

        let inProgress = await loadedModel(progress: progress(0.4))
        #expect(inProgress.confirmationMessageKey(for: .markFinished) == "MessageConfirmMarkAsFinished")
        #expect(inProgress.confirmationMessageKey(for: .discardProgress) == "MessageConfirmDiscardProgress")
        for action in [ItemDetailMenuAction.markNotFinished, .hideFromContinueListening, .share, .details, .history] {
            #expect(inProgress.confirmationMessageKey(for: action) == nil)
        }

        let finished = await loadedModel(progress: progress(1, finished: true))
        #expect(finished.confirmationMessageKey(for: .markNotFinished) == nil)
    }

    @Test func webURLKeepsSubpathAndEncodesID() throws {
        let root = try #require(URL(string: "https://abs.example.com"))
        #expect(
            ItemDetailModel.webURL(serverURL: root, itemID: "li_1").absoluteString
                == "https://abs.example.com/item/li_1")

        let subpath = try #require(URL(string: "https://example.com/audiobookshelf/"))
        #expect(
            ItemDetailModel.webURL(serverURL: subpath, itemID: "a/b c?").absoluteString
                == "https://example.com/audiobookshelf/item/a%2Fb%20c%3F")
    }
}
