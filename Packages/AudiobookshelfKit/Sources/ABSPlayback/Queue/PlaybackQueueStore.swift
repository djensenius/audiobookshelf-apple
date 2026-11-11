import ABSCore
import Foundation

/// Persists each connection's ``PlaybackQueue``.
@MainActor
public protocol PlaybackQueueStoring: AnyObject {
    /// The saved queue, or empty when there is none.
    func load(serverConnectionID: UUID) -> [QueueItem]
    /// Saves `items`; an empty queue removes the saved one.
    func save(_ items: [QueueItem], serverConnectionID: UUID)
    /// Deletes the connection's saved queue, when the connection is removed.
    func removeQueue(serverConnectionID: UUID)
}

/// Keeps each connection's queue as JSON in `UserDefaults` (the App Group store by default), under
/// its own key, like ``UserDefaultsLastPlayedStore``. The queue is small, device-local state the
/// server doesn't have, so it isn't a SwiftData model (ADR 0003).
@MainActor
public final class UserDefaultsPlaybackQueueStore: PlaybackQueueStoring {
    public static let defaultKeyPrefix = "playback_queue_"

    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = AppSettings.sharedDefaults(),
        keyPrefix: String = UserDefaultsPlaybackQueueStore.defaultKeyPrefix
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load(serverConnectionID: UUID) -> [QueueItem] {
        guard let data = defaults.data(forKey: key(serverConnectionID)) else { return [] }
        return (try? JSONDecoder().decode([QueueItem].self, from: data)) ?? []
    }

    public func save(_ items: [QueueItem], serverConnectionID: UUID) {
        let key = key(serverConnectionID)
        if items.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }

    public func removeQueue(serverConnectionID: UUID) {
        defaults.removeObject(forKey: key(serverConnectionID))
    }

    private func key(_ serverConnectionID: UUID) -> String {
        keyPrefix + serverConnectionID.uuidString
    }
}
