import ABSCore
import Foundation

/// Turns the app's models into CarPlay lists (#79, #80). Pure and template-agnostic: the CarPlay
/// delegate maps each ``CarPlayList`` to a `CPListTemplate` and each ``CarPlayRow`` to a
/// `CPListItem`, so the rules live here and are tested without CarPlay.
///
/// The Library tab's tree (ADR 0004), with each list's ``CarPlayDestination/depth``:
///
/// 1. Libraries
/// 2. A library's categories: Books, Series, Authors (a podcast library: Podcasts)
/// 3. Books (or podcasts), series or authors
/// 4. A series' or author's books, or a podcast's episodes
///
/// Tapping a book or episode plays it; Now Playing then fills the fifth level. A row that would
/// open a list deeper than ``CarPlayLimits/maximumDepth`` is left out, and a list deeper than it
/// has no rows. A row only opens the next level down, so a list's depth is its real place in the
/// stack: a collapsed series in a series' or author's books (level 4) is left out rather than
/// opening a fifth list, and its books stay reachable from the Series category.
///
/// Every list holds at most ``CarPlayLimits/maximumItemCount`` rows in at most
/// ``CarPlayLimits/maximumSectionCount`` sections. A paged list that has more rows, or whose
/// model hasn't reached its end, shows one row fewer and ends with a "More…" row
/// (``CarPlayRow/Action/more(_:offset:)``) that shows the list again from the next row.
/// Offsets count the model's loaded items (libraries, items, series, authors), including those
/// left out as rows, so they match ``rowsNeeded(offset:)``.
public struct CarPlayContentBuilder: Sendable {
    public let limits: CarPlayLimits
    public let labels: CarPlayLabels
    /// The account's server, for image keys; `nil` shows no images.
    public let serverID: UUID?
    /// The width bucket for row images: `ImageWidthBucket(pixelWidth:)` of
    /// `CPListItem.maximumImageSize` at the car screen's scale (ADR 0005).
    public let imageBucket: ImageWidthBucket

    public init(
        limits: CarPlayLimits = .standard, labels: CarPlayLabels, serverID: UUID?,
        imageBucket: ImageWidthBucket = .small
    ) {
        self.limits = limits
        self.labels = labels
        self.serverID = serverID
        self.imageBucket = imageBucket
    }

    // MARK: - Limits

    /// Whether a row may open `destination` within the depth limit.
    public func canOpen(_ destination: CarPlayDestination) -> Bool {
        destination.depth <= limits.maximumDepth
    }

    /// `sections` within the limits: empty sections dropped, at most
    /// ``CarPlayLimits/maximumSectionCount`` sections and ``CarPlayLimits/maximumItemCount`` rows
    /// in total, in order.
    public func trimmed(_ sections: [CarPlaySection]) -> [CarPlaySection] {
        var remaining = limits.maximumItemCount
        var result: [CarPlaySection] = []
        for section in sections where !section.rows.isEmpty {
            guard remaining > 0, result.count < limits.maximumSectionCount else { break }
            let rows = Array(section.rows.prefix(remaining))
            remaining -= rows.count
            result.append(CarPlaySection(id: section.id, header: section.header, rows: rows))
        }
        return result
    }

    /// How many items a paged list's model must have loaded to build the page from `offset`: load
    /// pages of the model until it has that many, or reached its end, before building the page.
    /// Offsets count the model's items, so a page whose items are all left out as rows still
    /// moves "More…" past them.
    public func rowsNeeded(offset: Int) -> Int {
        max(0, offset) + limits.maximumItemCount
    }

    // MARK: - Continue tab (#79)

