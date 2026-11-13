import ABSAppModel
import ABSCore
import ABSUI
import Testing

@testable import Audiobookshelf

@Suite struct PlayerPresentationTests {
    /// At accessibility text sizes the regular accessory drops the cover, author and jumps but
    /// keeps close; the inline accessory keeps only play/pause.
    @Test func theMiniPlayerReducesAtAccessibilitySizes() {
        typealias Layout = MiniPlayerView.Layout
        #expect(Layout.pick(isInline: false, isAccessibilitySize: false) == .regular)
        #expect(Layout.pick(isInline: false, isAccessibilitySize: true) == .accessibility)
        #expect(Layout.pick(isInline: true, isAccessibilitySize: true) == .inline)
        #expect(Layout.pick(isInline: true, isAccessibilitySize: false) == .inline)
        #expect(Layout.accessibility.transportStyle == .playPauseOnly)
        #expect(!Layout.accessibility.showsCoverAndAuthor)
        #expect(Layout.accessibility.showsCloseAndProgress)
        #expect(Layout.regular.transportStyle == .compact)
        #expect(!Layout.inline.showsCloseAndProgress)
    }

    /// The players' covers (#336) take the playing item's library's setting, else the current library's.
    @Test func coverSettingsComeFromTheItemsLibraryElseTheCurrentOne() {
        let libraries = [
            Library(
                id: "lib_standard", name: "Standard", mediaType: .book,
                settings: LibrarySettings(coverAspectRatio: 0)),
            Library(
                id: "lib_square", name: "Square", mediaType: .book, settings: LibrarySettings(coverAspectRatio: 1)),
        ]
        func settings(_ libraryID: String?, current: String?) -> LibrarySettings? {
            LibraryCoverSettings.settings(forLibrary: libraryID, current: current) { id in
                libraries.first { $0.id == id }
            }
        }
        #expect(settings("lib_square", current: "lib_standard")?.coverAspectRatio == 1)
        #expect(settings("lib_gone", current: "lib_standard")?.coverAspectRatio == 0)
        #expect(settings(nil, current: "lib_square")?.coverAspectRatio == 1)
        #expect(settings(nil, current: nil) == nil)
    }

    @Test func theFullPlayerClosesOnlyWhenPresentedWithoutASession() {
        #expect(PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: true))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: true))
    }

    /// On macOS turning the full player on opens the Now Playing window, but only with a session.
    @Test func theMacWindowOpensOnlyWithASession() {
        #expect(PlayerSlot.opensNowPlayingWindow(isPresented: true, hasSession: true))
        #expect(!PlayerSlot.opensNowPlayingWindow(isPresented: true, hasSession: false))
        #expect(!PlayerSlot.opensNowPlayingWindow(isPresented: false, hasSession: true))
        #expect(!PlayerSlot.opensNowPlayingWindow(isPresented: false, hasSession: false))
    }

    @Test(arguments: [
        PlayerErrorMessage.streamingNeedsConfirmation, .streamingNotAllowed, .sessionStartFailed,
        .streamUnavailable, .streamingInterrupted, .streamRejected, .playbackFailed,
    ])
    func everyPlayerErrorHasAResolvableMessage(_ error: PlayerErrorMessage) {
        let key = PlayerSlot.messageKey(for: error)
        #expect(L10n.string(key) != key)
    }

    /// #376: only "ask" offers to stream anyway; "never" and other failures show OK.
    @Test(arguments: [
        PlayerErrorMessage.streamingNeedsConfirmation, .streamingNotAllowed, .sessionStartFailed,
        .streamUnavailable, .streamingInterrupted, .streamRejected, .playbackFailed,
    ])
    func onlyAConfirmationOffersToStream(_ error: PlayerErrorMessage) {
        #expect(PlayerErrorAction(error) == (error == .streamingNeedsConfirmation ? .streamAnyway : nil))
        #expect(L10n.string(PlayerErrorAction.streamAnyway.titleKey) != PlayerErrorAction.streamAnyway.titleKey)
    }

    /// A scene shows a failure until it's dismissed there, and a different failure after that.
    @Test func anErrorShowsUntilItsSceneDismissesIt() {
        #expect(PlayerSlot.shownError(current: .playbackFailed, dismissed: nil) == .playbackFailed)
        #expect(PlayerSlot.shownError(current: .playbackFailed, dismissed: .playbackFailed) == nil)
        #expect(PlayerSlot.shownError(current: .streamRejected, dismissed: .playbackFailed) == .streamRejected)
        #expect(PlayerSlot.shownError(current: nil, dismissed: nil) == nil)
    }

    /// A different failure resets the dismissal: A, dismissed, then B shows, and A again after it.
    @Test func aDifferentErrorResetsTheDismissal() {
        var current: PlayerErrorMessage? = .playbackFailed
        var dismissed: PlayerErrorMessage?
        func change(to error: PlayerErrorMessage) {
            current = error
            dismissed = PlayerSlot.dismissed(afterChangeTo: error, dismissed: dismissed)
        }
        #expect(PlayerSlot.shownError(current: current, dismissed: dismissed) == .playbackFailed)
        dismissed = current
        #expect(PlayerSlot.shownError(current: current, dismissed: dismissed) == nil)
        change(to: .streamRejected)
        #expect(PlayerSlot.shownError(current: current, dismissed: dismissed) == .streamRejected)
        change(to: .playbackFailed)
        #expect(PlayerSlot.shownError(current: current, dismissed: dismissed) == .playbackFailed)
    }
}
