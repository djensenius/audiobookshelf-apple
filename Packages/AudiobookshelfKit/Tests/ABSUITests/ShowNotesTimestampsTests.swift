import Foundation
import Testing

@testable import ABSUI

@Suite struct ShowNotesTimestampsTests {
    /// Each linked run's text and the seconds its link plays from.
    private func links(_ html: String, duration: Double? = nil) -> [(String, Int?)] {
        let text = ShowNotesTimestamps.link(HTMLText.attributedString(from: html), duration: duration)
        return text.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(text[run.range].characters), ShowNotesTimestamps.seconds(in: url))
        }
    }

    private func linkedTimes(_ text: String, duration: Double? = nil) -> [String] {
        links(text, duration: duration).map(\.0)
    }

    @Test func minutesAndSecondsAreLinked() {
        let found = links("Intro 0:45, news at 12:34 and 75:30.")
        #expect(found.map(\.0) == ["0:45", "12:34", "75:30"])
        #expect(found.map(\.1) == [45, 754, 4_530])
    }

    @Test func hoursMinutesAndSecondsAreLinked() {
        let found = links("<p>(1:02:03) Q&amp;A</p><p>10:00:00 wrap-up</p>")
        #expect(found.map(\.0) == ["1:02:03", "10:00:00"])
        #expect(found.map(\.1) == [3_723, 36_000])
    }

    @Test(arguments: ["99:99", "12:60", "1:60:00", "1:00:60", "1:2", "1:234", "123:45", "1:02:03:04"])
    func outOfRangeOrMalformedTimesAreNotLinked(time: String) {
        #expect(linkedTimes("at \(time) here").isEmpty)
    }

    @Test func timesPastTheEpisodeAreNotLinked() {
        #expect(linkedTimes("0:30 and 1:00:00", duration: 3_600) == ["0:30", "1:00:00"])
        #expect(linkedTimes("0:30 and 1:00:01", duration: 3_600) == ["0:30"])
        // An unknown duration links every valid time.
        #expect(linkedTimes("1:00:01", duration: 0) == ["1:00:01"])
    }

    @Test(arguments: [
        "a12:34", "12:34pm", "v1.12:34", "x_12:34", "/12:34", "12:34/", "#12:34", "t=12:34", "https://x.example/12:34",
    ])
    func timesInsideWordsOrPathsAreNotLinked(text: String) {
        #expect(linkedTimes(text).isEmpty)
    }

    @Test func aTimeInsideAnExistingLinkKeepsThatLink() {
        let found = links(#"<a href="https://example.com/ep">Chapter 12:34</a> then 5:00"#)
        #expect(found.map(\.0) == ["Chapter 12:34", "5:00"])
        #expect(found.first?.1 == nil)
        #expect(found.last?.1 == 300)
    }

    @Test func textWithoutTimesIsUnchanged() {
        let original = HTMLText.attributedString(from: "<p>No times here: just <b>notes</b>, 12 and 3.</p>")
        #expect(ShowNotesTimestamps.link(original, duration: 100) == original)
    }

    @Test func linksKeepTheirFormatting() throws {
        let text = ShowNotesTimestamps.link(HTMLText.attributedString(from: "<b>at 12:34</b>"), duration: nil)
        let range = try #require(text.range(of: "12:34"))
        #expect(text[range].inlinePresentationIntent == .stronglyEmphasized)
        #expect(text[range].link == ShowNotesTimestamps.url(seconds: 754))
    }

    @Test func urlsRoundTripAndOthersAreRejected() throws {
        #expect(ShowNotesTimestamps.seconds(in: ShowNotesTimestamps.url(seconds: 754)) == 754)
        #expect(ShowNotesTimestamps.seconds(in: ShowNotesTimestamps.url(seconds: 0)) == 0)
        for string in [
            "https://example.com/754", "abs-timestamp:", "abs-timestamp:-1", "abs-timestamp:1.5", "abs-timestamp:x",
        ] {
            let url = try #require(URL(string: string))
            #expect(ShowNotesTimestamps.seconds(in: url) == nil, "\(string)")
        }
    }
}
