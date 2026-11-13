/// How the user's progress on an item or episode changed, for listeners that must tell a finish
/// or a reset apart from any other change: auto-advance stops assuming an episode that ended on
/// this device is finished only once the server has shown it finished and its progress is then
/// reset (#160).
public enum ProgressChangeKind: Sendable, Hashable {
    /// Anything that neither leaves it finished nor makes it unfinished again: a new position on
    /// an unfinished one, or a change the server hasn't confirmed yet (an optimistic action).
    case updated
    /// Finished, with the change confirmed: from the server, or an action the server accepted.
    case finished
    /// Back to unfinished: a finished progress made unfinished (marked not finished), or the
    /// progress removed (discarded).
    case reset

    /// The kind of the change from `old` to `new`, `nil` meaning no progress.
    public init(from old: MediaProgress?, to new: MediaProgress?) {
        switch (old, new) {
        case (.some, nil): self = .reset
        case (let old?, let new?) where old.isFinished && !new.isFinished: self = .reset
        case (_, let new?) where new.isFinished: self = .finished
        default: self = .updated
        }
    }
}
