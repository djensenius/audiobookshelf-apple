import ABSAppModel
import ABSCore
import ABSPlayback
import Foundation

extension AppPlayback {
    /// Where each connection's play queue is saved, under a key of its own: the settings'
    /// defaults, like its last-played record.
    static func queueStore(settings: AppSettings) -> UserDefaultsPlaybackQueueStore {
        UserDefaultsPlaybackQueueStore(defaults: settings.defaults)
    }

    /// Deletes a removed connection's saved queue, active or not, once its credentials are deleted
    /// (``AccountManager/credentialsRemoved``), after whatever handler is already set: the
    /// downloads', so call this after they're built. A removal that fails keeps the queue, along
    /// with the connection. Removing the active account ends its session first, which retires its
    /// scope and freezes its queue, so nothing saves it again.
    static func removesQueues(of accounts: AccountManager, from queues: UserDefaultsPlaybackQueueStore) {
        let previous = accounts.credentialsRemoved
        accounts.credentialsRemoved = { connectionID in
            await previous?(connectionID)
            queues.removeQueue(serverConnectionID: connectionID)
        }
    }
}
