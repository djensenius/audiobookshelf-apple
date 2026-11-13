import ABSAPI
import ABSCore
import Foundation
import Observation

/// The endpoints CarPlay's Library and Latest tabs load from. `LibraryStoreServices` conforms
/// (``LibraryStore/makeServices()``); tests use fakes.
public typealias CarPlayBrowseService = LibraryService & ItemDetailService & SeriesAuthorsService
    & LatestEpisodesService

/// Whether a browse list has something to show yet.
public enum CarPlayBrowseStatus: Sendable, Hashable {
    /// Its first page is on its way, or hasn't been asked for.
    case loading
    /// Its first page failed; ``CarPlayBrowseModel/refresh(_:offset:)`` retries it.
    case failed
    /// It has rows, or it's known to have none.
    case loaded
}

/// CarPlay's Library and Latest tabs (#80) for one signed-in account: what each list of the
/// browse tree (``CarPlayContentBuilder``) shows, and the loads behind it. The CarPlay delegate
/// shows ``list(_:offset:)`` for each list template it has, calls ``load(_:offset:)`` when it
/// shows one or pages it with "More…", ``refresh(_:offset:)`` when it shows again, and plays a
/// tapped row through ``CarPlayRootModel/play(_:in:of:)``.
///
/// The libraries and their categories come from the shared ``LibraryStore``, so they follow its
/// refreshes. Every other list is an ``ItemListModel`` created on first use and kept for the
/// model's life, so going back and forth doesn't reload it; lists of a library the store no longer
/// has are empty and dropped. Opening a library switches CarPlay's library and saves it as the
/// account's last-used one (``LibraryStore/saveLastLibraryID(_:)``, ADR 0004), which the
/// Continue tab follows. The Latest tab shows that library's newest episodes when it's a podcast
/// library, else the first podcast library's, and has no list without one (``latestLibraryID``).
///
/// A model belongs to one account: the delegate creates one per ``SessionIdentity`` and replaces
/// it when the account changes. While the store doesn't serve its account, every list is empty
/// and nothing loads.
@MainActor
@Observable
public final class CarPlayBrowseModel {
    /// The longest a list's model pages in one ``load(_:offset:)``, so a server sending pages
    /// that add nothing can't keep it loading.
    public static let maximumPagesPerLoad = 10

    public let identity: SessionIdentity
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let service: any CarPlayBrowseService
    @ObservationIgnored private let builder: CarPlayContentBuilder
    @ObservationIgnored private let pageSize: Int
    /// The models of the lists opened so far.
    private var sources: [CarPlayDestination: Source] = [:]
    /// The lists a page has arrived for, even one whose items were all left out (episodes that
    /// don't map, say): they've loaded, so a list that hasn't ended offers "More…".
    private var answered: Set<CarPlayDestination> = []
    /// The text of the row that opened a list, as its title.
    @ObservationIgnored private var titles: [CarPlayDestination: String] = [:]

    /// - Parameters:
    ///   - store: The shared library store, which serves `identity`'s account.
    ///   - service: The account's services (``LibraryStore/makeServices()``).
    ///   - limits: The car's list limits (``CarPlayLimits``).
    ///   - imageBucket: The width bucket of row images (``CarPlayContentBuilder/imageBucket``).
    ///   - pageSize: Items per page of a paged list.
    public init(
        store: LibraryStore, identity: SessionIdentity, service: any CarPlayBrowseService,
        limits: CarPlayLimits = .standard, labels: CarPlayLabels, imageBucket: ImageWidthBucket = .small,
        pageSize: Int = 50
    ) {
        self.store = store
        self.identity = identity
        self.service = service
        builder = CarPlayContentBuilder(
            limits: limits, labels: labels, serverID: identity.connectionID, imageBucket: imageBucket)
        self.pageSize = max(1, pageSize)
    }

    private var isServed: Bool { store.serves(identity) }

