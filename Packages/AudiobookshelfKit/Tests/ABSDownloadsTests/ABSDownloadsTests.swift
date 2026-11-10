import ABSDownloads
import Testing

@Suite struct ABSDownloadsTests {
    @Test func moduleIsLinked() {
        #expect(ABSDownloadsModule.name == "ABSDownloads")
    }
}
