import ABSAppModel
import ABSCore

extension AppEnvironment {
    /// Builds the library shared by every scene and CarPlay, and registers its participant as
    /// the lifecycle's seeder: it connects the store and seeds its progress for each session,
    /// and clears it when the session ends (#181).
    static func makeLibrary(
        settings: AppSettings, accounts: AccountManager, lifecycle: SessionLifecycle
    ) -> LibraryParticipant {
        let participant = LibraryParticipant(
            store: LibraryStore(settings: settings),
            defaultLibraryID: { [weak accounts] in accounts?.authorization?.userDefaultLibraryId })
        lifecycle.register(seeder: participant)
        return participant
    }
}
