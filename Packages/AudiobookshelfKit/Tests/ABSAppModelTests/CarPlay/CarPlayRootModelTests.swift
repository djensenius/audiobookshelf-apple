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
    authors: "Authors", more: "More")

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
                    self.playback.error = self.playError
                }
            },
            playing: { self.playing }, playback: playback, labels: labels)
    }
}

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
            #expect(model.streamingPrompt == nil)
            #expect(await confirm.value == .started)
            #expect(harness.playback.calls == [.confirmMeteredStreaming])
            #expect(harness.playback.error == nil)
            // Negative control: with nothing blocked, there's nothing to confirm.
            #expect(model.confirmStreaming() == nil)
        }
    }

    /// #544: Cancel declines the block, which clears the player's error and the prompt.
    @Test func aBlockedPlayDeclinedClearsThePrompt() async throws {
        try await withLibrarySettings { settings in
            let (harness, model) = try await blockedHarness(settings: settings)
            model.declineStreaming()
            #expect(model.streamingPrompt == nil)
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
            #expect(model.streamingPrompt == nil)
            // The same block back (the phone played it again) asks again; cleared, it goes.
            harness.playback.error = Self.needsConfirmation
            #expect(model.streamingPrompt == .confirm)
            harness.playback.error = nil
            #expect(model.streamingPrompt == nil)
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
            #expect(model.streamingPrompt == .notAllowed)
            #expect(model.confirmStreaming() == nil)
            model.declineStreaming()
            #expect(model.streamingPrompt == nil)
            #expect(harness.playback.calls.isEmpty)

            // Confirmed after the setting changed to "never": blocked again, with its reason.
            harness.playError = Self.needsConfirmation
            #expect(await model.play(row)?.value == .blocked)
            harness.playback.confirmFailure = .streamingNotAllowed(.cellular, key: Self.sherlockKey)
            #expect(await model.confirmStreaming()?.value == .blocked)
            #expect(model.streamingPrompt == .notAllowed)
        }
    }

    private static let sherlockKey = MediaKey(
        serverConnectionID: carAccountA.connectionID, libraryItemId: SampleLibrary.sherlock.id)
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
        #expect(model.streamingPrompt == nil)
        #expect(await model.play(row)?.value == .blocked)
        #expect(model.streamingPrompt == .confirm)
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
