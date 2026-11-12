import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI
import Testing

@testable import Audiobookshelf

/// Records the progress actions the More menu sends; each can be made to throw.
@MainActor
private final class RecordingMenuActions: ItemActionPerforming {
    struct Failure: Error {}

    var calls: [(String, ItemActionTarget)] = []
    var error: (any Error)?

    func markFinished(_ target: ItemActionTarget) async throws { try record("markFinished", target) }
    func markNotFinished(_ target: ItemActionTarget) async throws { try record("markNotFinished", target) }
    func hideFromContinueListening(_ target: ItemActionTarget) async throws { try record("hide", target) }
    func discardProgress(_ target: ItemActionTarget) async throws { try record("discard", target) }

    private func record(_ name: String, _ target: ItemActionTarget) throws {
        calls.append((name, target))
        if let error { throw error }
    }
}

/// Serves the item until told to fail.
private actor SwitchableItemService: ItemDetailService {
    let item: ABSCore.LibraryItem
    private var error: (any Error)?

    init(item: ABSCore.LibraryItem) {
        self.item = item
    }

    func fail(with error: (any Error)?) {
        self.error = error
    }

    func item(id: String) async throws -> ABSCore.LibraryItem {
        if let error { throw error }
        return item
    }
}

private let book = ItemSummary(id: "li-1", itemID: "li-1", kind: .book, title: "The Book", duration: 600)
private let target = ItemActionTarget(libraryItemID: "li-1", duration: 600)
private let english = Locale(identifier: "en")

@MainActor
@Suite struct ItemDetailMenuPresentationTests {
    @Test func marksRouteThroughItemCardActions() async {
        let actions = RecordingMenuActions()
        for action in [ItemDetailMenuAction.markFinished, .markNotFinished, .hideFromContinueListening] {
            #expect(await ItemDetailMenuPresentation.perform(action, on: book, actions: actions) == nil)
        }
        #expect(actions.calls.map(\.0) == ["markFinished", "markNotFinished", "hide"])
        #expect(actions.calls.allSatisfy { $0.1 == target })
    }

    @Test func discardCallsDiscardProgressWithTarget() async {
        let actions = RecordingMenuActions()
        #expect(await ItemDetailMenuPresentation.perform(.discardProgress, on: book, actions: actions) == nil)
        #expect(actions.calls.map(\.0) == ["discard"])
        #expect(actions.calls.first?.1 == target)
    }

    @Test func viewActionsAreNotPerformedHere() async {
        let actions = RecordingMenuActions()
        for action in [ItemDetailMenuAction.addToPlaylist, .share, .details, .history] {
            #expect(await ItemDetailMenuPresentation.perform(action, on: book, actions: actions) == nil)
        }
        #expect(actions.calls.isEmpty)
    }

    @Test func failureReturnsKeyPerAction() async {
        let actions = RecordingMenuActions()
        actions.error = RecordingMenuActions.Failure()
        let expected: [(ItemDetailMenuAction, String)] = [
            (.markFinished, "ToastItemMarkedAsFinishedFailed"),
            (.markNotFinished, "ToastItemMarkedAsNotFinishedFailed"),
            (.hideFromContinueListening, "MessageHideFromContinueListeningFailed"),
            (.discardProgress, "MessageItemDetailDiscardProgressFailed"),
        ]
        for (action, key) in expected {
            #expect(await ItemDetailMenuPresentation.perform(action, on: book, actions: actions) == key)
            #expect(L10n.string(key) != key)
        }
    }

    @Test func cancellationReturnsNil() async {
        let actions = RecordingMenuActions()
        actions.error = CancellationError()
        for action in [
            ItemDetailMenuAction.markFinished, .markNotFinished, .hideFromContinueListening, .discardProgress,
        ] {
            #expect(await ItemDetailMenuPresentation.perform(action, on: book, actions: actions) == nil)
        }
        #expect(actions.calls.count == 4)
    }

    @Test func goneItemKeepsProgressActionsOffUntilItLoads() async {
        let service = SwitchableItemService(item: ItemDetailPreviewData.book)
        let cache = ProgressCache()
        cache.apply(ItemDetailPreviewData.inProgress)
        let model = ItemDetailModel(itemID: ItemDetailPreviewData.book.id, service: service, cache: cache)
        var gone = ItemDetailGoneState()
        // What the menu offers, and what a confirmed action is checked against.
        func actions() -> [ItemDetailMenuAction] {
            let snapshot = ItemDetailGoneState.Snapshot(model: model)
            gone.update(snapshot)
            return ItemDetailMenuPresentation.actions(
                for: model, isGone: gone.isGone(snapshot), canEditPlaylists: false, canShare: false, canRoute: true)
        }
        await model.load()
        #expect(actions().contains(.discardProgress))

        await service.fail(with: APIError.notFound)
        await model.load()
        #expect(actions() == [.details, .history])

        // A retry that times out hides the model's 404, but the item is still known to be gone:
        // a discard confirmed now is no longer offered, so it isn't sent.
        await service.fail(with: APIError.timedOut)
        await model.load()
        #expect(actions() == [.details, .history])
        #expect(!actions().contains(.discardProgress))

        await service.fail(with: nil)
        await model.load()
        #expect(actions().contains(.discardProgress))
        #expect(
            ItemDetailMenuPresentation.actions(
                for: model, isGone: false, canEditPlaylists: false, canShare: false, canRoute: false
            ).contains(.history) == false)
    }

    @Test func discardIsDestructive() {
        for action in ItemDetailMenuAction.allCases {
            #expect((ItemDetailMenuPresentation.role(for: action) == .destructive) == (action == .discardProgress))
        }
    }

    @Test func titlesAndIcons() {
        let titles = ItemDetailMenuAction.allCases.map(ItemDetailMenuPresentation.titleKey(for:))
        let icons = ItemDetailMenuAction.allCases.map(ItemDetailMenuPresentation.systemImage(for:))
        #expect(Set(titles).count == ItemDetailMenuAction.allCases.count)
        #expect(Set(icons).count == ItemDetailMenuAction.allCases.count)
        // Every title is a translated string, not a missing key.
        for key in titles { #expect(L10n.string(key) != key) }
        #expect(
            L10n.string(ItemDetailMenuPresentation.titleKey(for: .discardProgress), locale: english)
                == "Discard Progress")
        #expect(L10n.string(ItemDetailMenuPresentation.titleKey(for: .details), locale: english) == "More Info")
    }
}
