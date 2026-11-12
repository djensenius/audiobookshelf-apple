import CoreGraphics

/// Which way the display folds, from its active `.division` reserved regions: nothing while it
/// lies flat (the fold's region is inactive) or on a display that doesn't fold.
enum PlayerFold: Equatable {
    case none
    /// A vertical fold, side-by-side halves: book pose.
    case vertical
    /// A horizontal fold, a top half over a bottom half: laptop pose.
    case horizontal

    /// The fold of the first active division; `frames` are the active `.division` regions'
    /// frames. A region taller than wide is a vertical fold, wider than tall a horizontal one.
    init(divisions frames: [CGRect]) {
        guard let frame = frames.first(where: { $0.width != $0.height }) else {
            self = .none
            return
        }
        self = frame.height > frame.width ? .vertical : .horizontal
    }
}

/// How the full player arranges itself (#84). Picked from size classes, the fold and whether
/// the toolbar is a vertical bar, never from the device model, so an iPhone Duo, an iPad and an
/// iPhone get the layout their space calls for.
struct PlayerLayout: Equatable {
    enum Arrangement: Equatable, CaseIterable {
        /// One column: the cover, titles, scrubber, transport and secondary controls. The only
        /// layout before iOS 27.1, on macOS and in compact sizes, such as the Duo's outer display.
        case column
        /// An `ArrangementView` with the `.split` style at a 0.5 ratio: the cover and controls
        /// as primary, chapters, Up Next and bookmarks as secondary. Regular width and height,
        /// such as the Duo's inner display, flat or in book pose.
        case split
        /// An `ArrangementView` with the `.overlay` style: the cover and titles on the top half,
        /// the controls on the stable bottom half. Laptop pose; `.split` would put the primary
        /// controls on top.
        case tabletop
    }

    var arrangement: Arrangement
    /// Whether the transport buttons are in the toolbar, preferring its vertical bar, with the
    /// other actions in its overflow menu, instead of in the column. Only for the column, while
    /// the toolbar is a vertical bar (the Duo's outer display).
    var transportInToolbar: Bool

    /// The layout before iOS 27.1 and on macOS: unchanged.
    static let fallback = PlayerLayout(arrangement: .column, transportInToolbar: false)

    /// - Parameters:
    ///   - supportsArrangements: Whether `ArrangementView` and the vertical-bar toolbar APIs are
    ///     available (iOS 27.1 and later); otherwise the layout is ``fallback``.
    ///   - regularWidth, regularHeight: The horizontal and vertical size classes.
    ///   - fold: The display's fold, from its reserved regions.
    ///   - verticalToolbar: Whether the toolbar is a vertical bar (`toolbarVerticalEdge` isn't `nil`).
    static func resolve(
        supportsArrangements: Bool, regularWidth: Bool, regularHeight: Bool, fold: PlayerFold,
        verticalToolbar: Bool
    ) -> PlayerLayout {
        guard supportsArrangements else { return .fallback }
        if fold == .horizontal { return PlayerLayout(arrangement: .tabletop, transportInToolbar: false) }
        if regularWidth, regularHeight { return PlayerLayout(arrangement: .split, transportInToolbar: false) }
        return PlayerLayout(arrangement: .column, transportInToolbar: verticalToolbar)
    }
}
