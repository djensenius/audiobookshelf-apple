import ABSAppModel
import ABSCore
import ABSData
import AppIntents
import CoreSpotlight
import Foundation

// Spotlight's recently played items (#87): ``RecentItemsDonor`` decides what to index and when;
// these write it to the system index, associated with the item's App Intents entity.

extension BookEntity: IndexedEntity {}

extension PodcastEpisodeEntity: IndexedEntity {}

/// Writes ``RecentItemsDonor``'s items to `CSSearchableIndex`. Each item keeps its own identifier
/// and its account's domain (``PlayableEntityRecord/spotlightItem()``), and is associated with its
/// ``BookEntity`` or ``PodcastEpisodeEntity``, so Spotlight offers the entity's intents (Play).
@MainActor
final class SpotlightRecentItemsIndex: RecentItemsIndexing {
    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    func index(_ record: PlayableEntityRecord) async throws {
        let item = record.spotlightItem()
        if let book = BookEntity(record) {
            item.attributeSet.associateAppEntity(book)
        } else if let episode = PodcastEpisodeEntity(record) {
            item.attributeSet.associateAppEntity(episode)
        }
        try await index.indexSearchableItems([item])
    }

    func delete(identifiers: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    func deleteDomain(of connectionID: UUID) async throws {
        try await index.deleteSearchableItems(
            withDomainIdentifiers: [PlayableEntityRecord.spotlightDomain(connectionID)])
    }
}

/// Indexes nothing: a fixture or test environment's, so it never touches the user's Spotlight.
@MainActor
final class NoRecentItemsIndex: RecentItemsIndexing {
    func index(_ record: PlayableEntityRecord) async throws {}
    func delete(identifiers: [String]) async throws {}
    func deleteDomain(of connectionID: UUID) async throws {}
}

extension AppEnvironment {
    /// The test host's suite for ``RecentItemsDonor``'s bookkeeping, emptied at each launch.
    static let testHostRecentItemsSuite = "AppEnvironment.TestHost.RecentItems"

    /// Where ``RecentItemsDonor`` writes, and where it keeps its bookkeeping.
    ///
    /// Only the App Group store (`storeLocation` `.appGroup`) outside the app test host, the real
    /// app, writes the system index and keeps its bookkeeping in `settings`. A fixture or test
    /// environment indexes nothing. The test host's shared environment also uses the App Group
    /// store, so it indexes nothing either, and keeps its bookkeeping in a suite of its own,
    /// emptied at launch: a retry of the user's saved deletions would otherwise run against nothing
    /// and forget them.
    static func recentItemsStorage(
        storeLocation: DataStack.Location, isTestHost: Bool, settings: AppSettings
    ) -> (index: any RecentItemsIndexing, defaults: UserDefaults) {
        guard storeLocation == .appGroup else { return (NoRecentItemsIndex(), settings.defaults) }
        guard isTestHost else { return (SpotlightRecentItemsIndex(), settings.defaults) }
        UserDefaults.standard.removePersistentDomain(forName: testHostRecentItemsSuite)
        return (NoRecentItemsIndex(), UserDefaults(suiteName: testHostRecentItemsSuite) ?? .standard)
    }

    /// Spotlight's recently played items (#87): a ``SessionStage/connect`` participant that follows
    /// `player`, and deletes an account's items once it's removed, a switch to it or the launch's
    /// restore of it ends signed out, or its credentials are removed or expire.
    ///
    /// Only the real app writes the system index (``recentItemsStorage(storeLocation:isTestHost:settings:)``).
    static func makeRecentItemsDonor(
        accounts: AccountManager?, lifecycle: SessionLifecycle, player: PlayerViewModel, settings: AppSettings,
        storeLocation: DataStack.Location
    ) -> RecentItemsDonor {
        let (index, defaults) = recentItemsStorage(
            storeLocation: storeLocation, isTestHost: isTestHost, settings: settings)
        let donor = RecentItemsDonor(index: index, defaults: defaults)
        lifecycle.register(donor, stage: .connect)
        donor.follow(player)
        // Weakly: the lifecycle keeps the donor, whose observers keep these closures.
        donor.followRejectedSwitches { [weak lifecycle] in
            (lifecycle?.signedOutSwitches ?? 0, lifecycle?.signedOutSwitchConnectionID)
        }
        // After whatever the environment already runs on a removal or an expiry.
        if let accounts { donor.follow(accounts: accounts) }
        return donor
    }
}
