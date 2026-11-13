import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import ABSUI

@MainActor
@Suite struct PlayerScrubberTests {
    private let locale = Locale(identifier: "en_US")

    @Test func remainingTimeIsANegativeTimestamp() {
        #expect(PlayerScrubber.remainingText(245, locale: locale) == "-4:05")
        #expect(PlayerScrubber.remainingText(3_723, locale: locale) == "-1:02:03")
        #expect(PlayerScrubber.remainingText(0, locale: locale) == "-0:00")
        #expect(PlayerScrubber.remainingText(.nan, locale: locale) == "-0:00")
    }

    @Test func accessibilityValueSpeaksElapsedAndRemaining() {
        let value = PlayerScrubber.accessibilityValue(elapsed: 245, remaining: 3_600, locale: locale)
        #expect(value == "4 minutes, 5 seconds, 1 hour remaining")
        let start = PlayerScrubber.accessibilityValue(elapsed: 0, remaining: 65, locale: locale)
        #expect(start == "0 seconds, 1 minute, 5 seconds remaining")
    }

    /// The "remaining" text is in the same language as the durations, not the app's language.
    @Test func accessibilityValueUsesTheLocalesLanguage() {
        let german = Locale(identifier: "de_DE")
        let value = PlayerScrubber.accessibilityValue(elapsed: 245, remaining: 3_600, locale: german)
        let remaining = DurationStyle.timestamp.accessibilityString(3_600, locale: german)
        #expect(value.hasSuffix(", \(remaining) verbleibend"))
        #expect(!value.contains("remaining"))
    }

    @Test func dragsMapToClampedFractions() {
        #expect(PlayerScrubber.fraction(atX: 50, width: 200) == 0.25)
        #expect(PlayerScrubber.fraction(atX: -10, width: 200) == 0)
        #expect(PlayerScrubber.fraction(atX: 250, width: 200) == 1)
        #expect(PlayerScrubber.fraction(atX: 10, width: 0) == 0)
        #expect(PlayerScrubber.fraction(atX: .nan, width: 200) == 0)
    }

    /// A scrubber that appends each callback's name to `calls`.
    private func recordingScrubber(_ calls: Recorder, allowsScrubbing: Bool = true) -> PlayerScrubber {
        PlayerScrubber(
            progress: 0.5, elapsed: 100, remaining: 100, onScrub: { _ in calls.values.append("scrub") },
            onScrubEnd: { calls.values.append("end") }, onIncrement: { calls.values.append("increment") },
            onDecrement: { calls.values.append("decrement") }, allowsScrubbing: allowsScrubbing)
    }

    @Test func aDragThatStopsEndsTheScrubOnce() {
        let calls = Recorder()
        let scrubber = recordingScrubber(calls)
        scrubber.draggingChanged(from: false, to: true)
        #expect(calls.values.isEmpty)
        // The gesture state resets to `false` both when the drag ends and when the system cancels
        // it (where `onEnded` never runs), so this one path ends the scrub in both cases.
        scrubber.draggingChanged(from: true, to: false)
        #expect(calls.values == ["end"])
        scrubber.draggingChanged(from: false, to: false)
        #expect(calls.values == ["end"])
    }

    @Test func adjustableActionCallsIncrementAndDecrement() {
        let calls = Recorder()
        let scrubber = recordingScrubber(calls)
        scrubber.adjust(.increment)
        scrubber.adjust(.decrement)
        scrubber.adjust(.increment)
        #expect(calls.values == ["increment", "decrement", "increment"])
    }

    /// A locked player (#505) can't be moved from VoiceOver's adjustable action either.
    @Test func aLockedScrubberIgnoresTheAdjustableAction() {
        let calls = Recorder()
        let scrubber = recordingScrubber(calls, allowsScrubbing: false)
        scrubber.adjust(.increment)
        scrubber.adjust(.decrement)
        #expect(calls.values.isEmpty)
    }
}

@MainActor
private final class Recorder {
    var values: [String] = []
}

@Suite struct TransportControlsTests {
    private let locale = Locale(identifier: "en_US")

    @Test func jumpSymbolsAreNumberedOnlyWhenSFSymbolsHasThem() {
        #expect(TransportControls.jumpSymbol(forward: true, seconds: 30) == "goforward.30")
        #expect(TransportControls.jumpSymbol(forward: false, seconds: 10) == "gobackward.10")
        #expect(TransportControls.jumpSymbol(forward: true, seconds: 20) == "goforward")
        #expect(TransportControls.jumpSymbol(forward: false, seconds: 120) == "gobackward")
    }

