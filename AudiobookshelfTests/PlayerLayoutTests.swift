import CoreGraphics
import Testing

@testable import Audiobookshelf

/// The full player's layout selection (#84): from size classes, the fold and the toolbar's vertical
/// bar, never the device model.
@Suite struct PlayerLayoutTests {
    private func resolve(
        supported: Bool = true, regularWidth: Bool, regularHeight: Bool, fold: PlayerFold? = PlayerFold.flat,
        verticalToolbar: Bool = false
    ) -> PlayerLayout {
        PlayerLayout.resolve(
            supportsArrangements: supported, regularWidth: regularWidth, regularHeight: regularHeight, fold: fold,
            verticalToolbar: verticalToolbar)
    }

    /// Before iOS 27.1 and on macOS the player keeps its column, whatever the display.
    @Test func withoutArrangementsTheLayoutIsUnchanged() {
        for fold in [nil, PlayerFold.flat, .vertical, .horizontal] {
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

    /// A vertical fold at compact sizes (a compact window on a folding display) keeps the column;
    /// only a vertical bar moves the transport.
    @Test func aVerticalFoldAtCompactSizesKeepsTheColumn() {
        for verticalToolbar in [false, true] {
            let layout = resolve(
                regularWidth: false, regularHeight: true, fold: .vertical, verticalToolbar: verticalToolbar)
            #expect(layout == PlayerLayout(arrangement: .column, transportInToolbar: verticalToolbar))
        }
    }

    /// Until the fold is first measured the player keeps the column, so laptop pose doesn't build
    /// the split first and then flash to tabletop.
    @Test func anUnmeasuredFoldKeepsTheColumn() {
        for verticalToolbar in [false, true] {
            let layout = resolve(regularWidth: true, regularHeight: true, fold: nil, verticalToolbar: verticalToolbar)
            #expect(layout == PlayerLayout(arrangement: .column, transportInToolbar: verticalToolbar))
        }
    }

    /// The fold comes from the first active division's shape; flat without one.
    @Test func theFoldFollowsTheActiveDivisionsShape() {
        let tall = CGRect(x: 400, y: 0, width: 20, height: 800)
        let wide = CGRect(x: 0, y: 400, width: 800, height: 20)
        #expect(PlayerFold(divisions: []) == .flat)
        #expect(PlayerFold(divisions: [(tall, true)]) == .vertical)
        #expect(PlayerFold(divisions: [(wide, true)]) == .horizontal)
        #expect(PlayerFold(divisions: [(.zero, true)]) == .flat)
        #expect(PlayerFold(divisions: [(.zero, true), (wide, true)]) == .horizontal)
    }

    /// A division that isn't active (the display lies flat) is no fold, so an open, flat display
    /// splits instead of going tabletop.
    @Test func anInactiveDivisionIsNoFold() {
        let wide = CGRect(x: 0, y: 400, width: 800, height: 20)
        #expect(PlayerFold(divisions: [(wide, false)]) == .flat)
        #expect(
            PlayerFold(divisions: [(wide, false), (CGRect(x: 400, y: 0, width: 20, height: 800), true)]) == .vertical)
        let fold = PlayerFold(divisions: [(wide, false)])
        #expect(resolve(regularWidth: true, regularHeight: true, fold: fold).arrangement == .split)
    }

    /// The details pane shows bookmarks only where the toolbar would, and falls back to chapters
    /// when the selected tab is hidden.
    @Test func theDetailsTabsHideBookmarksWithTheirButton() {
        #expect(PlayerDetailsTab.visible(showsBookmarks: true) == [.chapters, .upNext, .bookmarks])
        let withoutBookmarks = PlayerDetailsTab.visible(showsBookmarks: false)
        #expect(withoutBookmarks == [.chapters, .upNext])
        #expect(PlayerDetailsTab.bookmarks.shown(in: withoutBookmarks) == .chapters)
        #expect(PlayerDetailsTab.upNext.shown(in: withoutBookmarks) == .upNext)
    }
}
