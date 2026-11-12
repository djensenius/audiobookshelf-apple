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
