import ABSAppModel
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

@Suite struct PlayerSheetPresentationTests {
    private let locale = Locale(identifier: "en_US")

    private func row(_ title: String = "Intro", start: Double, end: Double, id: Int = 0) -> PlayerChapterRow {
        PlayerChapterRow(id: id, chapter: Chapter(id: id, start: start, end: end, title: title))
    }

    @Test func chapterRowUntitledUsesNumber() {
        let blank = ChapterRowPresentation(
            row: row(" \n", start: 0, end: 10, id: 4), position: 5, rate: 1, locale: locale)
        #expect(blank.title == "Chapter 5")
        #expect(blank.accessibilityLabel.hasPrefix("Chapter 5, "))

        let titled = ChapterRowPresentation(row: row("Intro", start: 0, end: 10), position: 1, rate: 1, locale: locale)
        #expect(titled.title == "Intro")
    }

    @Test func chapterDurationAtRate() {
        // The start stays in media time, like the scrubber's elapsed time; the duration is at the
        // rate, like its remaining time.
        let fast = ChapterRowPresentation(row: row(start: 300, end: 390), position: 1, rate: 1.5, locale: locale)
        #expect(fast.startText == "5:00")
        #expect(fast.durationText == "1:00")
        #expect(fast.accessibilityLabel == "Intro, starts at 5 minutes, duration 1 minute")

        for rate in [0, -1, .nan, .infinity] {
            let fallback = ChapterRowPresentation(
                row: row(start: 300, end: 390), position: 1, rate: rate, locale: locale)
            #expect(fallback.durationText == "1:30", "rate \(rate)")
        }
    }

    @Test func timestampsOverOneHour() {
        let long = ChapterRowPresentation(
            row: row("Late", start: 3_723, end: 7_323), position: 2, rate: 1, locale: locale)
        #expect(long.startText == "1:02:03")
        #expect(long.durationText == "1:00:00")
        #expect(long.accessibilityLabel == "Late, starts at 1 hour, 2 minutes, 3 seconds, duration 1 hour")
    }

    @Test func sheetIDsAreStable() {
        #expect(PlayerSheet.chapters.id == "chapters")
        #expect(PlayerSheet.bookmarks.id == "bookmarks")
        #expect(PlayerSheet.speed.id == "speed")
        #expect(PlayerSheet.sleepTimer.id == "sleepTimer")
        #expect(Set([PlayerSheet.chapters, .bookmarks, .speed, .sleepTimer].map(\.id)).count == 4)
    }
}
