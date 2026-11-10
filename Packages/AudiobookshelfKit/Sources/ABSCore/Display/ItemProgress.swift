import Foundation

/// A user's progress on one item, as a cell needs it.
public struct ItemProgress: Sendable, Hashable {
    /// `0...1`; `1` when finished.
    public let fraction: Double
    public let isFinished: Bool
    public let isHiddenFromContinue: Bool

    public init(fraction: Double, isFinished: Bool = false, isHiddenFromContinue: Bool = false) {
        self.fraction = isFinished ? 1 : (fraction.isFinite ? min(max(fraction, 0), 1) : 0)
        self.isFinished = isFinished
        self.isHiddenFromContinue = isHiddenFromContinue
    }

    public init(_ progress: MediaProgress) {
        self.init(
            fraction: progress.progress == 0 ? progress.ebookProgress ?? 0 : progress.progress,
            isFinished: progress.isFinished,
            isHiddenFromContinue: progress.hideFromContinueListening)
    }

    /// Some progress and not finished.
    public var isInProgress: Bool { !isFinished && fraction > 0 }
}
