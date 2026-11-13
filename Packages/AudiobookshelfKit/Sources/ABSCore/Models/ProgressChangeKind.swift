/// How the user's progress on an item or episode changed, for listeners that must tell a reset
/// apart from any other change: auto-advance stops assuming an episode that ended on this device
/// is finished only once its progress is reset (#160).
public enum ProgressChangeKind: Sendable, Hashable {
    /// Anything that doesn't make it unfinished again: a new position, a finish, hiding it from
    /// Continue Listening.
    case updated
    /// Back to unfinished: a finished progress made unfinished (marked not finished), or the
    /// progress removed (discarded).
    case reset

    /// The kind of the change from `old` to `new`, `nil` meaning no progress.
    public init(from old: MediaProgress?, to new: MediaProgress?) {
        switch (old, new) {
        case (.some, nil): self = .reset
        case (let old?, let new?) where old.isFinished && !new.isFinished: self = .reset
        default: self = .updated
        }
    }
}
