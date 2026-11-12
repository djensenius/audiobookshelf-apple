import ABSCore
import Foundation
import Synchronization

/// An ebook location and progress, compared as progress sync compares the ebook group: the same
/// location, and progress within ``progressTolerance`` or unknown on both sides.
public struct EbookPosition: Sendable, Equatable {
    /// How far two progress values may differ and still be the same position.
    public static let progressTolerance = 0.001

    public var location: String?
    public var progress: Double?

    public init(location: String?, progress: Double?) {
        self.location = location
        self.progress = progress
    }

    /// Whether `other` is the same position.
    public func matches(_ other: EbookPosition) -> Bool {
        guard location == other.location else { return false }
        switch (progress, other.progress) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return abs(lhs - rhs) <= Self.progressTolerance
        default: return false
        }
    }

    /// This position and, when its progress is unknown, the same location at 0: the server
    /// stores a missing `ebookProgress` as 0, so that is how a send of it is acknowledged.
    public var acknowledgeable: [EbookPosition] {
        progress == nil ? [self, EbookPosition(location: location, progress: 0)] : [self]
    }
}

extension ProgressBaseline {
    public var ebookPosition: EbookPosition { EbookPosition(location: ebookLocation, progress: ebookProgress) }
}

extension LocalMediaProgressDTO {
    public var ebookPosition: EbookPosition { EbookPosition(location: ebookLocation, progress: ebookProgress) }
}

extension MediaProgress {
    public var ebookPosition: EbookPosition { EbookPosition(location: ebookLocation, progress: ebookProgress) }
}

/// Orders ebook turns by when they were made, across every reader in the process, whatever the
/// wall clock does. A turn saved after a later one of the same media is dropped
/// (`LocalProgressStore.recordEbookTurn`).
public struct EbookTurnIntent: Sendable, Comparable, Hashable {
    private static let sequence = Atomic<UInt64>(0)

    let value: UInt64

    /// A new intent, after every one made before it.
    public static func next() -> EbookTurnIntent {
        EbookTurnIntent(value: sequence.add(1, ordering: .sequentiallyConsistent).newValue)
    }

    public static func < (lhs: EbookTurnIntent, rhs: EbookTurnIntent) -> Bool { lhs.value < rhs.value }
}
