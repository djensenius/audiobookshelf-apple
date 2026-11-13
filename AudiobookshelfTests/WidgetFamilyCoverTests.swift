import Testing
import WidgetKit

@testable import Audiobookshelf

/// The Continue Listening widget loads its cover only for the families that draw it (#89).
@Suite struct WidgetFamilyCoverTests {
    @Test func onlyTheHomeScreenFamiliesLoadTheCover() {
        #expect(WidgetFamily.systemSmall.showsContinueListeningCover)
        #expect(WidgetFamily.systemMedium.showsContinueListeningCover)
        // Not offered, but a family outside the two draws no cover either.
        #expect(!WidgetFamily.systemLarge.showsContinueListeningCover)
        // The accessory families are iOS-only; the app tests run on macOS, so CI checks the line above.
        #if os(iOS)
            for family in [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline] {
                #expect(!family.showsContinueListeningCover, "\(family)")
            }
        #endif
    }
}
