import ABSCore
import ABSRealtime
import Testing

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RemoteProgressOfferTests {
    let playback = FakePlaybackControl()
    let offer: RemoteProgressOffer

    init() {
        offer = RemoteProgressOffer(playback: playback)
        playback.load(FakePlaybackControl.bookSession(), at: 30)
    }

    private func update(_ item: String = "li_book", at time: Double, device: String? = nil) -> UserItemProgressUpdate {
        UserItemProgressUpdate(
            id: "p-\(item)", sessionId: "remote", deviceDescription: device,
            progress: MediaProgress(
                id: "p-\(item)", libraryItemId: item, currentTime: time, lastUpdate: 1_700_000_000_000))
    }

    @Test func acceptSeeksOnceToTheRemotePosition() async {
        offer.offer(update(at: 200, device: "Chrome on macOS"))
        #expect(
            offer.shown
                == .init(key: FakePlaybackControl.key(), position: 200, deviceDescription: "Chrome on macOS"))

        await offer.accept()?.value
        #expect(offer.accept() == nil)

        #expect(playback.calls == [.seek(200)])
        #expect(playback.currentTime == 200)
        #expect(offer.pending == nil)
    }

    @Test func acceptAfterTheMediaChangedDoesNotSeek() async {
        offer.offer(update(at: 200))
        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)

        #expect(offer.shown == nil)
        await offer.accept()?.value

        #expect(playback.calls.isEmpty)
        #expect(offer.pending == nil)
    }

    @Test func acceptAfterPlaybackStartedDoesNotSeek() async {
        offer.offer(update(at: 200))
        await playback.resume(rewindingBy: nil)
        playback.clearCalls()

        #expect(offer.shown == nil)
        await offer.accept()?.value

        #expect(playback.calls.isEmpty)
        #expect(offer.pending == nil)
    }

    @Test func dismissClearsWithoutSeeking() {
        offer.offer(update(at: 200))
        offer.dismiss()

        #expect(offer.pending == nil)
        #expect(offer.shown == nil)
        #expect(playback.calls.isEmpty)
    }

    @Test func aNewerOfferReplacesTheOlderOne() async {
        offer.offer(update(at: 200))
        offer.offer(update(at: 260))
        #expect(offer.shown?.position == 260)

        await offer.accept()?.value
        #expect(playback.calls == [.seek(260)])
    }

    @Test func anOfferForOtherMediaOrWhilePlayingIsIgnored() async {
        offer.offer(update("li_other", at: 200))
        #expect(offer.pending == nil)

        await playback.resume(rewindingBy: nil)
        offer.offer(update(at: 200))
        #expect(offer.pending == nil)
    }

    @Test func playbackStartingClearsTheOffer() async {
        offer.offer(update(at: 200))
        await playback.resume(rewindingBy: nil)
        #expect(await eventually { offer.pending == nil })

        // Pausing again doesn't bring the old offer back.
        playback.pause()
        await Task.yield()
        #expect(offer.shown == nil)
    }

    @Test func theMediaChangingClearsTheOffer() async {
        offer.offer(update(at: 200))
        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)
        #expect(await eventually { offer.pending == nil })

        playback.load(FakePlaybackControl.bookSession(), at: 30)
        await Task.yield()
        #expect(offer.shown == nil)
    }

    @Test func routingFeedsTheBridgesOfferToTheModel() async throws {
        try await withLibrarySettings { settings in
            let bridge = RealtimeBridge(progress: ProgressCache())
            bridge.route(
                library: LibraryStore(settings: settings), accounts: nil, bookmarks: { nil }, playback: playback,
                localProgress: nil, remoteProgressOffer: offer)

            bridge.onRemoteProgress?(update(at: 200))

            #expect(offer.shown?.position == 200)
        }
    }
}
