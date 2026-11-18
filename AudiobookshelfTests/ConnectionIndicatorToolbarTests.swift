import ABSAppModel
import SwiftUI
import Testing

@testable import Audiobookshelf

/// The connection indicator's toolbar priority (#691) and its fixture hook.
@MainActor
@Suite struct ConnectionIndicatorToolbarTests {
    /// In compact width a problem outranks the Library screen's filter and sort (`.high`), so the crowded Library
    /// root keeps it in its bar.
    @Test(arguments: [ConnectionIndicatorState.connecting, .offline, .serverUnreachable])
    func problemsOutrankTheLibraryControlsInCompactWidth(state: ConnectionIndicatorState) {
        #expect(ConnectionIndicatorPresentation.visibilityPriority(for: state, isCompact: true) > .high)
        #expect(ConnectionIndicatorPresentation.visibilityPriority(for: state, isCompact: false) == .automatic)
    }

    /// A working connection, however it's metered, keeps the default, so the filter and sort stay in the bar.
    @Test(arguments: [false, true], [false, true])
    func aConnectionKeepsTheDefault(cellular: Bool, metered: Bool) {
        let state = ConnectionIndicatorState.connected(cellular: cellular, metered: metered)
        #expect(ConnectionIndicatorPresentation.visibilityPriority(for: state, isCompact: true) == .automatic)
        #expect(ConnectionIndicatorPresentation.visibilityPriority(for: state, isCompact: false) == .automatic)
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
