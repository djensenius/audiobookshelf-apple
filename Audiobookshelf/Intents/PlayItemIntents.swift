import ABSAppModel
import ABSData
import AppIntents
import Foundation

/// What the play-item intent and the entity queries ask of the app: the signed-in account's
/// ``PlayableEntityCatalog`` and its play action. ``PlaybackIntentHandler`` conforms; the app
/// registers it with ``PlayableEntityRouter``.
@MainActor
protocol PlayableEntityHandling: AnyObject {
    /// The signed-in account's catalog, once the session lifecycle has started; `nil` without a
    /// library store.
    func catalog() async -> PlayableEntityCatalog?
    /// Plays the book or episode `key` names.
    func play(_ key: MediaKey) async throws
}

/// Hands the entity queries and ``PlayBookIntent``/``PlayEpisodeIntent`` to the app. App-only:
/// unlike the playback intents, the widget extension doesn't declare them.
@MainActor
enum PlayableEntityRouter {
    /// Set by the app at launch.
    static var handler: (any PlayableEntityHandling)?

    static func requireHandler() throws -> any PlayableEntityHandling {
        guard let handler else { throw PlaybackIntentError.playerUnavailable }
        return handler
    }

    /// The records for `identifiers`; none without a handler or catalog.
    static func entities(for identifiers: [String]) async -> [PlayableEntityRecord] {
        await handler?.catalog()?.entities(for: identifiers) ?? []
    }

    /// The server search's records for `query`.
    static func search(_ query: String) async throws -> [PlayableEntityRecord] {
        try await handler?.catalog()?.search(query) ?? []
    }

    /// Continue Listening's records.
    static func suggestions() async throws -> [PlayableEntityRecord] {
        try await handler?.catalog()?.suggestions() ?? []
    }
}

// MARK: - Entities

/// A book on the signed-in account, for Siri and Shortcuts (#87). Its identifier is the book's
/// ``MediaKey`` (``PlayableEntityRecord/id``), so it can't name a book on another account.
@AppEntity(schema: .audio.audiobook)
struct BookEntity {
    static let defaultQuery = BookEntityQuery()

    let id: String
    var title: String?
    var author: String?
    var genre: String?
    var narrator: String?
    var publisher: String?
    var seriesTitle: String?
    var releaseDate: Date?
    var purchaseDate: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title ?? "")", subtitle: author.map { LocalizedStringResource(stringLiteral: $0) })
    }

    /// `nil` unless `record` is a book.
    init?(_ record: PlayableEntityRecord) {
        guard record.kind == .book else { return nil }
        id = record.id
        title = record.title
        author = record.subtitle
        seriesTitle = record.seriesText
    }
}

/// Finds books by identifier, by the server's search, and from Continue Listening.
struct BookEntityQuery: EntityStringQuery {
    func entities(for identifiers: [BookEntity.ID]) async throws -> [BookEntity] {
        await PlayableEntityRouter.entities(for: identifiers).compactMap(BookEntity.init)
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        try await PlayableEntityRouter.search(string).compactMap(BookEntity.init)
    }

    func suggestedEntities() async throws -> [BookEntity] {
        try await PlayableEntityRouter.suggestions().compactMap(BookEntity.init)
    }
}

/// A podcast episode on the signed-in account, for Siri and Shortcuts (#87). Its identifier is
/// the episode's ``MediaKey`` (``PlayableEntityRecord/id``).
///
/// A plain entity rather than `@AppEntity(schema: .audio.podcastEpisode)`: that schema requires a
/// `show` property of a podcast show entity, which the app doesn't have yet.
struct PodcastEpisodeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("IntentPodcastEpisodeEntity", table: "AppIntents"))
    static let defaultQuery = PodcastEpisodeEntityQuery()

    let id: String
    var title: String
    var showName: String?
    var releaseDate: Date?
    /// Seconds.
    var duration: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)", subtitle: showName.map { LocalizedStringResource(stringLiteral: $0) })
    }

    /// `nil` unless `record` is an episode.
    init?(_ record: PlayableEntityRecord) {
        guard record.kind == .episode else { return nil }
        id = record.id
        title = record.title
        showName = record.subtitle
        duration = record.duration
    }
}

/// Finds episodes by identifier, by the server's search, and from Continue Listening.
struct PodcastEpisodeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [PodcastEpisodeEntity.ID]) async throws -> [PodcastEpisodeEntity] {
        await PlayableEntityRouter.entities(for: identifiers).compactMap(PodcastEpisodeEntity.init)
    }

    func entities(matching string: String) async throws -> [PodcastEpisodeEntity] {
        try await PlayableEntityRouter.search(string).compactMap(PodcastEpisodeEntity.init)
    }

    func suggestedEntities() async throws -> [PodcastEpisodeEntity] {
        try await PlayableEntityRouter.suggestions().compactMap(PodcastEpisodeEntity.init)
    }
}

// MARK: - Intents

// Plain intents rather than `@AppIntent(schema: .audio.playAudio)`: that schema takes one
// `@UnionValue` of every audio entity plus shuffle/repeat attributes, a queue position and a
// warm-up result, which this player can't honour. Each is an ``AudioPlaybackIntent``, so it runs
// in the app process.

/// Plays a book from its saved progress.
struct PlayBookIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentPlayBookTitle", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("IntentPlayBookDescription", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("IntentPlayBookParameter", table: "AppIntents"))
    var book: BookEntity

    init() {}

    init(book: BookEntity) {
        self.book = book
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlayableEntityRouter.play(id: book.id)
        return .result()
    }
}

/// Plays a podcast episode from its saved progress.
struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentPlayEpisodeTitle", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("IntentPlayEpisodeDescription", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("IntentPlayEpisodeParameter", table: "AppIntents"))
    var episode: PodcastEpisodeEntity

    init() {}

    init(episode: PodcastEpisodeEntity) {
        self.episode = episode
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlayableEntityRouter.play(id: episode.id)
        return .result()
    }
}

extension PlayableEntityRouter {
    /// Plays the entity identifier's item; ``PlaybackIntentError/itemUnavailable`` when it isn't
    /// a ``MediaKey``.
    static func play(id: String) async throws {
        let handler = try requireHandler()
        guard let key = MediaKey(rawValue: id) else { throw PlaybackIntentError.itemUnavailable }
        try await handler.play(key)
    }
}
