import Testing

@testable import Audiobookshelf

@Suite struct PlayerPresentationTests {
    @Test func aScrubberThatNeverScrubbedLeavesOtherWindowsScrubsAlone() {
        var ownership = ScrubOwnership()
        let ends = ownership.disappeared()
        #expect(!ends)
    }

    @Test func aScrubberDisappearingMidDragEndsItsScrub() {
        var ownership = ScrubOwnership()
        ownership.scrubbed()
        let ends = ownership.disappeared()
        #expect(ends)
        // Ended once: appearing and disappearing again doesn't end another scrub.
        let endsAgain = ownership.disappeared()
        #expect(!endsAgain)
    }

    @Test func aScrubberWhoseDragEndedDoesNotEndItAgain() {
        var ownership = ScrubOwnership()
        ownership.scrubbed()
        ownership.ended()
        let ends = ownership.disappeared()
        #expect(!ends)
    }

    @Test func theFullPlayerClosesOnlyWhenPresentedWithoutASession() {
        #expect(PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: true))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: true))
    }
}
