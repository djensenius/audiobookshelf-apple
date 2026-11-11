import ABSAppModel
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

    @Test func podcastEpisodesHaveSquareCoversInBothPlayers() {
        #expect(PlayerViewModel.coverShape(isPodcastEpisode: true) == .square)
        #expect(PlayerViewModel.coverShape(isPodcastEpisode: false) == .book)
    }

    @Test func theFullPlayerClosesOnlyWhenPresentedWithoutASession() {
        #expect(PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: true))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: true))
    }
}
