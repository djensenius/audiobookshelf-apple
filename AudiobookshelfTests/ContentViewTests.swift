import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct ContentViewTests {
    @Test func showsHostAppVersion() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let marketing = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)

        let version = ContentView().version
        #expect(version.marketing == marketing)
        #expect(version.build == build)
        // Not AppVersion's fallback, so the host app's Info.plist was read.
        #expect(version != AppVersion(marketing: "0.0.0", build: "0"))
    }
}
