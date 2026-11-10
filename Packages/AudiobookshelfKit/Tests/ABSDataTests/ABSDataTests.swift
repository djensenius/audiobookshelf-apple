import ABSData
import Testing

@Suite struct ABSDataTests {
    @Test func moduleIsLinked() {
        #expect(ABSDataModule.name == "ABSData")
    }
}
