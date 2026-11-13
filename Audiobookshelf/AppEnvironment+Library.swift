import ABSAppModel
import ABSCore
import ABSData
import ABSPlayback

extension AppEnvironment {
    /// Builds the library shared by every scene and CarPlay, and registers its participant as
    /// the lifecycle's seeder: it connects the store and seeds its progress for each session,
    /// and clears it when the session ends (#181).
    ///
    /// Each account's shared item actions (#368) update the local playback database through
    /// `writer`, the one ``AppPlayback/writer`` every account's `ProgressSyncer` writes through, so
    /// its supersession tokens stay with that writer. They refuse to mark finished or
    /// not finished, or discard, the item in the player (``ItemActionError/itemInPlayer``): its
    /// session would write its position back. Disabling them is the simplest correct choice, and
    /// the user can close the player instead. A closed session's final sync and close can still be
    /// in flight, and another window can start the item while an action runs, so the actions also
    /// share `mediaLeases` (``AppPlayback/mediaLeases``) with the coordinators: they wait for those
    /// closes to settle, and a start of the item waits for them. They also clear the account's
    /// last-played record of the media (the store the account's scope restores from), whose
    /// position predates the action. `current` is playback's ``AppPlayback/current``.
    static func makeLibrary(
        settings: AppSettings, accounts: AccountManager, lifecycle: SessionLifecycle, writer: LocalProgressStore?,
        current: CurrentPlayback, mediaLeases: MediaLeases
    ) -> LibraryParticipant {
        let store = LibraryStore(
            settings: settings,
            itemActionLocalSync: { key in
                writer.map {
                    LocalProgressItemActionSync(
                        store: $0, connectionID: key.connectionID,
                        lastPlayed: {
                            PlaybackScope.lastPlayedStore(for: key.connectionID, defaults: settings.defaults)
                        })
                }
            },
            itemInPlayer: { [weak current] key, target in
                current?.mediaKey
                    == MediaKey(
                        serverConnectionID: key.connectionID, libraryItemId: target.libraryItemID,
                        episodeId: target.episodeID)
            },
            mediaLeases: mediaLeases)
        let participant = LibraryParticipant(
            store: store,
            defaultLibraryID: { [weak accounts] in accounts?.authorization?.userDefaultLibraryId })
        lifecycle.register(seeder: participant)
        return participant
    }
}
