import ABSCore
import SwiftUI
import Testing

@testable import ABSUI

/// Voice Control names and Reduce Motion in the shared views (#106).
@MainActor
@Suite struct AccessibilityTests {
    // MARK: Voice Control

    /// "Tap The Gods of Mars" works, and so does the full VoiceOver label.
    @Test func cardsAreNamedByTheirTitleThenTheirFullLabel() {
        let item = ItemSummary(item: SampleLibrary.godsOfMars)
        #expect(
            CardAccessibility.inputLabels(title: item.title, label: ItemPresentation.accessibilityLabel(item))
                == ["The Gods of Mars", "The Gods of Mars, Edgar Rice Burroughs, Barsoom #2"])
    }

    @Test func aCardWhoseLabelIsItsTitleHasOneName() {
        #expect(CardAccessibility.inputLabels(title: "Dune", label: "Dune") == ["Dune"])
    }

    // MARK: Reduce Motion

    @Test func scrubberThumbResizesAtOnceWithReduceMotion() {
        #expect(PlayerScrubber.thumbAnimation(reduceMotion: true) == nil)
        #expect(PlayerScrubber.thumbAnimation(reduceMotion: false) != nil)
    }

    @Test func readMoreExpandsAtOnceWithReduceMotion() {
        #expect(ExpandableText.toggleAnimation(reduceMotion: true) == nil)
        #expect(ExpandableText.toggleAnimation(reduceMotion: false) != nil)
    }

    @Test func connectingIconPulsesOnlyWithoutReduceMotion() {
        #expect(ConnectionStatus.connecting.pulses(reduceMotion: false))
        #expect(!ConnectionStatus.connecting.pulses(reduceMotion: true))
        #expect(!ConnectionStatus.offline.pulses(reduceMotion: false))
    }
}
