import ABSCore
import Foundation
import Observation

/// The book detail screen: one library item from `GET /api/items/:id`, the user's progress on
/// it from ``ProgressCache``, and what the screen shows and enables. A port of the rules in the
/// legacy `pages/item/_id/index.vue`; the view (#293) only lays it out.
///
/// - Loading keeps the last item while reloading and after a failed reload, like ``StatsModel``.
///   When loads overlap, only the last one started is applied.
/// - Progress is read from the cache on every access, so a view reading ``progressFraction``,
///   ``timeRemaining`` or ``playButton`` invalidates when that item's (or episode's) cache entry
///   changes, and not for other items.
/// - Podcasts are out of scope: the view routes on ``mediaType`` to `PodcastDetailView` (#68).
///
/// A model belongs to one item, client and account; views recreate it when any changes (for
/// example `.task(id:)` on the item ID).
@MainActor
@Observable
public final class ItemDetailModel {
    /// The primary button. Legacy only had Play (`index.vue:54-57`); Resume and Play again
    /// follow the user's audio progress.
    public enum PlayButton: Sendable, Hashable {
        /// Not started.
        case play
        /// Some audio progress, not finished.
        case resume
        /// Finished; playing starts over.
        case playAgain
        /// Nothing to play: the item has no audio tracks or no duration, is missing or invalid
        /// on the server, or isn't a book. The view shows a disabled Play.
        case unavailable
    }

    /// A series the book belongs to, for a link to the series page.
    public struct SeriesEntry: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let sequence: String?

