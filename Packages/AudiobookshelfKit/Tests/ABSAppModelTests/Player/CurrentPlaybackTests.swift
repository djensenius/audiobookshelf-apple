import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// The scrubber of these tests.
private let owner = PlayerViewModel.ScrubOwner()

/// Runs `body` with an unbound ``CurrentPlayback`` and a view model built over it, as the app
/// builds them before any account session starts.
@MainActor
private func withUnboundPlayer(
    _ body: @MainActor (PlayerViewModel, CurrentPlayback) async throws -> Void
) async throws {
    let suiteName = "ABSAppModelTests.CurrentPlayback.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let current = CurrentPlayback()
    try await body(PlayerViewModel(playback: current, settings: AppSettings(defaults: defaults)), current)
}

/// Whether reading `read` inside observation tracking is invalidated by `change`.
@MainActor
private func invalidates(_ read: () -> Void, when change: () -> Void) -> Bool {
    let changed = Locked(false)
    withObservationTracking(read) { changed.value = true }
    change()
    return changed.value
}

/// Drops `playback`'s session the way a failed reload does: same item, no session or timeline.
@MainActor
private func dropSession(of playback: FakePlaybackControl) {
    playback.phase = .unloaded
    playback.session = nil
    playback.timeline = nil
}

@MainActor
@Suite struct CurrentPlaybackTests {
    @Test func unboundIsIdleAndIgnoresCommands() async {
        let current = CurrentPlayback()

        #expect(current.current == nil)
        #expect(current.phase == .idle)
        #expect(current.mediaKey == nil)
        #expect(current.session == nil)
        #expect(current.currentTime == 0)
        #expect(current.duration == 0)
        #expect(current.rate == 1)
        #expect(!current.isPlaying)
        #expect(!current.isPlaybackRequested)
        #expect(current.timeline == nil)
        #expect(current.chapterIndex == nil)
        #expect(await current.seek(to: 10) == nil)
        #expect(await current.jump(by: 10) == nil)
        await current.resume(rewindingBy: nil)
        current.pause()
        current.setRate(2)
        current.stop(reason: .user)
        #expect(current.phase == .idle)
    }

    @Test func forwardsStateAndCommandsToTheBinding() async {
        let current = CurrentPlayback()
        let playback = FakePlaybackControl()
        current.bind(playback)
        playback.load(FakePlaybackControl.bookSession(), at: 150, playing: true)

        #expect(current.current === playback)
        #expect(current.phase == .loaded)
        #expect(current.mediaKey == FakePlaybackControl.key())
        #expect(current.currentTime == 150)
        #expect(current.duration == 400)
        #expect(current.isPlaying)
        #expect(current.chapter?.title == "Middle")

        await current.resume(rewindingBy: 5)
        current.pause()
        #expect(await current.seek(to: 20) == 20)
        #expect(await current.jump(by: 10) == 30)
        current.setRate(1.5)
        current.stop(reason: .user)
        #expect(
            playback.calls == [
                .resume(rewindingBy: 5), .pause, .seek(20), .jump(10), .setRate(1.5), .stop(.user),
            ])

        current.bind(nil)
        current.pause()
        #expect(playback.calls.count == 6)
        #expect(current.phase == .idle)
    }

    @Test func bindInvalidatesObservers() {
        let current = CurrentPlayback()
        let playback = FakePlaybackControl()

        #expect(invalidates({ _ = current.phase }, when: { current.bind(playback) }))
        #expect(invalidates({ _ = current.phase }, when: { playback.phase = .loaded }))
        #expect(invalidates({ _ = current.phase }, when: { current.bind(nil) }))
        #expect(!invalidates({ _ = current.phase }, when: { playback.phase = .idle }))
    }

    /// A view model built before any binding follows the first one: its item tracking cancels a
    /// scrub when the bound coordinator's item changes, and its display tracking keeps text no view
    /// read. Both re-register on `willSet`, while the proxy is still unbound.
    @Test func trackingFollowsTheFirstBind() async throws {
        try await withUnboundPlayer { model, current in
            let playbackA = FakePlaybackControl()
            current.bind(playbackA)

            playbackA.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub(owner: owner)
            model.scrub(to: 0.9, owner: owner)
            playbackA.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)
            await model.endScrub(owner: owner)
            #expect(playbackA.calls.isEmpty)

            // Loaded and dropped with no one reading in between.
            playbackA.load(FakePlaybackControl.bookSession(), at: 150)
            dropSession(of: playbackA)
            #expect(model.title == "Dune")
        }
    }

    /// #543: an alert for the old binding's failure can't act on the new binding's equal one (an
    /// account switch); the new failure's own alert does.
    @Test func anAlertForTheOldBindingDoesNotActOnTheNewOne() async throws {
        try await withUnboundPlayer { model, current in
            let playbackA = FakePlaybackControl()
            let playbackB = FakePlaybackControl()
            playbackA.error = .recoveryExhausted
            playbackB.error = .recoveryExhausted
            current.bind(playbackA)
            let earlier = try #require(model.failure)
            current.bind(playbackB)
            let now = try #require(model.failure)
            #expect(now != earlier)

            await model.respond(to: earlier, with: .retry)
            #expect(playbackB.calls.isEmpty)
            await model.respond(to: now, with: .retry)
            #expect(playbackB.calls == [.resume(rewindingBy: nil)])
            #expect(playbackA.calls.isEmpty)
        }
    }

    /// After a re-bind the old coordinator's changes reach nothing, and the new one's do.
    @Test func trackingLeavesTheOldBinding() async throws {
        try await withUnboundPlayer { model, current in
            let playbackA = FakePlaybackControl()
            let playbackB = FakePlaybackControl()
            current.bind(playbackA)
            playbackA.load(FakePlaybackControl.bookSession(), at: 150)
            #expect(model.title == "Dune")
            current.bind(playbackB)
            #expect(model.title.isEmpty)

            // The old coordinator's item changing doesn't cancel the new one's scrub.
            playbackB.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub(owner: owner)
            model.scrub(to: 0.9, owner: owner)
            playbackA.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)
            await model.endScrub(owner: owner)
            #expect(playbackB.calls.count == 1)
            #expect(playbackA.calls.isEmpty)

            // The new one's item changing does.
            model.beginScrub(owner: owner)
            model.scrub(to: 0.5, owner: owner)
            playbackB.load(FakePlaybackControl.bookSession(item: "li_next"), at: 10)
            await model.endScrub(owner: owner)
            #expect(playbackB.calls.count == 1)

            // The new one's text is kept unread; the old one's changes don't invalidate the model.
            playbackB.load(FakePlaybackControl.bookSession(), at: 150)
            dropSession(of: playbackB)
            #expect(model.title == "Dune")
            #expect(!invalidates({ _ = model.title }, when: { playbackA.session = nil }))
        }
    }
}
