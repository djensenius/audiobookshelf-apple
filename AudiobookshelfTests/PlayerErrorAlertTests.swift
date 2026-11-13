import ABSAppModel
import ABSCore
import ABSPlayback
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

/// Where a playback failure shows (PR #537): the queue that started a failed play shows it once,
/// instead of the window or the full player under it, and a play that starts shows nothing.
@MainActor
@Suite struct PlayerErrorAlertTests {
    private let row = QueueRow(item: QueueItem(libraryItemID: "li_1", title: "Book"), serverConnectionID: UUID())

    /// Plays like the app's action: a failure goes to the player, nothing throws.
    private func play(failingWith error: PlayerErrorMessage?, on player: PlaceholderPlayerState) -> PlayItemAction {
        PlayItemAction { _, _, _ in player.errorMessageKey = error }
    }

    /// The failure each of `layers` shows in `owner`'s window; `nil` is the window's own alert.
    private func shown(
        _ owner: PlayerErrorAlertOwner, _ player: PlaceholderPlayerState, layers: [UUID?], isActive: Bool = true
    ) -> [PlayerErrorMessage?] {
        layers.map { owner.shownError(current: player.errorMessageKey, in: $0, isActive: isActive) }
    }

    /// A failed play from the queue sheet, over the iOS full player, shows one localized alert, on the sheet.
    @Test func aFailedQueuedPlayShowsOneAlertOnTheQueue() async throws {
        let owner = PlayerErrorAlertOwner()
        let player = PlaceholderPlayerState(hasSession: true)
        let fullPlayer = UUID()
        let queue = UUID()
        owner.add(fullPlayer)
        owner.add(queue)

        try await row.play(with: play(failingWith: .sessionStartFailed, on: player))

        #expect(shown(owner, player, layers: [nil, fullPlayer, queue]) == [nil, nil, .sessionStartFailed])
        let key = PlayerSlot.messageKey(for: .sessionStartFailed)
        #expect(L10n.string(key) != key)
    }

    /// A queued play that starts shows no alert anywhere.
    @Test func aQueuedPlayThatStartsShowsNoAlert() async throws {
        let owner = PlayerErrorAlertOwner()
        let player = PlaceholderPlayerState(hasSession: true)
        let queue = UUID()
        owner.add(queue)

        try await row.play(with: play(failingWith: nil, on: player))

        #expect(shown(owner, player, layers: [nil, queue]) == [nil, nil])
    }

    /// With the queue inspector open in an active browsing window, the inspector shows the failure
    /// and the window's own alert doesn't repeat it; once it closes, the window shows it again.
    @Test func theWindowDefersToItsQueueInspector() async throws {
        let owner = PlayerErrorAlertOwner()
        let player = PlaceholderPlayerState(hasSession: true)
        let inspector = UUID()
        owner.add(inspector)

        try await row.play(with: play(failingWith: .playbackFailed, on: player))
        #expect(shown(owner, player, layers: [nil, inspector]) == [nil, .playbackFailed])

        owner.remove(inspector)
        #expect(shown(owner, player, layers: [nil, inspector]) == [.playbackFailed, nil])
    }

    /// On a Mac the Now Playing window's queue sheet and a browsing window each own an alert, and
    /// only the active one shows the failure.
    @Test func onlyTheActiveWindowShowsTheFailure() async throws {
        let player = PlaceholderPlayerState(hasSession: true)
        let nowPlaying = PlayerErrorAlertOwner()
        let browsing = PlayerErrorAlertOwner()
        let queue = UUID()
        nowPlaying.add(queue)

        try await row.play(with: play(failingWith: .streamUnavailable, on: player))

        let shownInNowPlaying = shown(nowPlaying, player, layers: [queue], isActive: true)
        let shownInBrowsing = shown(browsing, player, layers: [nil], isActive: false)
        #expect((shownInNowPlaying + shownInBrowsing).compactMap(\.self) == [.streamUnavailable])
        #expect(shownInNowPlaying == [.streamUnavailable])
    }

    /// A failure dismissed on the queue doesn't show again in the window once the queue closes.
    @Test func aDismissalOnTheQueueHoldsForTheWindow() async throws {
        let owner = PlayerErrorAlertOwner()
        let player = PlaceholderPlayerState(hasSession: true)
        let queue = UUID()
        owner.add(queue)
        try await row.play(with: play(failingWith: .playbackFailed, on: player))

        owner.dismissedError = player.errorMessageKey
        owner.remove(queue)

        #expect(shown(owner, player, layers: [nil]) == [nil])
        owner.errorChanged(to: .streamRejected)
        player.errorMessageKey = .streamRejected
        #expect(shown(owner, player, layers: [nil]) == [.streamRejected])
    }
}