    /// The Continue tab from Home's sections: the playable items of the Continue Listening shelf
    /// (`continue-listening`), with their progress, trimmed to the limit without "More…".
    public func continueListening(
        sections: [HomeSection], progress: (ItemSummary) -> ItemProgress?
    ) -> CarPlayList {
        let shelf = sections.first { $0.id == "continue-listening" }
        let items: [ItemSummary] = (shelf?.entries ?? []).compactMap {
            guard case .item(let item) = $0 else { return nil }
            return item
        }
        let rows = items.compactMap { item -> CarPlayRow? in
            guard item.kind == .book || item.kind == .episode else { return nil }
            return itemRow(item, in: .continueListening, progress: progress(item)?.fraction)
        }
        return list(.continueListening, title: labels.continueListening, rows: rows)
    }

    // MARK: - Library tab (#80)

    /// The Library tab's root: one row per library, in the given order.
    public func libraries(_ libraries: [Library], offset: Int = 0) -> CarPlayList {
        let rows = libraries.map { library -> CarPlayRow? in
            let destination = CarPlayDestination.library(id: library.id, mediaType: library.mediaType)
            guard canOpen(destination) else { return nil }
            return CarPlayRow(id: library.id, text: library.name, action: .open(destination))
        }
        return page(.libraries, title: labels.libraries, rows: rows, reachedEnd: true, offset: offset)
    }

    /// A library's categories: Books, Series and Authors, or Podcasts for a podcast library. Paged
    /// like the other lists, so every category is reachable at any item limit.
    public func library(_ library: Library, offset: Int = 0) -> CarPlayList {
        let id = library.id
        let categories: [(String, CarPlayDestination)] =
            switch library.mediaType {
            case .podcast: [(labels.podcasts, .items(libraryID: id))]
            case .book, .unknown:
                [
                    (labels.books, .items(libraryID: id)), (labels.series, .series(libraryID: id)),
                    (labels.authors, .authors(libraryID: id)),
                ]
            }
        let rows = categories.map { text, destination -> CarPlayRow? in
            guard canOpen(destination) else { return nil }
            return CarPlayRow(id: "\(destination.depth)-\(text)", text: text, action: .open(destination))
        }
        return page(
            .library(id: id, mediaType: library.mediaType), title: library.name, rows: rows, reachedEnd: true,
            offset: offset)
    }

    /// A page of items: books and episodes play, collapsed series and podcasts open their books or
    /// episodes. `items` are the model's loaded items and `reachedEnd` whether it has them all.
    public func items(
        _ items: [ItemSummary], reachedEnd: Bool, in destination: CarPlayDestination, title: String, offset: Int = 0
    ) -> CarPlayList {
        let libraryID = destination.libraryID ?? ""
        let rows = items.map { item -> CarPlayRow? in
            switch item.kind {
            case .book, .episode:
                return itemRow(item, in: destination, progress: nil)
            case .series:
                guard let seriesID = item.seriesID else { return nil }
                return openRow(item, .seriesBooks(libraryID: libraryID, seriesID: seriesID), from: destination)
            case .podcast:
                return openRow(
                    item, .podcastEpisodes(libraryID: libraryID, itemID: item.itemID), from: destination)
            }
        }
        return page(destination, title: title, rows: rows, reachedEnd: reachedEnd, offset: offset)
    }

    /// A page of a library's series; each opens its books.
    public func series(
        _ series: [SeriesSummary], reachedEnd: Bool, libraryID: String, offset: Int = 0
    ) -> CarPlayList {
        let rows = series.map { series -> CarPlayRow? in
            let destination = CarPlayDestination.seriesBooks(libraryID: libraryID, seriesID: series.id)
            guard canOpen(destination) else { return nil }
            return CarPlayRow(
                id: series.id, text: series.name, image: imageKey(series.covers.first), action: .open(destination))
        }
        return page(
            .series(libraryID: libraryID), title: labels.series, rows: rows, reachedEnd: reachedEnd, offset: offset)
    }

