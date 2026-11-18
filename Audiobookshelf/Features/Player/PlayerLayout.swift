import CoreGraphics

/// Which way the display folds, from its active `.division` reserved regions: nothing while it
/// lies flat (the fold's region is inactive) or on a display that doesn't fold.
enum PlayerFold: Equatable {
    /// No fold: the display lies flat or doesn't fold.
    case flat
    /// A vertical fold, side-by-side halves: book pose.
    case vertical
    /// A horizontal fold, a top half over a bottom half: laptop pose.
    case horizontal

    /// The fold of the first active division; `divisions` are the `.division` reserved regions.
    /// An inactive region (the display lies flat) doesn't count. A region taller than wide is a
    /// vertical fold, wider than tall a horizontal one.
    init(divisions: [(frame: CGRect, isActive: Bool)]) {
        guard let frame = divisions.first(where: { $0.isActive && $0.frame.width != $0.frame.height })?.frame else {
            self = .flat
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
        /// layout before iOS 27.1, on macOS and in compact sizes without a fold, such as the Duo's
        /// outer display.
        case column
        /// An `ArrangementView` with the `.split.axes(.horizontal)` style at a 0.5 ratio: the cover
        /// and controls as primary, chapters, Up Next and bookmarks as secondary. Regular width
        /// and height, such as the Duo's inner display lying flat, or any size across a vertical
        /// fold (book pose), so nothing crosses the hinge. It only splits when
        /// wider than tall (ADR 0004); otherwise, as on an iPad in portrait, the primary fills it
        /// and the details open as sheets.
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
    ///   - fold: The display's fold, from its reserved regions; `nil` until it's first measured,
    ///     which keeps the column so laptop pose doesn't flash the split first.
    ///   - verticalToolbar: Whether the toolbar is a vertical bar (`toolbarVerticalEdge` isn't `nil`).
    static func resolve(
        supportsArrangements: Bool, regularWidth: Bool, regularHeight: Bool, fold: PlayerFold?,
        verticalToolbar: Bool
    ) -> PlayerLayout {
        guard supportsArrangements else { return .fallback }
        guard let fold else { return PlayerLayout(arrangement: .column, transportInToolbar: verticalToolbar) }
        if fold == .horizontal { return PlayerLayout(arrangement: .tabletop, transportInToolbar: false) }
        // An active vertical fold splits at any size: the column would put the scrubber and
        // transport across the hinge.
        if fold == .vertical || (regularWidth && regularHeight) {
            return PlayerLayout(arrangement: .split, transportInToolbar: false)
        }
        return PlayerLayout(arrangement: .column, transportInToolbar: verticalToolbar)
    }
}

/// The split arrangement's details pane tabs.
enum PlayerDetailsTab: CaseIterable {
    case chapters, upNext, bookmarks

    var titleKey: String {
        switch self {
        case .chapters: "HeaderChapters"
        case .upNext: "HeaderUpNext"
        case .bookmarks: "HeaderPlayerBookmarks"
        }
    }

    /// The tabs to show: bookmarks only where the toolbar would show them (not for podcast episodes).
    static func visible(showsBookmarks: Bool) -> [Self] {
        allCases.filter { $0 != .bookmarks || showsBookmarks }
    }

    /// The tab to show for this selection: itself if visible, else chapters.
    func shown(in visible: [Self]) -> Self {
        visible.contains(self) ? self : .chapters
    }
}
