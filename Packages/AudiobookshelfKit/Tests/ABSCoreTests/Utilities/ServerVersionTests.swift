import ABSCore
import Testing

@Suite struct ServerVersionTests {
    @Test(arguments: [
        ("2.26.0", ServerVersion(2, 26, 0)), ("v2.37.2", ServerVersion(2, 37, 2)), (" 2.26 ", ServerVersion(2, 26, 0)),
        ("3", ServerVersion(3, 0, 0)), ("2.26.3-beta.1", ServerVersion(2, 26, 3)),
        ("2.30.0+abc", ServerVersion(2, 30, 0)),
    ])
    func parses(string: String, expected: ServerVersion) {
        #expect(ServerVersion(string) == expected)
    }

    @Test(arguments: ["", " ", "abc", "2.x.0", "2..0", "2.26.0.1", "-1.0.0", "2.26.", "２.26.0"])
    func rejects(string: String) {
        #expect(ServerVersion(string) == nil)
    }

    /// Mirrors the legacy `isValidVersion(current, min)` and `isServerVersionGreaterThanOrEqualTo`.
    @Test(arguments: [
        ("2.26.0", "2.26.0", true), ("2.26.1", "2.26.0", true), ("2.25.1", "2.26.0", false),
        ("2.25.9", "2.26.0", false), ("2.27.0", "2.26.3", true), ("3.0.0", "2.26.0", true),
        ("1.99.99", "2.26.0", false), ("2.100.0", "2.26.0", true), ("2.26", "2.26.0", true),
        ("2.26.0", "2.26", true), ("2.9.0", "2.17.0", false),
    ])
    func isAtLeast(current: String, minimum: String, expected: Bool) throws {
        let current = try #require(ServerVersion(current))
        let minimum = try #require(ServerVersion(minimum))
        #expect((current >= minimum) == expected)
    }

    @Test func describesVersion() {
        #expect(ServerVersion(2, 26, 3).description == "2.26.3")
    }
}

@Suite struct ServerFeaturesTests {
    @Test(arguments: [
        ("2.25.9", false), ("2.26.0", true), ("2.26.2", true), ("2.26.3", true), ("2.37.2", true), ("1.0.0", false),
    ])
    func minimumSupportedIs2_26_0(version: String, supported: Bool) throws {
        let features = try #require(ServerFeatures(serverVersion: version))
        #expect(features.isSupported == supported)
    }

    @Test func unparseableVersionHasNoFeatures() {
        #expect(ServerFeatures(serverVersion: "") == nil)
        #expect(ServerFeatures(serverVersion: "unknown") == nil)
    }

    @Test(arguments: [("2.26.0", true), ("2.26.2", true), ("2.26.3", false), ("2.28.0", false)])
    func nullIndexEpisodeTracksNeedTokenFallbackBelow2_26_3(version: String, needsFallback: Bool) throws {
        let features = try #require(ServerFeatures(serverVersion: version))
        #expect(features.supportsNullIndexEpisodeTracks == !needsFallback)
        #expect(features.requiresTokenFallback(forEpisodeTrackIndex: nil) == needsFallback)
        #expect(features.requiresTokenFallback(forEpisodeTrackIndex: 1) == false)
        #expect(features.requiresTokenFallback(forEpisodeTrackIndex: 0) == false)
    }
}
