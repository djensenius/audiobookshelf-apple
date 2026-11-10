import ABSRealtime
import Testing

@Suite struct ABSRealtimeTests {
    @Test func moduleIsLinked() {
        #expect(ABSRealtimeModule.name == "ABSRealtime")
    }
}
