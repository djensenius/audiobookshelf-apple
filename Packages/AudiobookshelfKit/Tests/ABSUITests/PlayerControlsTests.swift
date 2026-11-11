import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import ABSUI

@MainActor
@Suite struct PlayerScrubberTests {
    private let locale = Locale(identifier: "en_US")

    @Test func remainingTimeIsANegativeTimestamp() {
        #expect(PlayerScrubber.remainingText(245) == "-4:05")
        #expect(PlayerScrubber.remainingText(3_723) == "-1:02:03")
        #expect(PlayerScrubber.remainingText(0) == "-0:00")
        #expect(PlayerScrubber.remainingText(.nan) == "-0:00")
    }

    @Test func accessibilityValueSpeaksElapsedAndRemaining() {
        let value = PlayerScrubber.accessibilityValue(elapsed: 245, remaining: 3_600, locale: locale)
        #expect(value == "4 minutes, 5 seconds, 1 hour remaining")
        let start = PlayerScrubber.accessibilityValue(elapsed: 0, remaining: 65, locale: locale)
        #expect(start == "0 seconds, 1 minute, 5 seconds remaining")
    }

    @Test func dragsMapToClampedFractions() {
        #expect(PlayerScrubber.fraction(atX: 50, width: 200) == 0.25)
        #expect(PlayerScrubber.fraction(atX: -10, width: 200) == 0)
        #expect(PlayerScrubber.fraction(atX: 250, width: 200) == 1)
        #expect(PlayerScrubber.fraction(atX: 10, width: 0) == 0)
        #expect(PlayerScrubber.fraction(atX: .nan, width: 200) == 0)
    }

    @Test func adjustableActionCallsIncrementAndDecrement() {
        var calls: [String] = []
        let scrubber = PlayerScrubber(
            progress: 0.5, elapsed: 100, remaining: 100, onScrub: { _ in calls.append("scrub") },
            onScrubEnd: { calls.append("end") }, onIncrement: { calls.append("increment") },
            onDecrement: { calls.append("decrement") })
        scrubber.adjust(.increment)
        scrubber.adjust(.decrement)
        scrubber.adjust(.increment)
        #expect(calls == ["increment", "decrement", "increment"])
    }
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
}