    /// Whether CarPlay's pushed lists stay open when the root model's load trigger changes to
    /// `identity`: while it's still this model's account, whatever the Continue tab shows. Its
    /// loading or failure after a library switch leaves browsing alone; a sign-out or an account
    /// switch closes it.
    public func keepsBrowsing(for identity: SessionIdentity?) -> Bool {
        identity != nil && identity == self.identity
    }

    // MARK: - Lists

    /// The library the Latest tab shows: CarPlay's library when it's a podcast library, else the
    /// account's first podcast library; `nil` without one, when the tab isn't shown.
    public var latestLibraryID: String? {
        guard isServed else { return nil }
        let libraries = store.libraries
        if let current = store.initialLibraryID,
            libraries.contains(where: { $0.id == current && $0.mediaType == .podcast })
        {
            return current
        }
        return libraries.first { $0.mediaType == .podcast }?.id
    }

    /// The page of `destination`'s list from `offset`, as loaded so far: empty until its first
    /// page arrives (so no "More…" row hides the loading or failure message), and for a library
    /// the store no longer has.
    public func list(_ destination: CarPlayDestination, offset: Int = 0) -> CarPlayList {
        let empty = CarPlayList(destination: destination, title: title(of: destination), sections: [])
        guard isServed else { return empty }
        switch destination {
        case .continueListening:
            return empty
        case .libraries:
            return builder.libraries(store.libraries, offset: offset)
        case .library(let id, _):
            guard let library = store.library(id: id) else { return empty }
            return builder.library(library, offset: offset)
        default:
            guard let libraryID = destination.libraryID, isKnown(libraryID), let source = sources[destination],
                status(destination) == .loaded
            else { return empty }
            switch (destination, source) {
            case (.series, .series(let model)):
                return builder.series(model.items, reachedEnd: model.reachedEnd, libraryID: libraryID, offset: offset)
            case (.authors, .authors(let model)):
                return builder.authors(
                    model.items, reachedEnd: model.reachedEnd, libraryID: libraryID, offset: offset)
            case (.latestEpisodes, .episodes(let model)):
                return builder.latestEpisodes(
                    model.items, reachedEnd: model.reachedEnd, libraryID: libraryID, offset: offset)
            case (_, .items(let model)):
                return builder.items(
                    model.items, reachedEnd: model.reachedEnd, in: destination, title: empty.title, offset: offset)
            case (_, .episodes(let model)):
                return builder.items(
                    model.items, reachedEnd: model.reachedEnd, in: destination, title: empty.title, offset: offset)
            default:
                return empty
            }
        }
    }

    /// Whether `destination`'s list has loaded, for the message an empty list shows.
    public func status(_ destination: CarPlayDestination) -> CarPlayBrowseStatus {
        switch destination {
        case .continueListening:
            return .loaded
        case .libraries, .library:
            if store.hasLoaded { return .loaded }
            return store.error == nil ? .loading : .failed
        default:
            guard let destinationLibrary = destination.libraryID, isKnown(destinationLibrary) else { return .loaded }
            guard let pager = sources[destination]?.pager else { return .loading }
            if pager.loadedCount > 0 || pager.reachedEnd || answered.contains(destination) { return .loaded }
            return pager.error == nil ? .loading : .failed
        }
    }

    /// Whether `row` is shown on the page of `destination`'s list from `offset`: by its ID, action
    /// and image, whatever its progress, and enabled. A tap from a page that has changed since is
    /// ignored.
    public func shows(_ row: CarPlayRow, in destination: CarPlayDestination, offset: Int) -> Bool {
        list(destination, offset: offset).rows.contains {
            $0.id == row.id && $0.action == row.action && $0.image == row.image && $0.isEnabled
        }
    }

