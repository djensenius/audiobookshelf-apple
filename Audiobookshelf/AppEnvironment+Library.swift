import ABSAppModel
import ABSCore
import ABSData

extension AppEnvironment {
    /// Builds the library shared by every scene and CarPlay, and registers its participant as
    /// the lifecycle's seeder: it connects the store and seeds its progress for each session,
    /// and clears it when the session ends (#181).
    ///
    /// Each account's shared item actions (#368) update the local playback database through
    /// `playback`'s one ``AppPlayback/writer``, the writer every account's `ProgressSyncer` writes
    /// through, so its supersession tokens stay with that writer. They refuse to mark finished or
    /// not finished, or discard, the item in the player (``ItemActionError/itemInPlayer``): its
    /// session would write its position back. Disabling them is the simplest correct choice, and
    /// the user can close the player instead. A closed session's final sync and close can still be
    /// in flight, and another window can start the item while an action runs, so the actions also
    /// share `playback`'s ``AppPlayback/mediaLeases`` with the coordinators: they wait for those
    /// closes to settle, and a start of the item waits for them.
    static func makeLibrary(
        settings: AppSettings, accounts: AccountManager, lifecycle: SessionLifecycle, playback: AppPlayback
    ) -> LibraryParticipant {
        let writer = playback.writer
        let current = playback.current
        let store = LibraryStore(
            settings: settings,
            itemActionLocalSync: { key in
                writer.map { LocalProgressItemActionSync(store: $0, connectionID: key.connectionID) }
            },
            itemInPlayer: { [weak current] key, target in
                current?.mediaKey
                    == MediaKey(
                        serverConnectionID: key.connectionID, libraryItemId: target.libraryItemID,
                        episodeId: target.episodeID)
            },
            mediaLeases: playback.mediaLeases)
        let participant = LibraryParticipant(
            store: store,
            defaultLibraryID: { [weak accounts] in accounts?.authorization?.userDefaultLibraryId })
        lifecycle.register(seeder: participant)
        return participant
    }
}
