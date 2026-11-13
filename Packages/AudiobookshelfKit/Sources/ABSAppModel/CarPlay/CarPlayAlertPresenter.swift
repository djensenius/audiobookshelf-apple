/// Which alert CarPlay presents, one at a time: CarPlay presents a template only once the one
/// shown is dismissed, and a dismissal is animated. So a change while one is shown dismisses it,
/// and the alert wanted when that dismissal completes (the latest one requested, or none) is
/// presented then; changes during the dismissal only update that wish.
///
/// The scene performs each returned ``Command`` and reports a dismissal's completion with
/// ``didDismiss()``.
public struct CarPlayAlertPresenter<Alert: Hashable>: Sendable where Alert: Sendable {
    public enum Command: Hashable, Sendable {
        case present(Alert)
        case dismiss
    }

    /// The alert presented, or being dismissed.
    public private(set) var shown: Alert?
    /// The alert to show once settled, `nil` for none.
    public private(set) var wanted: Alert?
    /// Whether a dismissal is in flight.
    public private(set) var isDismissing = false

    public init() {}

    /// Wants `alert` shown, or none: what to do now, if anything.
    public mutating func request(_ alert: Alert?) -> Command? {
        wanted = alert
        return next()
    }

    /// The dismissal finished: presents the alert wanted now, if any.
    public mutating func didDismiss() -> Command? {
        isDismissing = false
        shown = nil
        return next()
    }

    /// The alert couldn't be presented: none is shown. It's presented again when requested again.
    public mutating func didFailToPresent(_ alert: Alert) {
        guard shown == alert, !isDismissing else { return }
        shown = nil
        if wanted == alert { wanted = nil }
    }

    private mutating func next() -> Command? {
        guard !isDismissing, wanted != shown else { return nil }
        if shown != nil {
            isDismissing = true
            return .dismiss
        }
        guard let wanted else { return nil }
        shown = wanted
        return .present(wanted)
    }
}