    /// A page of a library's authors; each opens their books.
    public func authors(
        _ authors: [AuthorSummary], reachedEnd: Bool, libraryID: String, offset: Int = 0
    ) -> CarPlayList {
        let rows = authors.map { author -> CarPlayRow? in
            let destination = CarPlayDestination.authorBooks(libraryID: libraryID, authorID: author.id)
            guard canOpen(destination) else { return nil }
            let image = serverID.flatMap { author.imageKey(serverID: $0, bucket: imageBucket) }
            return CarPlayRow(id: author.id, text: author.name, image: image, action: .open(destination))
        }
        return page(
            .authors(libraryID: libraryID), title: labels.authors, rows: rows, reachedEnd: reachedEnd, offset: offset)
    }

    // MARK: - Latest tab (#80)

    /// A page of a podcast library's newest episodes, each playing; `episodes` are the model's
    /// loaded episodes and `reachedEnd` whether it has them all. Anything but an episode is left
    /// out, as it would open a list below the tab's root.
    public func latestEpisodes(
        _ episodes: [ItemSummary], reachedEnd: Bool, libraryID: String, offset: Int = 0
    ) -> CarPlayList {
        items(
            episodes, reachedEnd: reachedEnd, in: .latestEpisodes(libraryID: libraryID), title: labels.latest,
            offset: offset)
    }

    // MARK: - Helpers

    private func itemRow(_ item: ItemSummary, in destination: CarPlayDestination, progress: Double?) -> CarPlayRow {
        CarPlayRow(
            id: item.id, text: item.title, image: imageKey(item.cover), progress: progress.map { min(max($0, 0), 1) },
            isEnabled: !item.isMissing && item.hasAudio, action: .play(itemID: item.itemID, episodeID: item.episodeID))
    }

    /// A row opening `destination` from the list `parent`, or `nil` unless `destination` is the
    /// next level down (so pushing it puts it at its own depth) and within the limit.
    private func openRow(
        _ item: ItemSummary, _ destination: CarPlayDestination, from parent: CarPlayDestination
    ) -> CarPlayRow? {
        guard destination.depth == parent.depth + 1, canOpen(destination) else { return nil }
        return CarPlayRow(id: item.id, text: item.title, image: imageKey(item.cover), action: .open(destination))
    }

    private func imageKey(_ cover: CoverRef?) -> ImageKey? {
        guard let cover, let serverID else { return nil }
        return cover.key(serverID: serverID, bucket: imageBucket)
    }

    /// A list that isn't paged: its rows trimmed to the limit. Empty when it's too deep.
    private func list(_ destination: CarPlayDestination, title: String, rows: [CarPlayRow]) -> CarPlayList {
        let rows = canOpen(destination) ? rows : []
        return CarPlayList(
            destination: destination, title: title, sections: trimmed([CarPlaySection(id: "rows", rows: rows)]))
    }

    /// The rows from `offset`. `rows` has one entry per loaded model item, `nil` for an item left
    /// out, and offsets index it. All the rows when they fit and the model reached its end;
    /// otherwise one row fewer than the limit, then "More…" pointing past the last item shown, or
    /// past the loaded items when they ran out, so "More…" always moves forward.
    private func page(
        _ destination: CarPlayDestination, title: String, rows: [CarPlayRow?], reachedEnd: Bool, offset: Int
    ) -> CarPlayList {
        guard canOpen(destination) else { return CarPlayList(destination: destination, title: title, sections: []) }
        let start = min(max(offset, 0), rows.count)
        let remaining = rows[start...].enumerated().compactMap { index, row in row.map { (start + index, $0) } }
        let limit = limits.maximumItemCount
        var shown: [CarPlayRow]
        if reachedEnd, remaining.count <= limit {
            shown = remaining.map(\.1)
        } else {
            let page = remaining.prefix(limit - 1)
            shown = page.map(\.1)
            let next = page.count == limit - 1 ? (page.last.map { $0.0 + 1 } ?? start) : rows.count
            shown.append(CarPlayRow(id: "more-\(next)", text: labels.more, action: .more(destination, offset: next)))
        }
        return CarPlayList(
            destination: destination, title: title, sections: trimmed([CarPlaySection(id: "rows", rows: shown)]),
            offset: start)
    }
}
