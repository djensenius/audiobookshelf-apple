import ABSAppModel
import SwiftUI
import Testing

@testable import Audiobookshelf

/// The connection indicator's toolbar priority (#691) and its fixture hook.
@MainActor
@Suite struct ConnectionIndicatorToolbarTests {
    /// In compact width a lasting problem outranks the Library screen's filter and sort (`.high`), so the crowded
    /// Library root keeps it in its bar; a brief one doesn't, so the bar doesn't reflow for it.
    @Test(arguments: [ConnectionIndicatorState.connecting, .offline, .serverUnreachable])
    func lastingProblemsOutrankTheLibraryControlsInCompactWidth(state: ConnectionIndicatorState) {
        #expect(priority(state, problemPersisted: true, isCompact: true) > .high)
        #expect(priority(state, problemPersisted: false, isCompact: true) == .automatic)
        #expect(priority(state, problemPersisted: true, isCompact: false) == .automatic)
    }

    /// A working connection, however it's metered, keeps the default, so the filter and sort stay in the bar, even
    /// before the debounce has caught up with it.
    @Test(arguments: [false, true], [false, true])
    func aConnectionKeepsTheDefault(cellular: Bool, metered: Bool) {
        let state = ConnectionIndicatorState.connected(cellular: cellular, metered: metered)
        for persisted in [false, true] {
            #expect(priority(state, problemPersisted: persisted, isCompact: true) == .automatic)
            #expect(priority(state, problemPersisted: persisted, isCompact: false) == .automatic)
        }
    }

    private func priority(_ state: ConnectionIndicatorState, problemPersisted: Bool, isCompact: Bool)
        -> ToolbarItemVisibilityPriority
    {
        ConnectionIndicatorPresentation.visibilityPriority(
            for: state, problemPersisted: problemPersisted, isCompact: isCompact)
    }

    @Test func readsTheConnectionStateArgument() {
        let fixtures = [FixtureServer.launchArgument]
        #expect(FixtureServer.connectionState(arguments: fixtures + ["-ABSConnectionState", "offline"]) == .offline)
        #expect(
            FixtureServer.connectionState(arguments: fixtures + ["-ABSConnectionState", "serverUnreachable"])
                == .serverUnreachable)
        #expect(
            FixtureServer.connectionState(arguments: fixtures + ["-ABSConnectionState", "metered"])
                == .connected(cellular: false, metered: true))
        #expect(FixtureServer.connectionState(arguments: fixtures + ["-ABSConnectionState", "nonsense"]) == nil)
        #expect(FixtureServer.connectionState(arguments: fixtures + ["-ABSConnectionState"]) == nil)
        #expect(FixtureServer.connectionState(arguments: fixtures) == nil)
        // Only a fixture launch.
        #expect(FixtureServer.connectionState(arguments: ["-ABSConnectionState", "offline"]) == nil)
    }
}
