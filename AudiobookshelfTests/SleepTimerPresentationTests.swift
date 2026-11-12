import Foundation
import Testing

@testable import Audiobookshelf

@Suite struct SleepTimerPresentationTests {
    private let locale = Locale(identifier: "en_US")

    @Test func countdownTextFormats() {
        #expect(SleepTimerSlotPresentation.countdown(3_599, locale: locale) == "59:59")
        #expect(SleepTimerSlotPresentation.countdown(3_600, locale: locale) == "1:00:00")
        // Rounded up, so a fresh 15-minute timer shows 15:00 and the last half second 0:01.
        #expect(SleepTimerSlotPresentation.countdown(899.5, locale: locale) == "15:00")
        #expect(SleepTimerSlotPresentation.countdown(0.5, locale: locale) == "0:01")
        #expect(SleepTimerSlotPresentation.countdown(0, locale: locale) == "0:00")
    }

    @Test func slotAccessibilityValueWhenRunning() {
        let running = SleepTimerSlotPresentation(remaining: 899.5, isAutomatic: false, locale: locale)
        #expect(running.countdownText == "15:00")
        #expect(running.isAutomatic == false)
        #expect(running.symbolName == "moon.zzz")
        #expect(running.accessibilityLabel == "Sleep timer")
        #expect(running.accessibilityValue == "15 minutes remaining")

        let automatic = SleepTimerSlotPresentation(remaining: 3_600, isAutomatic: true, locale: locale)
        #expect(automatic.isAutomatic)
        #expect(automatic.symbolName == "moon.zzz.fill")
        #expect(automatic.accessibilityLabel == "Sleep timer")
        #expect(automatic.accessibilityValue == "Auto sleep timer, 1 hour remaining")
    }

    @Test func spokenRemainingChangesByTheMinute() {
        // Whole minutes, rounded up, so VoiceOver's value changes once a minute, not every tick.
        #expect(SleepTimerSlotPresentation.spokenRemaining(840.5, locale: locale) == "15 minutes")
        #expect(SleepTimerSlotPresentation.spokenRemaining(899, locale: locale) == "15 minutes")
        #expect(SleepTimerSlotPresentation.spokenRemaining(3_661, locale: locale) == "1 hour, 2 minutes")
        // Seconds in the last minute.
        #expect(SleepTimerSlotPresentation.spokenRemaining(60, locale: locale) == "1 minute")
        #expect(SleepTimerSlotPresentation.spokenRemaining(42.2, locale: locale) == "43 seconds")
        #expect(SleepTimerSlotPresentation.spokenRemaining(-1, locale: locale) == "0 seconds")
    }

    @Test func idleSlotHasNoValue() {
        let idle = SleepTimerSlotPresentation(remaining: nil, isAutomatic: true, locale: locale)
        #expect(idle.countdownText == nil)
        #expect(idle.isAutomatic == false)
        #expect(idle.accessibilityLabel == "Sleep timer")
        #expect(idle.accessibilityValue == nil)
    }
}