    /// The offset to show `destination`'s list from after a refresh: `offset`, unless the loaded
    /// list got shorter and the page from it is empty, with no "More…" to leave it; then the
    /// first page.
    public func offset(of destination: CarPlayDestination, afterRefreshFrom offset: Int) -> Int {
        guard offset > 0, status(destination) == .loaded, list(destination, offset: offset).rows.isEmpty else {
            return offset
        }
        return 0
    }

    // MARK: - Navigation and loading

    /// The list a tapped row opens, to push, or `nil` when it opens none or is past the depth
    /// limit. Opening a library makes it CarPlay's library and the account's last-used one.
    public func open(_ row: CarPlayRow) -> CarPlayDestination? {
        guard isServed, case .open(let destination) = row.action, builder.canOpen(destination) else { return nil }
        titles[destination] = row.text
        if case .library(let id, _) = destination, store.lastLibraryID != id { store.saveLastLibraryID(id) }
        return destination
    }

    /// Loads `destination`'s list until it has the items for the page from `offset`
    /// (``CarPlayContentBuilder/rowsNeeded(offset:)``) or all of them, at most
    /// ``maximumPagesPerLoad`` pages, stopping at a failure. The libraries load with the store,
    /// once.
    public func load(_ destination: CarPlayDestination, offset: Int = 0) async {
        guard isServed else { return }
        switch destination {
        case .continueListening:
            return
        case .libraries, .library:
            if !store.hasLoaded { await store.refresh() }
            return
        default:
            break
        }
        dropRemovedLibraries()
        guard let pager = source(for: destination)?.pager else { return }
        let needed = builder.rowsNeeded(offset: offset)
        for _ in 0..<Self.maximumPagesPerLoad {
            guard pager.loadedCount < needed, !pager.reachedEnd, isServed, let page = pager.loadNextPage() else {
                return
            }
            await page.value
            if pager.error != nil { return }
            if sources[destination]?.pager === pager { answered.insert(destination) }
        }
    }

    /// Reloads `destination`'s list, for example when it shows again: the libraries reload with
    /// the store, which drops the lists of a removed library; another list reloads from its first
    /// page, keeping its rows until that page replaces them, then loads on to the page from
    /// `offset`.
    public func refresh(_ destination: CarPlayDestination, offset: Int = 0) async {
        guard isServed else { return }
        switch destination {
        case .continueListening:
            return
        case .libraries, .library:
            await store.refresh()
            dropRemovedLibraries()
            return
        default:
            break
        }
        if let pager = sources[destination]?.pager, pager.loadedCount > 0 || pager.reachedEnd {
            await pager.refresh()?.value
        }
        await load(destination, offset: offset)
    }

    // MARK: - Sources

    /// A list's model, by the items it holds.
    private enum Source {
        case items(ItemListModel<LibraryQuery, ItemSummary>)
        case episodes(ItemListModel<String, ItemSummary>)
        case series(ItemListModel<String, SeriesSummary>)
        case authors(ItemListModel<String, AuthorSummary>)

        var pager: any CarPlayPager {
            switch self {
            case .items(let model): model
            case .episodes(let model): model
            case .series(let model): model
            case .authors(let model): model
            }
        }
    }

    /// Whether the store has `libraryID`, or doesn't know its libraries yet.
    private func isKnown(_ libraryID: String) -> Bool {
        !store.hasLoaded || store.libraries.contains { $0.id == libraryID }
    }

    private func dropRemovedLibraries() {
        let removed = sources.keys.filter { $0.libraryID.map { !isKnown($0) } ?? false }
        for destination in removed {
            sources[destination] = nil
            answered.remove(destination)
        }
    }

    private func title(of destination: CarPlayDestination) -> String {
        let labels = builder.labels
        switch destination {
        case .continueListening: return labels.continueListening
        case .libraries: return labels.libraries
        case .library(let id, _): return store.library(id: id)?.name ?? titles[destination] ?? ""
        case .items(let id): return store.mediaType(libraryID: id) == .podcast ? labels.podcasts : labels.books
        case .series: return labels.series
        case .authors: return labels.authors
        case .latestEpisodes: return labels.latest
        case .seriesBooks, .authorBooks, .podcastEpisodes: return titles[destination] ?? ""
        }
    }

