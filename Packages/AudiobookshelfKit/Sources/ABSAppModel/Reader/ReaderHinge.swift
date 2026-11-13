import CoreGraphics

/// The hinge a reader spreads around on a spanned iPhone Duo (ADR 0008, decision 7), from the
/// `.division` reserved regions over the reader area, for ``ReaderSpreadPolicy``'s `hingeWidth`.
public enum ReaderHinge {
    /// The gap kept over an active division with no width, so the reader still counts as spanned;
    /// the same 32 points `ItemGrid` reserves over a fold.
    public static let minimumGap: CGFloat = 32

    /// The width of the first active division running down through a reader `readerWidth` wide, or
    /// `nil` without one. Like the player's fold, an inactive region (the display lies flat) doesn't
    /// count; a region wider than tall runs across the reader (laptop pose) and doesn't either.
    public static func width(readerWidth: CGFloat, divisions: [(frame: CGRect, isActive: Bool)]) -> CGFloat? {
        guard readerWidth.isFinite,
            let frame = divisions.first(where: {
                $0.isActive && $0.frame.height > $0.frame.width && $0.frame.minX.isFinite && $0.frame.maxX.isFinite
                    && $0.frame.midX > 0 && $0.frame.midX < readerWidth
            })?.frame
        else { return nil }
        return frame.width > 0 ? frame.width : minimumGap
    }
}
