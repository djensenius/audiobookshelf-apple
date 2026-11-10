import Foundation

extension DeepLink {
    /// The type of the `NSUserActivity` that item, episode and player screens publish for
    /// Handoff (ADR 0004). It is also listed in the app's `NSUserActivityTypes`, which the
    /// system requires before it delivers a continued activity.
    public static let handoffActivityType = "org.davidjensenius.Audiobookshelf.item"

    /// Reads a continued Handoff activity's `userInfo`, which becomes the same link a URL
    /// would, so ``Router/open(_:)`` stays the only way into navigation.
    ///
    /// The activity carries `item` (required), `episode`, `server`, `position` (seconds) and
    /// `library`, which opening an item doesn't need. An activity with a `position` becomes a
    /// `play` link, so continuing a player screen asks before it plays and never resumes
    /// silently (``PlayLinkDecision``); without one it opens the item, or the episode.
    ///
    /// The values are checked like a URL's. The result is `nil` without `userInfo`, when `item`
    /// is missing, or when `item`, `episode` or `server` isn't a valid ID (the same rules as
    /// ``init(url:)``); an empty `episode` or `server` counts as absent. A `position` that isn't
    /// a number from 0 to ``maxStartTime`` is ignored, and the activity still opens the item.
    public init?(handoff userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        let item = Self.handoffID(userInfo["item"])
        let episode = Self.handoffID(userInfo["episode"])
        let server = Self.handoffID(userInfo["server"])
        // A server we can't read must not fall back to the active server, so an invalid
        // optional entry rejects the activity instead of being dropped.
        guard case .valid(let itemID) = item, !episode.isInvalid, !server.isInvalid else { return nil }

        let position = (userInfo["position"] as? NSNumber)?.doubleValue
        if let position, (0...Self.maxStartTime).contains(position) {
            self.init(
                .play(PlayLink(itemID: itemID, episodeID: episode.id, startTime: position)), serverID: server.id)
        } else {
            self.init(.item(id: itemID, episodeID: episode.id), serverID: server.id)
        }
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