    /// `destination`'s model, created on first use.
    private func source(for destination: CarPlayDestination) -> Source? {
        if let source = sources[destination] { return source }
        guard let libraryID = destination.libraryID, isKnown(libraryID) else { return nil }
        let key = LibraryConnectionKey(connectionID: identity.connectionID, userID: identity.userID)
        let service = service
        let byTitle = "media.metadata.title"
        let source: Source
        switch destination {
        case .items:
            source = .items(books(LibraryQuery(sort: byTitle), libraryID: libraryID, key: key))
        case .seriesBooks(_, let seriesID):
            // No sort: the server's sequence order.
            source = .items(books(LibraryQuery(filter: .series(id: seriesID)), libraryID: libraryID, key: key))
        case .authorBooks(_, let authorID):
            source = .items(
                books(LibraryQuery(sort: byTitle, filter: .authors(id: authorID)), libraryID: libraryID, key: key))
        case .series:
            source = .series(
                .series(
                    service: service, libraryID: libraryID, pageSize: pageSize, prefetchThreshold: 0,
                    connectionKey: key))
        case .authors:
            // The endpoint isn't paged: one page holds every author.
            source = .authors(
                ItemListModel(query: libraryID, pageSize: 0, prefetchThreshold: 0, connectionKey: key) {
                    libraryID, page, limit in
                    let authors = try await service.authorList(libraryID: libraryID)
                    return PagedResults(
                        results: authors.map(AuthorSummary.init(author:)), total: authors.count, limit: limit,
                        page: page)
                })
        case .podcastEpisodes(_, let itemID):
            // The podcast's item holds every episode: one page, newest first.
            source = .episodes(
                ItemListModel(query: itemID, pageSize: 0, prefetchThreshold: 0, connectionKey: key) {
                    itemID, page, limit in
                    let item = try await service.item(id: itemID)
                    guard case .podcast(let podcast) = item.media else {
                        return PagedResults(results: [], total: 0, limit: limit, page: page)
                    }
                    let episodes = (podcast.episodes ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
                    return PagedResults(
                        results: episodes.map { ItemSummary(item: item, episode: $0) }, total: episodes.count,
                        limit: limit, page: page)
                })
        case .latestEpisodes:
            source = .episodes(
                ItemListModel(query: libraryID, pageSize: pageSize, prefetchThreshold: 0, connectionKey: key) {
                    libraryID, page, limit in
                    let response = try await service.recentEpisodes(libraryID: libraryID, page: page, limit: limit)
                    // Paging counts the server's rows, including episodes dropped here; the
                    // server sends no total, so a short page ends the list.
                    return PagedResults(
                        results: response.episodes.compactMap(LatestEpisode.init).map(\.summary), total: nil,
                        limit: response.limit, page: response.page, rawCount: response.rawCount)
                })
        case .continueListening, .libraries, .library:
            return nil
        }
        sources[destination] = source
        return source
    }

    private func books(
        _ query: LibraryQuery, libraryID: String, key: LibraryConnectionKey
    ) -> ItemListModel<LibraryQuery, ItemSummary> {
        .filteredBooks(
            service: service, libraryID: libraryID, query: query, pageSize: pageSize, prefetchThreshold: 0,
            connectionKey: key)
    }
}

/// What ``CarPlayBrowseModel`` needs of a list's ``ItemListModel``, whatever its items.
@MainActor
private protocol CarPlayPager: AnyObject {
    var loadedCount: Int { get }
    var reachedEnd: Bool { get }
    var error: (any Error)? { get }
    func loadNextPage() -> Task<Void, Never>?
    func refresh() -> Task<Void, Never>?
}

extension ItemListModel: CarPlayPager {
    fileprivate var loadedCount: Int { items.count }
}
