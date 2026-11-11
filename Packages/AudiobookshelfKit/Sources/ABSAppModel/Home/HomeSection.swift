import ABSCore
import Foundation

/// What a ``HomeSection`` holds, from its shelf's ``ShelfType``.
public enum HomeSectionKind: Sendable, Hashable {
    case book
    /// Whole podcasts.
    case podcast
    /// Podcast episodes (``ItemSummary`` of kind `.episode`).
    case episode
    case series
    case authors
}

/// One card of a ``HomeSection``. All entries of a section have the case its ``HomeSectionKind``
/// implies: `.item` for book, podcast and episode sections, `.series` and `.author` otherwise.
public enum HomeEntry: Sendable, Hashable, Identifiable {
    case item(ItemSummary)
    case series(SeriesSummary)
    case author(AuthorSummary)

    /// The summary's ID, unique within a section.
    public var id: String {
        switch self {
        case .item(let item): item.id
        case .series(let series): series.id
        case .author(let author): author.id
        }
    }
}

/// A personalized shelf as Home shows it, a port of the shelves of the legacy
/// `pages/bookshelf/index.vue` and `components/bookshelf/Shelf.vue`.
public struct HomeSection: Sendable, Hashable, Identifiable {
    /// The shelf ID, for example `continue-listening`; stable across reloads.
    public let id: String
    /// The localization key of the title (the shelf's `labelStringKey`), for example
    /// `LabelContinueListening`.
    public let titleKey: String?
    /// The server's English title, for when ``titleKey`` is missing or unknown.
    public let label: String
    public let kind: HomeSectionKind
    /// Never empty.
    public let entries: [HomeEntry]

    public init(id: String, titleKey: String?, label: String, kind: HomeSectionKind, entries: [HomeEntry]) {
        self.id = id
        self.titleKey = titleKey
        self.label = label
        self.kind = kind
        self.entries = entries
    }

    /// The shelves whose items leave as soon as their progress is hidden from Continue Listening
    /// or finished. The server builds them from unhidden, unfinished progress
    /// (`continue-listening` for audio, episodes included, and `continue-reading` for ebooks), so
    /// the next reload would drop the item anyway.
    static let continueShelfIDs: Set<String> = ["continue-listening", "continue-reading"]

    /// Maps shelves to sections in server order. Shelves of an unknown type, whose entities don't
    /// match their type, or without entries are dropped.
    ///
    /// `progress` looks up an item's progress by library item and episode ID (pass
    /// ``ProgressCache/progress(libraryItemID:episodeID:)``). It is only called for the items of
    /// Continue Listening shelves, so observation tracks just those keys.
    public static func sections(
        from shelves: [Shelf], progress: (_ libraryItemID: String, _ episodeID: String?) -> MediaProgress?
    ) -> [HomeSection] {
        shelves.compactMap { shelf in
            guard let (kind, entries) = Self.entries(of: shelf) else { return nil }
            var kept = entries
            if continueShelfIDs.contains(shelf.id) {
                kept.removeAll { entry in
                    // A collapsed series stands for several books, so no single progress applies.
                    guard case .item(let item) = entry, item.kind != .series,
                        let progress = progress(item.itemID, item.episodeID)
                    else { return false }
                    return progress.hideFromContinueListening || progress.isFinished
                }
            }
            guard !kept.isEmpty else { return nil }
            return HomeSection(
                id: shelf.id, titleKey: shelf.labelStringKey, label: shelf.label, kind: kind, entries: kept)
        }
    }

    private static func entries(of shelf: Shelf) -> (HomeSectionKind, [HomeEntry])? {
        switch (shelf.type, shelf.entities) {
        case (.book, .libraryItems(let items)): (.book, items.map { .item(ItemSummary(item: $0)) })
        case (.podcast, .libraryItems(let items)): (.podcast, items.map { .item(ItemSummary(item: $0)) })
        case (.episode, .libraryItems(let items)): (.episode, items.map { .item(ItemSummary(item: $0)) })
        case (.series, .series(let series)): (.series, series.map { .series(SeriesSummary(series: $0)) })
        case (.authors, .authors(let authors)): (.authors, authors.map { .author(AuthorSummary(author: $0)) })
        default: nil
        }
    }
}
