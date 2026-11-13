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

    @Test func acceptSeeksOnceToTheRemotePosition() async throws {
        offer.offer(update(at: 200, device: "Chrome on macOS"))
        let shown = try #require(offer.shown)
        #expect(shown == .init(key: FakePlaybackControl.key(), position: 200, deviceDescription: "Chrome on macOS"))

        await offer.accept(shown)?.value
        #expect(offer.accept(shown) == nil)

        #expect(playback.calls == [.seek(200)])
        #expect(playback.currentTime == 200)
        #expect(offer.pending == nil)
    }

    @Test func acceptAfterTheMediaChangedDoesNotSeek() async throws {
        offer.offer(update(at: 200))
        let shown = try #require(offer.shown)
        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)

        #expect(offer.shown == nil)
        await offer.accept(shown)?.value

        #expect(playback.calls.isEmpty)
        #expect(offer.pending == nil)
    }

    @Test func acceptAfterPlaybackStartedDoesNotSeek() async throws {
        offer.offer(update(at: 200))
        let shown = try #require(offer.shown)
        await playback.resume(rewindingBy: nil)
        playback.clearCalls()

        #expect(offer.shown == nil)
        await offer.accept(shown)?.value

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

    @Test func aNewerOfferReplacesTheOlderOne() async throws {
        offer.offer(update(at: 200))
        offer.offer(update(at: 260))
        let shown = try #require(offer.shown)
        #expect(shown.position == 260)

        await offer.accept(shown)?.value
        #expect(playback.calls == [.seek(260)])
    }

    /// The alert keeps showing the offer it was presented with; accepting that one after a newer
    /// one replaced it doesn't seek, and the newer one stays to be shown.
    @Test func acceptingAReplacedOfferDoesNotSeek() async throws {
        offer.offer(update(at: 200))
        let displayed = try #require(offer.shown)
        offer.offer(update(at: 260))

        await offer.accept(displayed)?.value

        #expect(playback.calls.isEmpty)
        #expect(offer.shown?.position == 260)
    }

    @Test func mediaChangingAfterAcceptBeforeTheSeekRunsDoesNotSeek() async throws {
        offer.offer(update(at: 200))
        let task = offer.accept(try #require(offer.shown))
        playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)

        await task?.value

        #expect(playback.calls.isEmpty)
        #expect(playback.currentTime == 10)
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

    /// A remote update at 200 offers a jump from 30; a newer one back at 30 offers none, but ends
    /// the earlier offer.
    @Test func aNewerRemoteUpdateAtThePlayersPositionEndsTheOffer() async throws {
        try await withLibrarySettings { settings in
            let harness = BridgeHarness()
            harness.bridge.route(
                library: LibraryStore(settings: settings), accounts: nil, bookmarks: { nil }, playback: playback,
                localProgress: nil, remoteProgressOffer: offer)
            let socket = try await harness.start()

            await harness.send(progressUpdate("li_book", currentTime: 200, lastUpdate: 1_000), on: socket)
            #expect(offer.shown?.position == 200)

            await harness.send(progressUpdate("li_book", currentTime: 30, lastUpdate: 2_000), on: socket)
            #expect(offer.pending == nil)
            #expect(playback.calls.isEmpty)
        }
    }
}
