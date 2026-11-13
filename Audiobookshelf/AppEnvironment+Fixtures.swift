import Foundation

extension AppPlayback {
    /// The playback scopes' track URL override (`PlaybackScope.Configuration.trackURLOverride`)
    /// for this launch: the fixture server's (#46) when launched with its argument, so fixture
    /// sessions play the bundled silent audio, and `nil` otherwise. Always `nil` in Release, which
    /// has neither the fixture server nor its files.
    static var fixtureTrackURL: (@Sendable (URL) -> URL)? {
        fixtureTrackURL(arguments: ProcessInfo.processInfo.arguments)
    }

    /// The override for a launch with `arguments`.
    static func fixtureTrackURL(arguments: [String]) -> (@Sendable (URL) -> URL)? {
        #if DEBUG
            guard arguments.contains(FixtureServer.launchArgument) else { return nil }
            return { FixtureServer.trackURL($0) }
        #else
            nil
        #endif
    }
}
