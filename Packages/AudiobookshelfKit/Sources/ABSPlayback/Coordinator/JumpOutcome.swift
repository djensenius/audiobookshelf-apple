/// How one ``PlaybackCoordinator/jumpOutcome(by:)`` call ended.
public enum JumpOutcome: Sendable, Equatable {
    /// Playback landed at this global time.
    case landed(Double)
    /// Nothing landed yet, and nothing failed: the jump was queued while starting, a later seek or
    /// item superseded it, an interruption kept its target pending, or nothing is loaded.
    case deferred
    /// The target couldn't load (the engine's ``SeekResult/failed``).
    case failed

    /// Where playback landed, or `nil` unless ``landed(_:)``.
    public var landedTime: Double? {
        if case .landed(let time) = self { time } else { nil }
    }
}
