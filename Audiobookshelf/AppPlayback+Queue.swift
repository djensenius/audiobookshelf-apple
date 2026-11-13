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

    /// Deletes a removed connection's saved queue, active or not, once the store has removed the
    /// connection (``AccountManager/connectionRemoved``), after whatever handler is already set. A
    /// removal that fails, deleting the credentials or saving the removal, keeps the queue along
    /// with the connection. Removing the active account ends its session first, which retires its
    /// scope and freezes its queue, so nothing saves it again.
    static func removesQueues(of accounts: AccountManager, from queues: UserDefaultsPlaybackQueueStore) {
        let previous = accounts.connectionRemoved
        accounts.connectionRemoved = { connectionID in
            previous?(connectionID)
            queues.removeQueue(serverConnectionID: connectionID)
        }
    }
}