        /// `Name #sequence`, or the name alone without a sequence (`index.vue:350-360`).
        public var text: String {
            guard let sequence else { return name }
            return "\(name) #\(sequence)"
        }
    }

    /// The book's display values from ``BookMetadata`` and its media. Empty lists and blank
    /// strings are normalized to empty and `nil`, so the view hides those rows.
    public struct Details: Sendable, Hashable {
        public let title: String
        public let subtitle: String?
        public let authors: [Author]
        public let narrators: [String]
        public let series: [SeriesEntry]
        public let genres: [String]
        /// The media's tags (`media.tags`, not metadata).
        public let tags: [String]
        public let publisher: String?
        /// `publishedYear`.
        public let year: String?
        public let language: String?
        /// The HTML description, as the server sends it.
        public let description: String?
        /// Seconds; `nil` unless positive.
        public let duration: TimeInterval?
        /// Bytes; the item's size, else the media's.
        public let size: Int?
        public let isExplicit: Bool
        public let isAbridged: Bool
    }

    public let itemID: String
    /// The episode whose progress is read; `nil` for a book.
    public let episodeID: String?

    /// The last loaded item; kept while reloading and after a failed reload.
    public private(set) var item: LibraryItem?
    /// The book's display values; `nil` until loaded, and for items that aren't books.
    public private(set) var details: Details?
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?

    @ObservationIgnored private let service: any ItemDetailService
    @ObservationIgnored private let cache: ProgressCache
    @ObservationIgnored private var sequence = 0

    public init(itemID: String, episodeID: String? = nil, service: any ItemDetailService, cache: ProgressCache) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.service = service
        self.cache = cache
    }

    // MARK: Loading

    /// The item has been loaded at least once.
    public var hasLoaded: Bool { item != nil }

    /// A reload failed while the earlier item is still shown, so the page keeps it and offers a
    /// retry.
    public var refreshFailed: Bool { hasLoaded && error != nil && !isLoading }

    /// Loads unless the item has already loaded. Views call it each time they appear, so a load
    /// cancelled before it finished (the view disappeared) runs again.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Loads the item. A response to an older call that arrives after a newer one started is
    /// dropped, so a late reply never replaces fresher data or clears a newer error.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<LibraryItem, any Error>
        do {
            result = .success(try await service.item(id: itemID))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let loaded):
            item = loaded
            details = loaded.book.map { Self.details(item: loaded, book: $0) }
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }

    // MARK: Item

    /// `nil` until loaded. Podcasts route to their own screen (#68).
    public var mediaType: MediaType? { item?.mediaType }

    /// The slim value cells and playback take (cover, title, play target); `nil` until loaded.
    public var summary: ItemSummary? { item.map { ItemSummary(item: $0) } }

    /// Missing on the server; legacy shows a Missing button instead of Play (`index.vue:69-72`).
    public var isMissing: Bool { item?.isMissing ?? false }

    // MARK: Progress

    /// The user's progress from the cache. Reading it registers observation of this key only.
    public var progress: MediaProgress? {
        cache.progress(libraryItemID: itemID, episodeID: episodeID)
    }

    /// `0...1`: the audio progress, or the ebook progress when there's no audio progress
    /// (`index.vue:388-395`); `1` when finished, as on cells (``ItemProgress``).
    public var progressFraction: Double {
        progress.map { ItemProgress($0).fraction } ?? 0
    }

    public var isFinished: Bool { progress?.isFinished ?? false }

    /// When the user finished the item, if they did and the server recorded it (`index.vue:77`).
    public var finishedAt: Date? {
        guard let progress, progress.isFinished, let finishedAt = progress.finishedAt, finishedAt > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(finishedAt) / 1000)
    }

    /// Seconds of audio left, shown only for audio progress that isn't finished
    /// (`index.vue:74-76`): the progress's duration, else the media's, minus the current time
    /// (`index.vue:383-387`), never negative. `nil` otherwise.
    public var timeRemaining: TimeInterval? {
        guard let progress, !progress.isFinished, progress.progress > 0 else { return nil }
        let duration = progress.duration > 0 ? progress.duration : (details?.duration ?? 0)
        let remaining = duration - progress.currentTime
        guard remaining.isFinite else { return nil }
        return max(remaining, 0)
    }

    // MARK: Actions

    /// The primary button for the current item and progress.
    public var playButton: PlayButton {
        guard hasAudio else { return .unavailable }
        guard let progress else { return .play }
        if progress.isFinished { return .playAgain }
        if progress.progress > 0 || progress.currentTime > 0 { return .resume }
        return .play
    }

    /// The book has audio it can play: not missing or invalid, with tracks and a positive
    /// duration (`index.vue:445-447`).
    public var hasAudio: Bool {
        guard let item, !item.isMissing, !item.isInvalid, item.book != nil, let summary else { return false }
        return summary.hasAudio && details?.duration != nil
    }

    /// The book has an ebook, so the view shows Read (`index.vue:448-450`).
    public var hasEbook: Bool { ebookFormat != nil || item?.book?.ebookFile != nil }

    /// The ebook's format, for the Read label (`index.vue:464-467`).
    public var ebookFormat: EbookFormat? {
        guard let book = item?.book else { return nil }
        return book.ebookFile?.ebookFormat ?? book.ebookFormat
    }

    /// Read is shown when ``hasEbook`` but stays disabled until the ebook readers exist.
    public var isReadEnabled: Bool { false }

    /// Placeholder for the Download button (legacy `index.vue:451-454`, `613-694`): `false`
    /// until downloads exist, so the view hides the button.
    public var isDownloadAvailable: Bool { false }

    /// Placeholder hook for the Download button; does nothing until downloads exist.
    public func download() {}

    // MARK: Mapping

    static func details(item: LibraryItem, book: Book) -> Details {
        let metadata = book.metadata
        let trackDuration = book.tracks?.reduce(0) { $0 + $1.duration }
        return Details(
            title: metadata.title,
            subtitle: nonEmpty(metadata.subtitle),
            authors: metadata.authors ?? [],
            narrators: (metadata.narrators ?? []).filter { !$0.isEmpty },
            series: (metadata.series ?? []).map {
                SeriesEntry(id: $0.id, name: $0.name, sequence: nonEmpty($0.sequence))
            },
            genres: (metadata.genres ?? []).filter { !$0.isEmpty },
            tags: (book.tags ?? []).filter { !$0.isEmpty },
            publisher: nonEmpty(metadata.publisher),
            year: nonEmpty(metadata.publishedYear),
            language: nonEmpty(metadata.language),
            description: nonEmpty(metadata.description),
            duration: positive(book.duration ?? trackDuration),
            size: item.size ?? book.size,
            isExplicit: metadata.explicit ?? false,
            isAbridged: metadata.abridged ?? false)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func positive(_ seconds: Double?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
