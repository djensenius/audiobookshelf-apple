import Foundation
import Testing

@testable import Audiobookshelf

@Suite struct PlaybackSpeedPresentationTests {
    private let locale = Locale(identifier: "en_US")

    @Test func rateLabelFormatsTrailingZeros() {
        #expect(PlaybackSpeedPresentation.label(1, locale: locale) == "1×")
        #expect(PlaybackSpeedPresentation.label(1.2, locale: locale) == "1.2×")
        #expect(PlaybackSpeedPresentation.label(10, locale: locale) == "10×")
        #expect(PlaybackSpeedPresentation.label(0.5, locale: locale) == "0.5×")
        // A stepped rate's binary error never shows.
        #expect(PlaybackSpeedPresentation.label(1.0 + 0.1 * 7, locale: locale) == "1.7×")
    }

    @Test func rateLabelShowsTwoDecimals() {
        // An off-grid rate saved elsewhere keeps its second decimal.
        #expect(PlaybackSpeedPresentation.label(1.25, locale: locale) == "1.25×")
    }

    @Test func rateLabelFollowsLocale() {
        #expect(PlaybackSpeedPresentation.label(1.5, locale: Locale(identifier: "de_DE")) == "1,5×")
    }
}
