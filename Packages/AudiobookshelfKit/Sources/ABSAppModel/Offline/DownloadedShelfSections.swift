import ABSCore
import ABSData
import Foundation

extension DownloadedShelfModel {
    /// The ID of the Local Books section.
    public nonisolated static let booksSectionID = "local-books"
    /// The ID of the Local Podcasts section.
    public nonisolated static let podcastsSectionID = "local-podcasts"

    /// The shelves as Home sections, as legacy `pages/bookshelf/index.vue` builds them: Local
    /// Books, then Local Podcasts, each left out while empty.
    ///
    /// - Parameter kind: Only the shelf of this kind. Online, legacy adds only the local shelf of
    ///   the current library's media type. `nil` (disconnected, or no library yet) gives both.
    public func sections(for kind: LibraryKind?) -> [HomeSection] {
        Self.sections(books: books, podcasts: podcasts, for: kind)
    }

    /// ``sections(for:)`` for the given shelves.
    nonisolated static func sections(
        books: [LocalLibraryItemDTO], podcasts: [LocalLibraryItemDTO], for kind: LibraryKind?
    ) -> [HomeSection] {
        var sections: [HomeSection] = []
        if kind != .podcast, !books.isEmpty {
            sections.append(
                HomeSection(
                    id: booksSectionID, titleKey: "LabelLocalBooks", label: "Local Books", kind: .book,
                    entries: books.map { .item(ItemSummary(localItem: $0)) }))
        }
        if kind != .book, !podcasts.isEmpty {
            sections.append(
                HomeSection(
                    id: podcastsSectionID, titleKey: "LabelLocalPodcasts", label: "Local Podcasts", kind: .podcast,
                    entries: podcasts.map { .item(ItemSummary(localItem: $0)) }))
        }
        return sections
    }
}

extension ItemSummary {
    /// A downloaded item as a card. It stands for the server's item (`libraryItemId`), so it
    /// opens and acts on that item. Its cover is keyed like the Downloads tab's, so the image
    /// pipeline serves the downloaded cover offline.
    ///
    /// A podcast is the whole podcast, as on the server's podcast shelves: no duration, and
    /// played per episode.
    public init(localItem item: LocalLibraryItemDTO) {
        let metadata = item.media.metadata
        let subtitle = [item.authorName ?? "", metadata.authors.joined(separator: ", ")].first { !$0.isEmpty }
        let cover = CoverRef(
            entityID: item.libraryItemId, updatedAt: LocalDownloadedCovers.version(of: item.coverUpdatedAt))
        if item.mediaType == .podcast {
            self.init(
                id: item.libraryItemId, itemID: item.libraryItemId, kind: .podcast, title: item.title,
                subtitle: subtitle, cover: cover, isExplicit: metadata.explicit, hasAudio: false)
            return
        }
        let duration = item.media.audioTracks.reduce(0) { $0 + max($1.duration, 0) }
        self.init(
            id: item.libraryItemId, itemID: item.libraryItemId, kind: .book, title: item.title, subtitle: subtitle,
            duration: duration.isFinite && duration > 0 ? duration : nil, cover: cover, isExplicit: metadata.explicit,
            isAbridged: metadata.abridged, hasAudio: item.files.contains { $0.kind == .audio })
    }
}
