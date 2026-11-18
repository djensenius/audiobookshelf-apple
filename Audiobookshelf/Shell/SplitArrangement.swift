import SwiftUI

/// What an `ArrangementView` split with `.split.axes(.horizontal)` shows, for the player (`SplitAxisReader`) and item
/// detail (`DetailPrimaryPane`), so both read `splitArrangementAxis` the same way (ADR 0004).
enum SplitArrangement {
    /// Whether the split shows its secondary pane beside the primary, from its `splitArrangementAxis`: only along the
    /// horizontal axis, the one `.split.axes(.horizontal)` splits along. The axis is `nil` while only the primary
    /// shows on the iPhone Duo, but vertical on an iPad in portrait, where only the primary shows too, so the primary
    /// must still offer the secondary content (inline or as sheets). #698
    static func showsSecondaryPane(axis: Axis?) -> Bool {
        axis == .horizontal
    }
}
