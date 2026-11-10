import ABSCore
import Testing

@Suite struct AppVersionTests {
    @Test func describesMarketingVersionAndBuild() {
        #expect(AppVersion(marketing: "0.1.0", build: "1").description == "0.1.0 (1)")
    }
}
