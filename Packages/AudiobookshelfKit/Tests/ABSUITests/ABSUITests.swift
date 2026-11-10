import ABSUI
import Testing

@Suite struct ABSUITests {
    @Test func moduleIsLinked() {
        #expect(ABSUIModule.name == "ABSUI")
    }
}
