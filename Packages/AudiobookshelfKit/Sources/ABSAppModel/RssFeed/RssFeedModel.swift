import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Observation

/// Opens and closes RSS feeds; `APIClient` conforms. Every request needs an admin or root user.
public protocol RssFeedService: ServerURLProviding {
    /// The feed open for `target`, or `nil`.
    func currentFeed(for target: RssFeedTarget) async throws -> RssFeed?
    func openFeed(for target: RssFeedTarget, _ request: RssFeedOpenRequest) async throws -> RssFeed
    func closeFeed(id: String) async throws
}

extension APIClient: RssFeedService {
    public func currentFeed(for target: RssFeedTarget) async throws -> RssFeed? {
        try await send(FeedEndpoints.current(target)).rssFeed
    }

    public func openFeed(for target: RssFeedTarget, _ request: RssFeedOpenRequest) async throws -> RssFeed {
        try await send(FeedEndpoints.open(target, request)).feed
    }

    public func closeFeed(id: String) async throws {
        _ = try await send(FeedEndpoints.close(id: id))
    }
}

/// Why ``RssFeedModel`` couldn't do something.
public enum RssFeedModelError: Error, Sendable, Hashable {
    /// The slug is empty.
    case slugRequired
    /// The slug had characters a feed address can't use; ``RssFeedModel/slug`` now holds the cleaned
    /// one, to check before opening again (legacy "Slug had to be modified - Run again").
    case slugChanged
    /// The owner email isn't an address.
    case invalidOwnerEmail
    /// The current feed couldn't be fetched.
    case loadFailed
    /// The server refused to open the feed; `message` is its plain-text reason, such as
    /// "Slug already in use".
    case openFailed(message: String?)
    case closeFailed
}

/// The RSS feed of one item, collection or series (legacy `RssFeedModal.vue`): shows the open feed,
/// or opens one with a slug and the owner details, and closes it. Only admins and root users can
/// manage feeds (``canManageFeeds(_:)``); the server refuses everyone else.
///
/// ``load()`` fetches the current feed and the server address. ``open()`` validates the fields
/// first and ``close()`` needs an open feed; while either runs, both return `false`. ``apply(_:)``
/// follows live `rss_feed_open` and `rss_feed_closed` events (``RealtimeBridge/onRssFeedChange``)
/// for this entity; a load that started before one doesn't overwrite it.
@MainActor
@Observable
public final class RssFeedModel {
    public enum LoadState: Sendable, Hashable {
        case idle, loading, loaded, failed
    }

    public let target: RssFeedTarget
    /// A podcast with episodes that have no publication date, which some podcast apps need
    /// (legacy `NoteRSSFeedPodcastAppsPubDate`).
    public let hasEpisodesWithoutPubDate: Bool
    public private(set) var loadState: LoadState = .idle
    /// The open feed, or `nil` when none is.
    public private(set) var feed: RssFeed?
    /// The address the client connects to, which new feeds' links are built on; set by ``load()``.
    public private(set) var serverURL: URL?
    /// Defaults to the entity's ID, as in legacy.
    public var slug: String
    public var preventIndexing = true
    public var ownerName = ""
    public var ownerEmail = ""
    /// Opening or closing.
    public private(set) var isWorking = false
    /// The last failure, cleared when the next open or close starts.
    public private(set) var error: RssFeedModelError? {
        didSet { if error != nil { failureCount += 1 } }
    }
    /// Counts failures, so a view can announce one that repeats the last ``error``.
    public private(set) var failureCount = 0

    @ObservationIgnored private let service: any RssFeedService
    /// Bumped by each live change, so a load that started earlier keeps the newer state.
    @ObservationIgnored private var changeGeneration = 0

    public init(target: RssFeedTarget, service: any RssFeedService, hasEpisodesWithoutPubDate: Bool = false) {
        self.target = target
        self.service = service
        self.hasEpisodesWithoutPubDate = hasEpisodesWithoutPubDate
        slug = target.id
    }

    /// Whether a user of this type can open and close feeds (server `isAdminOrUp`). `nil`, such as
    /// offline, can't.
    public nonisolated static func canManageFeeds(_ type: UserType?) -> Bool {
        type == .admin || type == .root
    }

    /// The open feed's address.
    public var feedURL: URL? {
        guard let feed, let serverURL else { return nil }
        return feed.url(on: serverURL)
    }

    /// What the new feed's address will be (legacy `MessageFeedURLWillBe`), from the cleaned slug.
    public var previewURL: String? {
        guard let serverURL else { return nil }
        return Self.serverAddress(serverURL) + "/feed/" + Self.sanitizeSlug(slug)
    }

