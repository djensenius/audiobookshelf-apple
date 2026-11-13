import ABSUI
import SwiftUI

/// A fold running down through item or episode detail (the iPhone Duo's in book pose, #85): the room on each side of
/// its `.division` reserved region, inside the detail's safe area.
///
/// Unlike the player's ``PlayerFold``, an inactive region counts: it is where the display folds once it does, so the
/// detail keeps one arrangement while the display folds and unfolds instead of rebuilding its panes, and their scroll
/// positions, at every change of pose.
struct DetailFold: Equatable, Sendable {
    /// The room between the safe area's leading edge and the fold, and between the fold and the trailing edge.
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat

    /// The first of `divisions` (the `.division` reserved regions, inactive ones included) that runs down through the
    /// safe area of a detail `width` wide; `nil` without one. A region taller than wide runs down (book pose); one
    /// wider than tall runs across (laptop pose), which a vertically scrolling detail ignores.
    /// - Parameters:
    ///   - width: The detail's width, safe area included.
    ///   - leadingInset, trailingInset: The safe area's insets on each side, such as a sidebar's, which can differ.
    ///   - divisions: The regions' frames in the detail's space, from its leading edge.
    init?(
        width: CGFloat, leadingInset: CGFloat = 0, trailingInset: CGFloat = 0,
        divisions: [(frame: CGRect, isActive: Bool)]
    ) {
        let safeMaxX = width - trailingInset
        guard safeMaxX.isFinite, leadingInset.isFinite,
            let frame = divisions.lazy.map(\.frame).first(where: {
                $0.height > $0.width && $0.minX.isFinite && $0.maxX.isFinite && $0.midX > leadingInset
                    && $0.midX < safeMaxX
            })
        else { return nil }
        leadingWidth = frame.minX - leadingInset
        trailingWidth = safeMaxX - frame.maxX
    }
}

/// How item and episode detail arrange themselves (#85): as before, or split at a fold that runs down through them,
/// so no text crosses the hinge in book pose. Picked from the display's fold, never from the device model or pose.
enum DetailArrangement: Equatable {
    /// One scroll view, laid out as before (``ItemDetailLayout``). Before iOS 27.1, on macOS, without a fold, across a
    /// fold that runs across (laptop pose), beside a fold that leaves a side too narrow, and until the fold is measured.
    case scroll
    /// An `ArrangementView` split half and half at the fold: the cover, title, actions and progress on one side, the
    /// description, chapters and tracks (or show notes) on the other.
    case split

    /// The narrowest either side of the fold can be for the split: the text column's minimum beside the cover.
    static let minimumPaneWidth = ItemDetailLayout.minimumTextColumnWidth

    /// - Parameters:
    ///   - supportsArrangements: Whether `ArrangementView` and reserved regions are available (iOS 27.1 and later).
    ///   - fold: The fold through the detail, from its reserved regions; `nil` without one or until measured.
    static func resolve(supportsArrangements: Bool, fold: DetailFold?) -> DetailArrangement {
        guard supportsArrangements, let fold,
            min(fold.leadingWidth, fold.trailingWidth) >= minimumPaneWidth
        else { return .scroll }
        return .split
    }
}

extension View {
    /// This scroll view, or, across a fold that runs down through it (``DetailArrangement/split``, iOS 27.1 and later),
    /// `primary` and `secondary` in a pane each on either side of the fold. Before iOS 27.1 and on macOS, always this
    /// view. Where the split doesn't go side by side, the primary pane shows `secondary` under `primary`.
    func detailSplitAtFold<Primary: View, Secondary: View>(
        @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary
    ) -> some View {
        DetailArrangementContainer(scroll: self, primary: primary(), secondary: secondary())
    }
}

/// Shows ``detailSplitAtFold(primary:secondary:)``'s scroll view or its split, from the display's fold.
private struct DetailArrangementContainer<Scroll: View, Primary: View, Secondary: View>: View {
    let scroll: Scroll
    let primary: Primary
    let secondary: Secondary

    var body: some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                DetailFoldReader(scroll: scroll, primary: primary, secondary: secondary)
            } else {
                scroll
            }
        #else
            scroll
        #endif
    }
}

#if os(iOS)
    /// Reads the fold from the detail's `.division` reserved regions, inactive ones included, and its safe area.
    @available(iOS 27.1, *)
    private struct DetailFoldReader<Scroll: View, Primary: View, Secondary: View>: View {
        let scroll: Scroll
        let primary: Primary
        let secondary: Secondary
        /// `nil` until the first geometry arrives, and without a fold.
        @State private var fold: DetailFold?

        var body: some View {
            Group {
                switch DetailArrangement.resolve(supportsArrangements: true, fold: fold) {
                case .scroll: scroll
                case .split: DetailSplit(primary: primary, secondary: secondary)
                }
            }
            .onGeometryChange(for: DetailFold?.self) { proxy in
                DetailFold(
                    width: proxy.size.width, leadingInset: proxy.safeAreaInsets.leading,
                    trailingInset: proxy.safeAreaInsets.trailing,
                    divisions: proxy.reservedRegions(kind: .division, options: .includeInactive).map {
                        ($0.frame, $0.isActive)
                    })
            } action: {
                fold = $0
            }
        }
    }

    /// The primary and secondary panes half and half, side by side only when wider than tall (ADR 0004); the split
    /// lines up with the fold.
    @available(iOS 27.1, *)
    private struct DetailSplit<Primary: View, Secondary: View>: View {
        let primary: Primary
        let secondary: Secondary

        var body: some View {
            ArrangementView {
                DetailPrimaryPane(primary: primary, secondary: secondary)
                    .splitArrangementLayoutRatio(0.5)
            } secondary: {
                DetailPane { secondary }
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        }
    }

    /// The primary pane, with the secondary content under it when the split shows only this pane.
    @available(iOS 27.1, *)
    private struct DetailPrimaryPane<Primary: View, Secondary: View>: View {
        let primary: Primary
        let secondary: Secondary
        @Environment(\.splitArrangementAxis) private var axis

        var body: some View {
            DetailPane {
                primary
                if axis == nil { secondary }
            }
        }
    }

    /// A pane's own scroll view, padded as the unsplit detail.
    private struct DetailPane<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: ABSSpacing.large) { content }
                    .padding(ItemDetailLayout.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
#endif
