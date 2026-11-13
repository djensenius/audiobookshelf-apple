import ABSData
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Spotlight's index of recently played items (#87), as ``RecentItemsDonor`` uses it. The app's
/// index associates each item with its `BookEntity` or `PodcastEpisodeEntity` and writes it to
/// `CSSearchableIndex`; tests pass a fake.
@MainActor
public protocol RecentItemsIndexing: AnyObject {
    /// Adds `record`'s item (``PlayableEntityRecord/spotlightItem()``), or updates it when its
    /// identifier is already indexed.
    func index(_ record: PlayableEntityRecord) async throws
    /// Deletes the items with these identifiers (``PlayableEntityRecord/id``).
    func delete(identifiers: [String]) async throws
    /// Deletes every item of `connectionID`'s account (``PlayableEntityRecord/spotlightDomain(_:)``).
    func deleteDomain(of connectionID: UUID) async throws
}

extension PlayableEntityRecord {
    /// The record of the item `key` names, as the player shows it: a book without an episode, an
    /// episode with one. The player has no series text.
    /// - Parameter subtitle: The author for a book, the podcast's title for an episode.
    public init(key: MediaKey, title: String, subtitle: String?, duration: TimeInterval?) {
        self.key = key
        kind = key.episodeId == nil ? .book : .episode
        self.title = title
        self.subtitle = subtitle
        seriesText = nil
        self.duration = duration
    }

    /// The Spotlight domain of `connectionID`'s items: the connection ID, so an account's items are
    /// deleted together, without touching another account's.
    public static func spotlightDomain(_ connectionID: UUID) -> String {
        connectionID.uuidString
    }

    /// What Spotlight shows and searches: the title, the author (a book's) or podcast (an
    /// episode's) and the duration.
    public var spotlightAttributes: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = subtitle
        if let subtitle {
            switch kind {
            case .book: attributes.authorNames = [subtitle]
            case .episode: attributes.album = subtitle
            }
        }
        attributes.duration = duration.map { NSNumber(value: $0) }
        return attributes
    }

    /// The searchable item: identified by ``id`` (the ``MediaKey``), so donating the item again
    /// updates it, in its account's ``spotlightDomain(_:)``. A tap opens the app with this
    /// identifier (``DeepLink/init(spotlightIdentifier:)``).
    public func spotlightItem() -> CSSearchableItem {
        CSSearchableItem(
            uniqueIdentifier: id, domainIdentifier: Self.spotlightDomain(key.serverConnectionID),
            attributeSet: spotlightAttributes)
    }
}

extension DeepLink {
    /// The link a tapped Spotlight result opens (`CSSearchableItemActivityIdentifier`): the item, or
    /// the episode, on the account it was played on (`server=`), so the router asks before
    /// switching rather than opening it on whichever account is active (ADR 0004). Opening it
    /// doesn't play it: Siri and the Play intents do (``PlayableEntityCatalog``).
    ///
    /// `nil` when `identifier` isn't a ``MediaKey``, or its item or episode isn't a valid ID.
    public init?(spotlightIdentifier identifier: String) {
        guard let key = MediaKey(rawValue: identifier), Self.isValidID(key.libraryItemId),
            key.episodeId.map(Self.isValidID) ?? true
        else { return nil }
        self.init(
            .item(id: key.libraryItemId, episodeID: key.episodeId), serverID: key.serverConnectionID.uuidString)
    }
}
