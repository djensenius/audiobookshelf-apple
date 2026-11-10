import ABSPlayback
import Testing

@Suite struct ABSPlaybackTests {
    @Test func moduleIsLinked() {
        #expect(ABSPlaybackModule.name == "ABSPlayback")
    }
}
