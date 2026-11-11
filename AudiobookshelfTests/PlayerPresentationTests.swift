import ABSAppModel
import ABSUI
import Testing

@testable import Audiobookshelf

@Suite struct PlayerPresentationTests {
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
