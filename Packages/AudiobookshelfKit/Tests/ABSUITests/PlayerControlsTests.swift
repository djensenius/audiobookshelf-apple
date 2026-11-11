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
    private func recordingScrubber(_ calls: Recorder) -> PlayerScrubber {
        PlayerScrubber(
            progress: 0.5, elapsed: 100, remaining: 100, onScrub: { _ in calls.values.append("scrub") },
            onScrubEnd: { calls.values.append("end") }, onIncrement: { calls.values.append("increment") },
            onDecrement: { calls.values.append("decrement") })
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

    @Test func playPauseLabelFollowsTheIntent() {
        #expect(TransportControls.playPauseLabel(showsPause: true) == "Pause")
        #expect(TransportControls.playPauseLabel(showsPause: false) == "Play")
    }

    @Test func bufferingPlayPauseSaysLoading() {
        #expect(TransportControls.playPauseAccessibilityValue(isBuffering: true) == "Loading...")
        #expect(TransportControls.playPauseAccessibilityValue(isBuffering: false).isEmpty)
    }
}
