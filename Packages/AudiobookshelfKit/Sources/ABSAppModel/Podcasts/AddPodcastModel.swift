import ABSAPI
import ABSCore
import Foundation
import Observation

/// The endpoints adding a podcast uses. `APIClient` conforms; tests use fakes.
public protocol AddPodcastService: Sendable {
    /// `GET /api/search/podcast`: the iTunes directory's podcasts matching `term`.
    func searchPodcastDirectory(term: String, country: String?) async throws -> [PodcastDirectoryResult]
    /// `POST /api/podcasts/feed`: the server's parse of the RSS feed at `rssFeed`.
    func podcastFeed(rssFeed: String) async throws -> PodcastFeed
    /// `POST /api/podcasts`: the new podcast's library item.
    func createPodcast(_ request: NewPodcastRequest) async throws -> LibraryItem
}

extension APIClient: AddPodcastService {
    public func searchPodcastDirectory(term: String, country: String?) async throws -> [PodcastDirectoryResult] {
        try await send(PodcastEndpoints.searchDirectory(term: term, country: country))
    }

    public func podcastFeed(rssFeed: String) async throws -> PodcastFeed {
        try await send(PodcastEndpoints.feed(rssFeed: rssFeed)).podcast
    }

    public func createPodcast(_ request: NewPodcastRequest) async throws -> LibraryItem {
        try await send(PodcastEndpoints.create(request))
    }
}

extension User {
    /// Whether the user may add podcasts: admins and root only. The server's `PodcastController` refuses everyone
    /// else's feed lookups and creates with 403, even with upload permission, and legacy `BookshelfNavBar.vue` shows
    /// Add only to `getIsAdminOrUp`.
    public var canAddPodcasts: Bool {
        type == .admin || type == .root
    }
}

/// Why looking up a podcast's feed failed.
public enum AddPodcastLookupError: Error, Sendable, Equatable {
    /// The directory entry has no RSS feed, so it can't be added (legacy "Invalid podcast - no feed").
    case noFeed
    /// The server couldn't fetch or parse the feed, or refused the request.
    case feedFailed
}

/// The Add podcast screen (legacy `pages/bookshelf/add-podcast.vue`) for one library and account: search the iTunes
/// directory, or look up a pasted RSS feed URL, then fill a ``NewPodcastDraft``.
///
/// Like legacy, ``submit()`` reads the field: text starting with `http:` or `https:` is looked up as a feed, anything
/// else searched for. Searching happens only on submit, not while typing. Each submit or ``select(_:)`` supersedes
/// the request before it: that request is cancelled, and its response is dropped if it still arrives, so results
/// or a form never show for an earlier query.
@MainActor
@Observable
public final class AddPodcastModel {
    /// The text as typed.
    public var query = ""
    /// The directory's podcasts for ``searchedTerm``.
    public private(set) var results: [PodcastDirectoryResult] = []
    /// The term ``results`` belong to; `nil` before a search, or after a feed lookup replaced them.
    public private(set) var searchedTerm: String?
    /// A search or feed lookup is running.
    public private(set) var isSearching = false
    public private(set) var isLookingUpFeed = false
    /// The last search failed; the previous ``results`` are cleared.
    public private(set) var searchError: (any Error)?
    /// The last feed lookup failed.
    public private(set) var lookupError: AddPodcastLookupError?
    /// The form for the feed just looked up; the view presents it and sets this to `nil` when dismissed.
    public var draft: NewPodcastDraft?

    public let libraryID: String
    /// The library's folders; the form picks one.
    public let folders: [LibraryFolder]

    /// The running search or lookup. Tests await it.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private let service: any AddPodcastService
    @ObservationIgnored private let country: String?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - library: The library the podcast is added to; its folders and `podcastSearchRegion` are used.
    public init(service: any AddPodcastService, library: Library) {
        self.service = service
        libraryID = library.id
        folders = library.folders ?? []
        country = library.settings?.podcastSearchRegion
    }

    isolated deinit {
        task?.cancel()
    }

    /// Whether `text` is looked up as a feed rather than searched for (legacy: it starts with `http:` or `https:`).
    public nonisolated static func isFeedURL(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("http:") || lowered.hasPrefix("https:")
    }

    /// Searches for ``query``, or looks it up when it's a feed URL. A blank query does nothing.
    public func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if Self.isFeedURL(text) {
            results = []
            searchedTerm = nil
            searchError = nil
            lookUpFeed(text, directory: nil)
        } else {
            search(text)
        }
    }

    /// Looks up the feed of a directory entry; an entry without one sets ``lookupError`` to `.noFeed`.
    public func select(_ result: PodcastDirectoryResult) {
        guard let feedURL = result.feedURL?.trimmingCharacters(in: .whitespacesAndNewlines), !feedURL.isEmpty else {
            supersede()
            lookupError = .noFeed
            return
        }
        lookUpFeed(feedURL, directory: result)
    }

    /// Clears ``lookupError`` once the view has shown it.
    public func clearLookupError() {
        lookupError = nil
    }

    /// Cancels the running request and returns the generation the next one belongs to.
    @discardableResult
    private func supersede() -> Int {
        task?.cancel()
        task = nil
        generation += 1
        isSearching = false
        isLookingUpFeed = false
        lookupError = nil
        return generation
    }

    private func search(_ term: String) {
        let generation = supersede()
        isSearching = true
        let (service, country) = (service, country)
        task = Task { [weak self] in
            let result: Result<[PodcastDirectoryResult], any Error>
            do {
                result = .success(try await service.searchPodcastDirectory(term: term, country: country))
            } catch {
                result = .failure(error)
            }
            self?.applySearch(result, term: term, generation: generation)
        }
    }

    private func applySearch(_ result: Result<[PodcastDirectoryResult], any Error>, term: String, generation: Int) {
        guard generation == self.generation else { return }
        isSearching = false
        switch result {
        case .success(let results):
            self.results = results
            searchedTerm = term
            searchError = nil
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            results = []
            searchedTerm = nil
            searchError = error
        }
    }

    private func lookUpFeed(_ url: String, directory: PodcastDirectoryResult?) {
        let generation = supersede()
        isLookingUpFeed = true
        let service = service
        task = Task { [weak self] in
            let result: Result<PodcastFeed, any Error>
            do {
                result = .success(try await service.podcastFeed(rssFeed: url))
            } catch {
                result = .failure(error)
            }
            self?.applyFeed(result, url: url, directory: directory, generation: generation)
        }
    }

    private func applyFeed(
        _ result: Result<PodcastFeed, any Error>, url: String, directory: PodcastDirectoryResult?, generation: Int
    ) {
        guard generation == self.generation else { return }
        isLookingUpFeed = false
        switch result {
        case .success(let feed):
            draft = NewPodcastDraft(
                service: service, libraryID: libraryID, folders: folders, feed: feed, directory: directory,
                feedURL: url)
        case .failure(let error):
            if !(error is CancellationError) { lookupError = .feedFailed }
        }
    }
}
