import ABSCore
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct ContentViewTests {
    @Test func showsHostAppVersion() {
        let version = ContentView().version
        #expect(version.marketing == "0.1.0")
        #expect(version.build == "1")
    }

    @Test func versionDescriptionIncludesBuild() {
        #expect(AppVersion(marketing: "0.1.0", build: "1").description == "0.1.0 (1)")
    }
}