    /// The server is plain `http`, which most podcast apps refuse.
    public var isInsecureServer: Bool {
        serverURL?.scheme?.lowercased() == "http"
    }

    /// Fetches the current feed and the server address. A failure keeps the last loaded feed; a success
    /// clears an earlier load failure.
    public func load() async {
        loadState = .loading
        let generation = changeGeneration
        serverURL = await service.serverURL()
        do {
            let current = try await service.currentFeed(for: target)
            if generation == changeGeneration { feed = current }
            loadState = .loaded
            if error == .loadFailed { error = nil }
        } catch {
            loadState = .failed
            if !(error is CancellationError) { self.error = .loadFailed }
        }
    }

    /// Validates the fields and opens the feed; `true` when it opened. Trims the owner fields.
    @discardableResult
    public func open() async -> Bool {
        guard !isWorking, feed == nil else { return false }
        if let failure = validate() {
            error = failure
            return false
        }
        isWorking = true
        defer { isWorking = false }
        error = nil
        let serverURL = await service.serverURL()
        self.serverURL = serverURL
        let request = RssFeedOpenRequest(
            serverAddress: Self.serverAddress(serverURL), slug: slug,
            metadataDetails: .init(preventIndexing: preventIndexing, ownerName: ownerName, ownerEmail: ownerEmail))
        do {
            feed = try await service.openFeed(for: target, request)
            return true
        } catch {
            self.error = .openFailed(message: Self.serverMessage(error))
            return false
        }
    }

    /// Closes the open feed; `true` when it closed. A feed the server no longer has (404), for example
    /// closed elsewhere, counts as closed.
    @discardableResult
    public func close() async -> Bool {
        guard !isWorking, let feed else { return false }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await service.closeFeed(id: feed.id)
            self.feed = nil
            return true
        } catch APIError.notFound {
            self.feed = nil
            return true
        } catch {
            self.error = .closeFailed
            return false
        }
    }

    /// Follows a live open or close of this entity's feed (legacy item page `rssFeedOpen` and
    /// `rssFeedClosed`); other entities' changes are ignored, as is the close of a feed other than
    /// the one shown.
    public func apply(_ change: RssFeedChange) {
        let changed = change.feed
        guard changed.entityId == target.id, changed.entityType == Self.entityType(target.kind) else { return }
        switch change {
        case .opened:
            feed = changed
        case .closed:
            guard feed == nil || feed?.id == changed.id else { return }
            feed = nil
        }
        changeGeneration += 1
    }

    /// The server's `entityType` for a target kind.
    nonisolated static func entityType(_ kind: RssFeedTarget.Kind) -> String {
        switch kind {
        case .item: "libraryItem"
        case .collection: "collection"
        case .series: "series"
        }
    }

    /// Legacy's checks (a slug is set and doesn't need cleaning) plus the owner email's shape. Trims
    /// the owner fields, and replaces a slug that needs cleaning with the cleaned one.
    func validate() -> RssFeedModelError? {
        ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        ownerEmail = ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty { return .slugRequired }
        let sanitized = Self.sanitizeSlug(slug)
        if sanitized != slug {
            slug = sanitized
            return sanitized.isEmpty ? .slugRequired : .slugChanged
        }
        if !ownerEmail.isEmpty, !Self.looksLikeEmail(ownerEmail) { return .invalidOwnerEmail }
        return nil
    }

    /// Legacy `$sanitizeSlug`: trims, lowercases, folds the accents it lists, turns `·/,:;`, dots
    /// and whitespace into dashes, and keeps only `a-z`, `0-9`, `_` and single dashes. Legacy also
    /// keeps characters such as `?` and `#` and replaces only the first dot; this always gives one
    /// safe path segment.
    public nonisolated static func sanitizeSlug(_ value: String) -> String {
        let folded = Dictionary(
            uniqueKeysWithValues: zip(
                "àáäâèéëêìíïîòóöôùúüûñçěščřžýůďťň·/,:;.", "aaaaeeeeiiiioooouuuuncescrzyudtn------"))
        var result = ""
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            let character = folded[character] ?? character
            if character.isWhitespace || character == "-" {
                if !result.hasSuffix("-") { result.append("-") }
            } else if character == "_" || (character.isASCII && (character.isLetter || character.isNumber)) {
                result.append(character)
            }
        }
        return result
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    private static func serverAddress(_ url: URL) -> String {
        var address = url.absoluteString
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    private static func serverMessage(_ error: any Error) -> String? {
        let message: String? =
            switch error as? APIError {
            case .http(_, let message), .forbidden(let message): message
            default: nil
            }
        return message.flatMap { $0.isEmpty ? nil : $0 }
    }
}
