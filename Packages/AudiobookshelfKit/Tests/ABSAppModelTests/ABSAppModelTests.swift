import ABSAppModel
import Testing

@Suite struct ABSAppModelTests {
    @Test func moduleIsLinked() {
        #expect(ABSAppModelModule.name == "ABSAppModel")
    }
}
