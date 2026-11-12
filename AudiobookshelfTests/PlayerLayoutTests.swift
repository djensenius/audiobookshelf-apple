import CoreGraphics
import Testing

@testable import Audiobookshelf

/// The full player's layout selection (#84): from size classes, the fold and the toolbar's vertical
/// bar, never the device model.
@Suite struct PlayerLayoutTests {
    private func resolve(
        supported: Bool = true, regularWidth: Bool, regularHeight: Bool, fold: PlayerFold = .none,
        verticalToolbar: Bool = false
    ) -> PlayerLayout {
        PlayerLayout.resolve(
            supportsArrangements: supported, regularWidth: regularWidth, regularHeight: regularHeight, fold: fold,
            verticalToolbar: verticalToolbar)
    }

    /// Before iOS 27.1 and on macOS the player keeps its column, whatever the display.
    @Test func withoutArrangementsTheLayoutIsUnchanged() {
        for fold in [PlayerFold.none, .vertical, .horizontal] {
            for regular in [false, true] {
                let layout = resolve(
                    supported: false, regularWidth: regular, regularHeight: regular, fold: fold, verticalToolbar: true)
                #expect(layout == .fallback)
            }
        }
        #expect(PlayerLayout.fallback == PlayerLayout(arrangement: .column, transportInToolbar: false))
    }

    /// The inner display, flat or in book pose, splits the controls and the details half and half.
    @Test func aRegularDisplaySplits() {
        #expect(resolve(regularWidth: true, regularHeight: true).arrangement == .split)
        #expect(resolve(regularWidth: true, regularHeight: true, fold: .vertical).arrangement == .split)
        #expect(!resolve(regularWidth: true, regularHeight: true, verticalToolbar: true).transportInToolbar)
    }

    /// Laptop pose puts the controls on the bottom half, even on a regular display, instead of
    /// splitting them onto the top half.
    @Test func aHorizontalFoldIsTabletop() {
        for regular in [false, true] {
            let layout = resolve(
                regularWidth: regular, regularHeight: regular, fold: .horizontal, verticalToolbar: true)
            #expect(layout == PlayerLayout(arrangement: .tabletop, transportInToolbar: false))
        }
    }

    /// Compact sizes (the outer display, an iPhone) keep the column; the transport moves to the
    /// toolbar only when the toolbar is a vertical bar, so an iPhone keeps its bottom bar.
    @Test func compactSizesKeepTheColumn() {
        let sizes = [(false, false), (false, true), (true, false)]
        for (width, height) in sizes {
            #expect(
                resolve(regularWidth: width, regularHeight: height)
                    == PlayerLayout(arrangement: .column, transportInToolbar: false))
            #expect(
                resolve(regularWidth: width, regularHeight: height, verticalToolbar: true)
                    == PlayerLayout(arrangement: .column, transportInToolbar: true))
        }
    }

    /// The fold comes from the first active division's shape; none without one.
    @Test func theFoldFollowsTheDivisionsShape() {
        #expect(PlayerFold(divisions: []) == .none)
        #expect(PlayerFold(divisions: [CGRect(x: 400, y: 0, width: 20, height: 800)]) == .vertical)
        #expect(PlayerFold(divisions: [CGRect(x: 0, y: 400, width: 800, height: 20)]) == .horizontal)
        #expect(PlayerFold(divisions: [.zero]) == .none)
        #expect(
            PlayerFold(divisions: [.zero, CGRect(x: 0, y: 400, width: 800, height: 20)]) == .horizontal)
    }
}
