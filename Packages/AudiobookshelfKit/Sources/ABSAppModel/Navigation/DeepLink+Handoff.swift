import Foundation

extension DeepLink {
    /// The type of the `NSUserActivity` that item, episode and player screens publish for
    /// Handoff (ADR 0004). It is also listed in the app's `NSUserActivityTypes`, which the
    /// system requires before it delivers a continued activity.
    public static let handoffActivityType = "org.davidjensenius.Audiobookshelf.item"

    /// Reads a continued Handoff activity's `userInfo`, which becomes the same link a URL
    /// would, so ``Router/open(_:)`` stays the only way into navigation.
    ///
    /// The activity carries `item` (required), `episode` and `position` (seconds). A `library`
    /// entry is ignored, because opening an item doesn't need it. The link names no server, so
    /// the account that is active here opens it; ``HandoffActivity`` also reads the optional
    /// `serverAddress` and `userID` pair and resolves it to a connection here (ADR 0004,
    /// "Handoff"). A `server` entry, whatever it holds, is ignored: it would be the sending
    /// device's connection ID, which means nothing on this one.
    ///
    /// An activity with a `position` becomes a `play` link, so continuing a player screen asks
    /// before it plays and never resumes silently (``PlayLinkDecision``); without one it opens
    /// the item, or the episode.
    ///
    /// The values are checked like a URL's. The result is `nil` without `userInfo`, when `item`
    /// is missing, or when `item` or `episode` isn't a valid ID (the same rules as
    /// ``init(url:)``); an empty `episode` counts as absent. It is `nil` too when only one of
    /// `serverAddress` and `userID` is present, or either is invalid. A `position` that isn't a
    /// number from 0 to ``maxStartTime`` (a Boolean isn't one) is ignored, and the activity
    /// still opens the item.
    public init?(handoff userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        let item = Self.handoffID(userInfo["item"])
        let episode = Self.handoffID(userInfo["episode"])
        // An episode we can't read rejects the activity instead of opening the item without it.
        guard case .valid(let itemID) = item, !episode.isInvalid else { return nil }
        // So is an account it can't name: opening it on whichever account is active could show
        // another user's library (``HandoffActivity``).
        guard Self.handoffAccount(userInfo) != .invalid else { return nil }

        if let position = Self.handoffPosition(userInfo["position"]) {
            self.init(.play(PlayLink(itemID: itemID, episodeID: episode.id, startTime: position)))
        } else {
            self.init(.item(id: itemID, episodeID: episode.id))
        }
    }

    /// A start time from an activity: a number from 0 to ``maxStartTime``. Booleans are
    /// `NSNumber`s too, so they are told apart, or `true` would start the item at one second.
    private static func handoffPosition(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        return (0...maxStartTime).contains(seconds) ? seconds : nil
    }

    /// An ID read from an activity: absent (or empty), valid, or present but not a valid ID.
    private enum HandoffID {
        case absent
        case valid(String)
        case invalid

        var id: String? {
            if case .valid(let id) = self { id } else { nil }
        }

        var isInvalid: Bool {
            if case .invalid = self { true } else { false }
        }
    }

    private static func handoffID(_ value: Any?) -> HandoffID {
        guard let value else { return .absent }
        guard let text = value as? String else { return .invalid }
        if text.isEmpty { return .absent }
        return isValidID(text) ? .valid(text) : .invalid
    }
}
