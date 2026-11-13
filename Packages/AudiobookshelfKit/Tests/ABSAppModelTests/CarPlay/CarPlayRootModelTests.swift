import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

private let carAccountA = SessionIdentity(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A") ?? UUID(), userID: "user-1")
private let carAccountB = SessionIdentity(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B") ?? UUID(), userID: "user-1")
private let labels = CarPlayLabels(
    continueListening: "Continue", libraries: "Libraries", books: "Books", podcasts: "Podcasts", series: "Series",
    authors: "Authors", latest: "Latest", more: "More")

private func key(_ identity: SessionIdentity) -> LibraryConnectionKey {
    LibraryConnectionKey(connectionID: identity.connectionID, userID: identity.userID)
}

/// A service with one library, `books`, whose Continue Listening shelf holds `items`. `fail`
/// fails the shelves, `failLibraries` the libraries.
private func service(
    _ items: [LibraryItem], fail: Locked<Bool>? = nil, failLibraries: Locked<Bool>? = nil
) -> FakeLibraryService {
    var service = FakeLibraryService()
    service.librariesHandler = {
        if failLibraries?.value == true { throw TestError.offline }
        return [makeLibrary("books")]
    }
    service.shelvesHandler = { _ in
        if fail?.value == true { throw TestError.offline }
        return [
            Shelf(id: "continue-listening", label: "Continue Listening", type: .book, entities: .libraryItems(items)),
            Shelf(
                id: "recently-added", label: "Recently Added", type: .book,
                entities: .libraryItems([SampleLibrary.emma])),
        ]
    }
    return service
}

/// The model's inputs, changed by the tests. The model keeps it alive.
@MainActor
private final class Harness {
    var gate: AuthGate = .ready(carAccountA, isOffline: false)
    var canPlay = true
    var playing: MediaKey?
    let plays = Locked<[String]>([])
    let playback = FakePlaybackControl()
    /// The error a play leaves in ``playback``, as the coordinator's does: a metered block, say.
    var playError: PlaybackCoordinatorError?
    /// Whether a play throws, as when it has no session to play in.
    var playThrows = false
    /// The account session ``playback`` is bound to: replaced by a sign-in, `nil` while unbound.
    var session: AnyObject? = PlaybackSessionToken()
    /// Holds each play until it's resumed, when set.
    var holdsPlays = false
    private var heldPlays: [CheckedContinuation<Void, Never>] = []
    var heldPlayCount: Int { heldPlays.count }

    func releasePlays() {
        let held = heldPlays
        heldPlays = []
        held.forEach { $0.resume() }
    }

    fileprivate func hold() async {
        guard holdsPlays else { return }
        await withCheckedContinuation { heldPlays.append($0) }
    }
    let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func model() -> CarPlayRootModel {
        CarPlayRootModel(
            gate: { self.gate }, store: store,
            playItem: { identity in
                guard self.canPlay else { return nil }
                return PlayItemAction { [plays = self.plays] itemID, episodeID, _ in
                    plays.value.append("\(identity.connectionID == carAccountA.connectionID ? "A" : "B"):\(itemID)")
                    _ = episodeID
                    await self.hold()
                    if self.playThrows { throw TestError.unexpected }
                    self.playback.error = self.playError
                }
            },
            playing: { self.playing }, playback: playback,
            playbackSession: { self.session }, labels: labels)
    }
}

private final class PlaybackSessionToken {}

private func tabRows(_ content: CarPlayRootContent) -> [CarPlayRow] {
    guard case .tabs(let list, _) = content else { return [] }
    return list.rows
}

@MainActor
@Suite struct CarPlayRootModelTests {
    @Test func theGateChoosesTheTemplate() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(store: LibraryStore(settings: settings))
            let model = harness.model()
            let cases: [(AuthGate, CarPlayRootContent)] = [
                (.launching, .loading), (.connect, .signedOut), (.switching(from: carAccountA), .loading),
                (.signingOut(from: carAccountA), .loading),
                (.storeUnavailable(SessionStoreError(TestError.unexpected)), .storeUnavailable),
            ]
            for (gate, content) in cases {
                harness.gate = gate
                #expect(model.content == content)
            }
            // Ready, but the store doesn't serve the account yet.
            harness.gate = .ready(carAccountA, isOffline: false)
            #expect(model.content == .loading)
        }
    }

    @Test func theContinueTabShowsTheAccountsContinueListeningShelf() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(
                client: service([SampleLibrary.frankenstein, SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            // Negative control: nothing is loaded before the first update.
            #expect(model.content == .loading)
            #expect(model.loadTrigger.identity == carAccountA)
            #expect(model.loadTrigger.libraryID == "books")

            await model.update()
            let rows = tabRows(model.content)
            #expect(rows.map(\.id) == [SampleLibrary.frankenstein.id, SampleLibrary.sherlock.id])
            #expect(rows.allSatisfy { $0.image?.serverID == carAccountA.connectionID })

            store.progress.apply(
                MediaProgress(
                    id: "p", libraryItemId: SampleLibrary.sherlock.id, progress: 0.25, isFinished: false,
                    hideFromContinueListening: false, lastUpdate: 1))
            #expect(tabRows(model.content).last?.progress == 0.25)
            #expect(tabRows(model.content).first?.progress == nil)
        }
    }

    @Test func noLibraryShowsAnEmptyTabOnceTheLibrariesAreKnown() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FakeLibraryService(), connectionKey: key(carAccountA))
            let model = Harness(store: store).model()
            await model.update()
            guard case .tabs(let list, nil) = model.content else {
                Issue.record("Expected the tabs, got \(model.content)")
                return
            }
            #expect(list.rows.isEmpty)
        }
    }

    @Test func aFailedFirstLoadShowsTheFailure() async throws {
        try await withLibrarySettings { settings in
            let fail = Locked(true)
            let store = LibraryStore(settings: settings)
            await store.connect(
                client: service([SampleLibrary.frankenstein], fail: fail), connectionKey: key(carAccountA))
            let model = Harness(store: store).model()
            await model.update()
            #expect(model.content == .failed)

            fail.value = false
            await model.refresh()
            #expect(tabRows(model.content).map(\.id) == [SampleLibrary.frankenstein.id])
        }
    }

    @Test func anotherAccountsShelvesAreNeverShown() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.frankenstein]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            #expect(!tabRows(model.content).isEmpty)

            // Switched to B: A's shelves stay hidden until B's load.
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountB))
            harness.gate = .ready(carAccountB, isOffline: false)
            #expect(model.content == .loading)
            await model.update()
            #expect(tabRows(model.content).map(\.id) == [SampleLibrary.sherlock.id])
            #expect(tabRows(model.content).allSatisfy { $0.image?.serverID == carAccountB.connectionID })
        }
    }

    @Test func signingOutDropsTheShelves() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.frankenstein]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()

            harness.gate = .connect
            #expect(model.loadTrigger.identity == nil)
            await model.update()
            #expect(model.content == .signedOut)

            // Signed in again to the same account: loading until its own load.
            harness.gate = .ready(carAccountA, isOffline: false)
            #expect(model.content == .loading)
        }
    }

    @Test func aTappedRowPlaysThroughTheAccountsPlayAction() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(
                client: service([SampleLibrary.frankenstein, SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let row = try #require(tabRows(model.content).last)

            #expect(await model.play(row)?.value == .started)
            #expect(harness.plays.value == ["A:\(SampleLibrary.sherlock.id)"])

            // Negative controls: a row the tab doesn't show, a disabled row, a row that doesn't play,
            // an account that can't play, and a switch, start nothing.
            let foreign = CarPlayRow(id: "x", text: "X", action: .play(itemID: "x", episodeID: nil))
            #expect(model.play(foreign) == nil)
            let disabled = CarPlayRow(
                id: row.id, text: row.text, image: row.image, isEnabled: false, action: row.action)
            #expect(model.play(disabled) == nil)
            #expect(model.play(CarPlayRow(id: row.id, text: row.text, action: .open(.libraries))) == nil)
            harness.canPlay = false
            #expect(model.play(row) == nil)
            harness.canPlay = true
            harness.gate = .switching(from: carAccountA)
            #expect(model.play(row) == nil)
            #expect(harness.plays.value.count == 1)
        }
    }

    /// #544: a tap handler holds the row as it was rendered; progress saved since then (the
    /// player's own sync, say) doesn't stop the tap from playing.
    @Test func aTapPlaysTheRowAfterItsProgressChanged() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let rendered = try #require(tabRows(model.content).first)
            #expect(rendered.progress == nil)

            store.progress.apply(
                MediaProgress(
                    id: "p", libraryItemId: SampleLibrary.sherlock.id, progress: 0.5, isFinished: false,
                    hideFromContinueListening: false, lastUpdate: 1))
            #expect(tabRows(model.content).first?.progress == 0.5)

            #expect(await model.play(rendered)?.value == .started)
            #expect(harness.plays.value == ["A:\(SampleLibrary.sherlock.id)"])
        }
    }

    /// #544: the libraries request failed with no saved or default library, so there was no
    /// shelf to load; a refresh retries the libraries, then loads the shelves.
    @Test func aRefreshRetriesAFailedLibrariesLoad() async throws {
        try await withLibrarySettings { settings in
            let failLibraries = Locked(true)
            let store = LibraryStore(settings: settings)
            await store.connect(
                client: service([SampleLibrary.frankenstein], failLibraries: failLibraries),
                connectionKey: key(carAccountA))
            let model = Harness(store: store).model()
            await model.update()
            #expect(model.content == .failed)

            failLibraries.value = false
            await model.refresh()
            #expect(tabRows(model.content).map(\.id) == [SampleLibrary.frankenstein.id])
        }
    }

    /// #544: a play blocked by "ask" on a metered network is asked about on CarPlay; Stream plays
    /// it, and the prompt goes.
    @Test func aBlockedPlayAsksAndStreamPlaysIt() async throws {
        try await withLibrarySettings { settings in
            let (harness, model) = try await blockedHarness(settings: settings)
            #expect(harness.playback.calls.isEmpty)

            let confirm = try #require(model.confirmStreaming())
            #expect(model.alert == nil)
            #expect(await confirm.value == .started)
            #expect(harness.playback.calls == [.confirmMeteredStreaming])
            #expect(harness.playback.error == nil)
            // Negative control: with nothing blocked, there's nothing to confirm.
            #expect(model.confirmStreaming() == nil)
        }
    }

    /// #544: Stream's consent goes to the player only for the block it was asked about. If the
    /// phone blocks another item, or the playback rebinds to another session, before its task
    /// runs, nothing is forwarded.
    @Test(arguments: [false, true])
    func aConfirmationIsntForwardedAfterANewerBlockOrARebind(rebinds: Bool) async throws {
        try await withLibrarySettings { settings in
            let (harness, model) = try await blockedHarness(settings: settings)
            let confirm = try #require(model.confirmStreaming())
            if rebinds {
                harness.session = PlaybackSessionToken()
            } else {
                harness.playback.error = .streamingNeedsConfirmation(.cellular, key: Self.frankensteinKey)
            }
            #expect(await confirm.value == .discarded)
            #expect(harness.playback.calls.isEmpty)
            #expect(model.alert == nil)

            // The discarded confirmation isn't a play to join: a tap on its row starts afresh.
            let row = try #require(tabRows(model.content).first)
            let tap = try #require(model.play(row))
            #expect(tap != confirm)
            _ = await tap.value
            #expect(harness.plays.value.count == 2)
        }
    }

    /// #544: while the replay Stream started is starting, it's the blocked row's play: a tap on
    /// that row joins it (the coordinator would return at once for the item it's loading) and gets
    /// its outcome, here a failure, with one alert. Once it has ended, a tap plays again.
    @Test func aTapDuringAConfirmedReplayJoinsItAndGetsItsFailure() async throws {
        try await withLibrarySettings { settings in
            let (harness, model) = try await blockedHarness(settings: settings)
            let row = try #require(tabRows(model.content).first)
            let (replayEnds, endReplay) = AsyncStream<Void>.makeStream()
            harness.playback.confirmHold = {
                for await _ in replayEnds {}
            }
            harness.playback.confirmFailure = .sessionStartFailed(.timedOut)

            let confirm = try #require(model.confirmStreaming())
            while harness.playback.calls.isEmpty { await Task.yield() }
            let tap = try #require(model.play(row))
            #expect(tap == confirm)
            #expect(harness.plays.value.count == 1)

            endReplay.finish()
            #expect(await confirm.value == .failed)
            #expect(await tap.value == .failed)
            #expect(model.alert == .sessionStartFailed)

            harness.playback.error = nil
            let again = try #require(model.play(row))
            #expect(again != confirm)
            #expect(await again.value == .started)
            #expect(harness.plays.value.count == 2)
        }
    }

    /// #544: a streaming block for another item (another book, or the same one on another server)
    /// that the player ends on while CarPlay's play is pending, as when the phone played it
    /// meanwhile, isn't this play's: it's discarded, with no prompt and nothing to confirm, so
    /// Stream can't authorize an item the driver didn't tap. The play's own block is still its
    /// outcome.
    @Test(arguments: [true, false], [CarPlayRootModelTests.frankensteinKey, CarPlayRootModelTests.sherlockOnServerB])
    func aBlockOnAnotherItemIsntThePlaysOwn(asks: Bool, otherKey: MediaKey) async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let row = try #require(tabRows(model.content).first)

            func block(_ key: MediaKey) -> PlaybackCoordinatorError {
                asks ? .streamingNeedsConfirmation(.cellular, key: key) : .streamingNotAllowed(.cellular, key: key)
            }
            harness.playError = block(otherKey)
            #expect(await model.play(row)?.value == .discarded)
            #expect(model.alert == nil)
            #expect(model.confirmStreaming() == nil)
            #expect(harness.playback.calls.isEmpty)

            // Negative control: the play's own block is its outcome.
            harness.playError = block(Self.sherlockKey)
            #expect(await model.play(row)?.value == .blocked)
            #expect(model.alert == (asks ? .streamingNeedsConfirmation : .streamingNotAllowed))
        }
    }

    /// #544: Cancel declines the block, which clears the player's error and the prompt.
    @Test func aBlockedPlayDeclinedClearsThePrompt() async throws {
        try await withLibrarySettings { settings in
            let (harness, model) = try await blockedHarness(settings: settings)
            model.dismissAlert()
            #expect(model.alert == nil)
            #expect(harness.playback.calls == [.declineMeteredStreaming])
            #expect(harness.playback.error == nil)
        }
    }

    /// #544: the prompt follows the player's error: answered on the phone (or replaced by another
    /// failure), it goes from CarPlay too.
    @Test func thePromptGoesWhenThePlayersErrorChanges() async throws {
        try await withLibrarySettings { settings in
            let (harness, model) = try await blockedHarness(settings: settings)
            harness.playback.error = .streamRejected
            #expect(model.alert == nil)
            // The same block back (the phone played it again) asks again; cleared, it goes.
            harness.playback.error = Self.needsConfirmation
            #expect(model.alert == .streamingNeedsConfirmation)
            harness.playback.error = nil
            #expect(model.alert == nil)
            #expect(model.confirmStreaming() == nil)
        }
    }

    /// #544: "never" blocks with its reason alone: nothing to stream, and OK only dismisses it.
    @Test func aPlayStreamingNeverAllowsOffersNoConfirmation() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            harness.playError = .streamingNotAllowed(.cellular, key: Self.sherlockKey)
            let model = harness.model()
            await model.update()
            let row = try #require(tabRows(model.content).first)

            #expect(await model.play(row)?.value == .blocked)
            #expect(model.alert == .streamingNotAllowed)
            #expect(model.confirmStreaming() == nil)
            model.dismissAlert()
            #expect(model.alert == nil)
            #expect(harness.playback.calls.isEmpty)

            // Confirmed after the setting changed to "never": blocked again, with its reason.
            harness.playError = Self.needsConfirmation
            #expect(await model.play(row)?.value == .blocked)
            harness.playback.confirmFailure = .streamingNotAllowed(.cellular, key: Self.sherlockKey)
            #expect(await model.confirmStreaming()?.value == .blocked)
            #expect(model.alert == .streamingNotAllowed)
        }
    }

    /// #544: a play that fails says why on CarPlay, with the player's message, until dismissed
    /// (which declines nothing); one that throws says playback failed.
    @Test func aFailedPlayShowsItsError() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let row = try #require(tabRows(model.content).first)

            harness.playError = .sessionStartFailed(.timedOut)
            #expect(await model.play(row)?.value == .failed)
            #expect(model.alert == .sessionStartFailed)
            #expect(model.confirmStreaming() == nil)
            model.dismissAlert()
            #expect(model.alert == nil)
            #expect(harness.playback.calls.isEmpty)

            harness.playError = nil
            harness.playback.error = nil
            harness.playThrows = true
            #expect(await model.play(row)?.value == .failed)
            #expect(model.alert == .playbackFailed)

            // Negative control: a play that starts clears it and shows nothing.
            harness.playThrows = false
            #expect(await model.play(row)?.value == .started)
            #expect(model.alert == nil)
        }
    }

    /// #544: a play still running when the account signs out (its playback unbound, so it ends
    /// with no error) or signs in again (another session, with its own error) is discarded: no
    /// Now Playing and no alert.
    @Test(arguments: [false, true])
    func aPlayThatOutlivesItsSessionIsDiscarded(signsInAgain: Bool) async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let row = try #require(tabRows(model.content).first)

            harness.holdsPlays = true
            let play = try #require(model.play(row))
            while harness.heldPlayCount == 0 { await Task.yield() }
            harness.gate = .connect
            harness.session = nil
            if signsInAgain {
                harness.gate = .ready(carAccountA, isOffline: false)
                harness.session = PlaybackSessionToken()
                harness.playError = Self.needsConfirmation
            }
            harness.releasePlays()
            #expect(await play.value == .discarded)
            #expect(model.alert == nil)
        }
    }

    /// #544: a tap on another item while one is starting supersedes it: only the latest play's
    /// result counts, and the earlier one's failure, ending after it, shows nothing.
    @Test func aTapOnAnotherItemSupersedesTheStartingPlay() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(
                client: service([SampleLibrary.frankenstein, SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let rows = tabRows(model.content)
            let first = try #require(rows.first)
            let other = try #require(rows.last)

            harness.holdsPlays = true
            let firstPlay = try #require(model.play(first))
            while harness.heldPlayCount == 0 { await Task.yield() }
            harness.holdsPlays = false
            let otherPlay = try #require(model.play(other))
            #expect(otherPlay != firstPlay)
            #expect(await otherPlay.value == .started)
            harness.playError = .sessionStartFailed(.timedOut)
            harness.releasePlays()
            #expect(await firstPlay.value == .discarded)
            #expect(model.alert == nil)
            #expect(harness.plays.value == ["A:\(SampleLibrary.frankenstein.id)", "A:\(SampleLibrary.sherlock.id)"])
        }
    }

    /// #544: tapping the row again while its play is starting joins that play rather than
    /// starting (and so superseding) another: its outcome comes with the real start, and its
    /// failure is one alert.
    @Test(arguments: [false, true])
    func aSecondTapOnAStartingItemJoinsItsPlay(fails: Bool) async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            let row = try #require(tabRows(model.content).first)

            harness.holdsPlays = true
            let first = try #require(model.play(row))
            while harness.heldPlayCount == 0 { await Task.yield() }
            // A play the second tap might start isn't held, so it can't outlive the test.
            harness.holdsPlays = false
            let second = try #require(model.play(row))
            #expect(second == first)
            #expect(harness.plays.value == ["A:\(SampleLibrary.sherlock.id)"])

            if fails { harness.playError = .sessionStartFailed(.timedOut) }
            harness.releasePlays()
            let outcome: CarPlayPlayOutcome = fails ? .failed : .started
            #expect(await first.value == outcome)
            #expect(await second.value == outcome)
            #expect(model.alert == (fails ? .sessionStartFailed : nil))

            // Once it has started, a tap plays again.
            harness.playError = nil
            let again = try #require(model.play(row))
            #expect(again != first)
            #expect(await again.value == .started)
            #expect(harness.plays.value.count == 2)
        }
    }

    /// #544: a play outlives its CarPlay connection, but its start pushes Now Playing only on the
    /// connection it was tapped on, not on one made before it ends. A joined tap isn't waited on
    /// twice; a start (and only a start) on the current connection shows Now Playing.
    @Test func aPlayFromADisconnectedConnectionDoesntShowNowPlaying() async throws {
        let waiter = CarPlayNowPlayingWaiter()
        let (starts, start) = AsyncStream<Void>.makeStream()
        let play = Task<CarPlayPlayOutcome, Never> {
            for await _ in starts {}
            return .started
        }
        let wait = try #require(waiter.wait(for: play))
        #expect(waiter.wait(for: play) == nil)

        waiter.disconnect()
        let newConnectionWait = try #require(waiter.wait(for: play))
        start.finish()
        #expect(await wait.value == false)
        #expect(await newConnectionWait.value == true)

        let failed = Task<CarPlayPlayOutcome, Never> { .failed }
        #expect(await waiter.wait(for: failed)?.value == false)
    }

    /// #544: one alert at a time. A change while one is shown dismisses it; the alert wanted
    /// when the dismissal completes is presented then, through any changes (and `nil`) meanwhile.
    @Test func thePresenterShowsTheLatestAlertOnceTheDismissalCompletes() {
        var presenter = CarPlayAlertPresenter<PlayerErrorMessage>()
        #expect(presenter.request(nil) == nil)
        #expect(presenter.request(.streamingNeedsConfirmation) == .present(.streamingNeedsConfirmation))
        #expect(presenter.request(.streamingNeedsConfirmation) == nil)

        // Stream: the prompt goes, and the retry is blocked by "never" before the dismissal ends.
        #expect(presenter.request(nil) == .dismiss)
        #expect(presenter.request(.streamingNotAllowed) == nil)
        #expect(presenter.didDismiss() == .present(.streamingNotAllowed))

        // Changes during a dismissal, through nil, end with none.
        #expect(presenter.request(.sessionStartFailed) == .dismiss)
        #expect(presenter.request(nil) == nil)
        #expect(presenter.request(.playbackFailed) == nil)
        #expect(presenter.request(nil) == nil)
        #expect(presenter.didDismiss() == nil)
        #expect(presenter.shown == nil)

        // An alert that couldn't be presented isn't shown, and can be asked for again.
        #expect(presenter.request(.playbackFailed) == .present(.playbackFailed))
        presenter.didFailToPresent(.playbackFailed)
        #expect(presenter.shown == nil)
        #expect(presenter.request(.playbackFailed) == .present(.playbackFailed))
    }

    // MARK: - Library and Latest tabs (#80)

    @Test func aRowOfTheLibraryTabPlaysOnlyWhileItsPageShowsIt() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.books.value = ["books": BrowseFixtures.books(3)]
            let (store, browse) = await makeBrowse(service, settings: settings, identity: carAccountA)
            let harness = Harness(store: store)
            let model = harness.model()
            let books = CarPlayDestination.items(libraryID: "books")
            await browse.load(books)
            let row = try #require(browse.list(books).rows.first)

            // Not on the page it says it came from, or from another account's browse model.
            #expect(model.play(row, in: books, offset: 1, of: browse) == nil)
            let (_, other) = await makeBrowse(service, settings: settings, identity: carAccountB)
            await other.load(books)
            #expect(model.play(row, in: books, offset: 0, of: other) == nil)
            #expect(harness.plays.value.isEmpty)

            #expect(await model.play(row, in: books, offset: 0, of: browse)?.value == .started)
            #expect(harness.plays.value == ["A:books-0"])
        }
    }

    @Test func aLatestEpisodeBlockedOnAMeteredNetworkAsksToStream() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("pods", mediaType: .podcast)]
            service.recent.value = ["pods": [BrowseFixtures.recent("e1")]]
            let (store, browse) = await makeBrowse(service, settings: settings, identity: carAccountA)
            let harness = Harness(store: store)
            harness.playError = .streamingNeedsConfirmation(
                .cellular,
                key: MediaKey(serverConnectionID: carAccountA.connectionID, libraryItemId: "pod", episodeId: "e1"))
            let model = harness.model()
            let latest = try #require(browse.latestLibraryID.map { CarPlayDestination.latestEpisodes(libraryID: $0) })
            await browse.load(latest)
            let row = try #require(browse.list(latest).rows.first)
            #expect(await model.play(row, in: latest, offset: 0, of: browse)?.value == .blocked)
            #expect(model.alert == .streamingNeedsConfirmation)
            harness.playError = nil
            #expect(await model.confirmStreaming()?.value == .started)
            #expect(harness.playback.calls.contains(.confirmMeteredStreaming))
        }
    }

    private static let sherlockKey = MediaKey(
        serverConnectionID: carAccountA.connectionID, libraryItemId: SampleLibrary.sherlock.id)
    nonisolated private static let sherlockOnServerB = MediaKey(
        serverConnectionID: carAccountB.connectionID, libraryItemId: SampleLibrary.sherlock.id)
    nonisolated private static let frankensteinKey = MediaKey(
        serverConnectionID: carAccountA.connectionID, libraryItemId: SampleLibrary.frankenstein.id)
    private static let needsConfirmation = PlaybackCoordinatorError.streamingNeedsConfirmation(
        .cellular, key: sherlockKey)

    /// A model whose tapped row was blocked by "ask" on a metered network.
    private func blockedHarness(
        settings: AppSettings
    ) async throws -> (Harness, CarPlayRootModel) {
        let store = LibraryStore(settings: settings)
        await store.connect(client: service([SampleLibrary.sherlock]), connectionKey: key(carAccountA))
        let harness = Harness(store: store)
        harness.playError = Self.needsConfirmation
        let model = harness.model()
        await model.update()
        let row = try #require(tabRows(model.content).first)
        // Negative control: nothing to ask before the play.
        #expect(model.alert == nil)
        #expect(await model.play(row)?.value == .blocked)
        #expect(model.alert == .streamingNeedsConfirmation)
        harness.playError = nil
        return (harness, model)
    }

    @Test func theItemInThePlayerIsMarkedPlaying() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(
                client: service([SampleLibrary.frankenstein, SampleLibrary.sherlock]), connectionKey: key(carAccountA))
            let harness = Harness(store: store)
            let model = harness.model()
            await model.update()
            guard case .tabs(_, nil) = model.content else {
                Issue.record("Nothing plays yet")
                return
            }

            harness.playing = MediaKey(
                serverConnectionID: carAccountA.connectionID, libraryItemId: SampleLibrary.sherlock.id)
            guard case .tabs(_, let playing) = model.content else { return }
            #expect(playing == SampleLibrary.sherlock.id)

            // The same item ID on another server isn't this row.
            harness.playing = MediaKey(
                serverConnectionID: carAccountB.connectionID, libraryItemId: SampleLibrary.sherlock.id)
            guard case .tabs(_, let other) = model.content else { return }
            #expect(other == nil)
        }
    }
}
