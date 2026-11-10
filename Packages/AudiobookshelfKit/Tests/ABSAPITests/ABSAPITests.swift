import ABSAPI
import Testing

@Suite struct ABSAPITests {
    @Test func moduleIsLinked() {
        #expect(ABSAPIModule.name == "ABSAPI")
    }
}