    @Test func jumpLabelsSpeakTheInterval() {
        #expect(TransportControls.jumpLabel(forward: true, seconds: 30, locale: locale) == "Jump forward 30 seconds")
        #expect(TransportControls.jumpLabel(forward: false, seconds: 60, locale: locale) == "Jump back 1 minute")
        #expect(
            TransportControls.jumpLabel(forward: false, seconds: 90, locale: locale) == "Jump back 1 minute, 30 seconds"
        )
    }

    /// Intervals without a numbered symbol show their length under the plain arrow.
    @Test func jumpCaptionShowsIntervalsWithoutANumberedSymbol() {
        #expect(TransportControls.jumpCaption(seconds: 10, locale: locale) == nil)
        #expect(TransportControls.jumpCaption(seconds: 30, locale: locale) == nil)
        #expect(TransportControls.jumpCaption(seconds: 120, locale: locale) == "2m")
        #expect(TransportControls.jumpCaption(seconds: 300, locale: locale) == "5m")
        #expect(TransportControls.jumpCaption(seconds: 150, locale: locale) == "2.5m")
        #expect(TransportControls.jumpCaption(seconds: 20, locale: locale) == "20s")
    }

    /// Too narrow for one row (as at accessibility text sizes on an iPhone), the full controls wrap
    /// into two rows instead of clipping: taller, and no wider than offered.
    @MainActor @Test func fullControlsWrapWhenTooNarrow() throws {
        let wide = try renderedSize(width: 400)
        let narrow = try renderedSize(width: 160)
        #expect(narrow.height > wide.height)
        #expect(narrow.width <= 160)
    }

    @MainActor private func renderedSize(width: CGFloat) throws -> CGSize {
        let controls = TransportControls(
            style: .full, showsPause: false, jumpBackwardSeconds: 10, jumpForwardSeconds: 30, hasPreviousChapter: true,
            hasNextChapter: true
        ) { _ in }
        let renderer = ImageRenderer(content: controls.frame(width: width).environment(\.locale, locale))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    @Test func playPauseLabelFollowsTheIntent() {
        #expect(TransportControls.playPauseLabel(showsPause: true) == "Pause")
        #expect(TransportControls.playPauseLabel(showsPause: false) == "Play")
    }

    @Test func bufferingPlayPauseSaysLoading() {
        #expect(TransportControls.playPauseAccessibilityValue(isBuffering: true) == "Loading...")
        #expect(TransportControls.playPauseAccessibilityValue(isBuffering: false).isEmpty)
    }

    /// The toolbar transport (#84) keeps everything the row has: both chapter buttons, enabled as
    /// the row's are, the buffering spinner and its value, and the captions of plain arrows.
    @Test func toolbarTransportMatchesTheRow() {
        let entries = TransportToolbarEntry.entries(
            showsPause: true, isBuffering: true, jumpBackwardSeconds: 20, jumpForwardSeconds: 30,
            hasPreviousChapter: false, hasNextChapter: true, locale: locale)
        #expect(entries.map(\.action) == [.previousChapter, .jumpBackward, .playPause, .jumpForward, .nextChapter])
        #expect(
            entries.map(\.accessibilityLabel) == [
                "Previous chapter", "Jump back 20 seconds", "Pause", "Jump forward 30 seconds", "Next chapter",
            ])
        #expect(entries.map(\.isEnabled) == [false, true, true, true, true])
        #expect(
            entries.map(\.symbol) == [
                "backward.end.fill", "gobackward", "pause.fill", "goforward.30", "forward.end.fill",
            ])
        #expect(entries.map(\.caption) == [nil, "20s", nil, nil, nil])
        #expect(entries[2].showsSpinner)
        #expect(entries[2].accessibilityValue == "Loading...")

        let idle = TransportToolbarEntry.entries(
            showsPause: false, isBuffering: false, jumpBackwardSeconds: 10, jumpForwardSeconds: 120,
            hasPreviousChapter: true, hasNextChapter: false, locale: locale)
        #expect(idle.map(\.isEnabled) == [true, true, true, true, false])
        #expect(idle[2].symbol == "play.fill")
        #expect(!idle[2].showsSpinner)
        #expect(idle[2].accessibilityValue.isEmpty)
        #expect(idle[3].caption == "2m")
    }

    /// A locked player (#505) keeps only play/pause in the toolbar.
    @Test func lockedToolbarTransportShowsOnlyPlayPause() {
        let entries = TransportToolbarEntry.entries(
            showsPause: true, isBuffering: false, jumpBackwardSeconds: 10, jumpForwardSeconds: 30,
            hasPreviousChapter: true, hasNextChapter: true, showsSkipControls: false, locale: locale)
        #expect(entries.map(\.action) == [.playPause])
    }
}
