import ABSAPI
import ABSCore
import Foundation

@testable import ABSAppModel

/// A ``GroupsService`` whose responses come from closures.
struct FakeGroupsService: GroupsService {
    var collectionsHandler: @Sendable (String, Int, Int) async throws -> PagedResults<LibraryCollection> = {
        _, _, _ in PagedResults(results: [], total: 0, limit: 0, page: 0)
    }
    var playlistsHandler: @Sendable (String, Int, Int) async throws -> PagedResults<Playlist> = { _, _, _ in
        PagedResults(results: [], total: 0, limit: 0, page: 0)
    }
    var collectionHandler: @Sendable (String) async throws -> LibraryCollection = { _ in throw TestError.unexpected }
    var playlistHandler: @Sendable (String) async throws -> Playlist = { _ in throw TestError.unexpected }

    func collectionsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<LibraryCollection> {
        try await collectionsHandler(libraryID, page, limit)
    }

    func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist> {
        try await playlistsHandler(libraryID, page, limit)
    }

    func collectionDetail(id: String) async throws -> LibraryCollection { try await collectionHandler(id) }
    func playlistDetail(id: String) async throws -> Playlist { try await playlistHandler(id) }
}

/// Builders for the group tests.
enum GroupFixtures {
    /// An expanded book; `tracks` audio tracks, and a cover at `cover` unless `nil`.
    static func book(
        _ id: String, tracks: Int = 1, isMissing: Bool = false, isInvalid: Bool = false,
        cover: String? = "/covers/x.jpg"
    ) -> LibraryItem {
        LibraryItem(
            id: id, libraryId: "lib", updatedAt: 1, isMissing: isMissing, isInvalid: isInvalid, mediaType: .book,
            media: .book(
                Book(
                    id: "book-\(id)", metadata: BookMetadata(title: "Title \(id)"), coverPath: cover,
                    tracks: (0..<tracks).map { _ in AudioTrack(duration: 60) })))
    }

    /// A podcast, with a cover.
    static func podcast(_ id: String, isMissing: Bool = false) -> LibraryItem {
        LibraryItem(
            id: id, libraryId: "lib", updatedAt: 1, isMissing: isMissing, mediaType: .podcast,
            media: .podcast(
                Podcast(id: "pod-\(id)", metadata: PodcastMetadata(title: "Show \(id)"), coverPath: "/c.jpg")))
    }

    /// An episode, with an audio file unless `hasAudio` is false.
    static func episode(_ id: String, hasAudio: Bool = true) -> PodcastEpisode {
        PodcastEpisode(id: id, title: "Episode \(id)", audioFile: hasAudio ? AudioFile(ino: "ino-\(id)") : nil)
    }

    static func collection(_ id: String, name: String? = nil, description: String? = nil, books: [LibraryItem])
        -> LibraryCollection
    {
        LibraryCollection(id: id, libraryId: "lib", name: name ?? id, description: description, books: books)
    }

    static func playlist(_ id: String, name: String? = nil, items: [PlaylistItem]) -> Playlist {
        Playlist(id: id, libraryId: "lib", name: name ?? id, items: items)
    }

    static func bookEntry(_ item: LibraryItem) -> PlaylistItem {
        PlaylistItem(libraryItemId: item.id, libraryItem: item)
    }

    static func episodeEntry(_ podcast: LibraryItem, _ episode: PodcastEpisode) -> PlaylistItem {
        PlaylistItem(libraryItemId: podcast.id, episodeId: episode.id, episode: episode, libraryItem: podcast)
    }

    /// `isFinished` progress on `target`, stamped `lastUpdate` so later stamps replace it.
    static func progress(_ target: GroupPlayTarget, finished: Bool, at lastUpdate: Int) -> MediaProgress {
        MediaProgress(
            id: "mp-\(target.progressKey)", libraryItemId: target.itemID, episodeId: target.episodeID,
            isFinished: finished, lastUpdate: lastUpdate)
    }
}
