import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A recorded playlist write: the playlist ID (or new name) and the entries sent.
private struct PlaylistWrite: Sendable, Equatable {
    let id: String
    let entries: [PlaylistEntryKey]
}

/// A ``PlaylistEditingService`` whose responses come from closures.
private struct FakePlaylistEditingService: PlaylistEditingService {
    var list: @Sendable (String) async throws -> [Playlist] = { _ in [] }
    var create: @Sendable (PlaylistWrite) async throws -> Playlist = { _ in throw TestError.unexpected }
    var add: @Sendable (PlaylistWrite) async throws -> Playlist = { _ in throw TestError.unexpected }
    var remove: @Sendable (PlaylistWrite) async throws -> Playlist = { _ in throw TestError.unexpected }

    func allPlaylists(libraryID: String) async throws -> [Playlist] { try await list(libraryID) }
    func createPlaylist(name: String, libraryID: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await create(PlaylistWrite(id: "\(libraryID)/\(name)", entries: items.map(\.key)))
    }
    func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await add(PlaylistWrite(id: id, entries: items.map(\.key)))
    }
    func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await remove(PlaylistWrite(id: id, entries: items.map(\.key)))
    }
    func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist {
        throw TestError.unexpected
    }
    func deletePlaylist(id: String) async throws { throw TestError.unexpected }
}

extension PlaylistItemReference {
    fileprivate var key: PlaylistEntryKey { PlaylistEntryKey(itemID: libraryItemID, episodeID: episodeID) }
}

private let book1 = PlaylistEntryKey(itemID: "b1")
private let book2 = PlaylistEntryKey(itemID: "b2")
private let episode1 = PlaylistEntryKey(itemID: "pod", episodeID: "e1")
private let episode2 = PlaylistEntryKey(itemID: "pod", episodeID: "e2")

private func playlist(_ id: String, _ entries: [PlaylistEntryKey]) -> Playlist {
    Playlist(
        id: id, libraryId: "lib", name: "Name \(id)",
        items: entries.map { PlaylistItem(libraryItemId: $0.itemID, episodeId: $0.episodeID) })
}

@MainActor
private func loadedModel(
    _ entries: [PlaylistEntryKey], playlists: [Playlist], service: FakePlaylistEditingService = .init()
) async -> AddToPlaylistModel {
    var service = service
    service.list = { _ in playlists }
    let model = AddToPlaylistModel(entries: entries, libraryID: "lib", service: service)
    await model.load()
    return model
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AddToPlaylistModelTests {
    @Test func checksOnlyPlaylistsWithEveryEntryAndListsThemFirst() async {
        let model = await loadedModel(
            [book1, book2, book1],
            playlists: [playlist("some", [book1]), playlist("none", []), playlist("all", [book2, book1])])
        #expect(model.entries == [book1, book2])
        #expect(model.rows.map(\.id) == ["all", "some", "none"])
        #expect(model.rows.map(\.isChecked) == [true, false, false])
        #expect(model.rows.map(\.itemCount) == [2, 1, 0])
        #expect(model.hasLoaded)
    }

    @Test func episodesMatchOnlyTheSameEpisode() async {
        let model = await loadedModel(
            [episode1],
            playlists: [
                playlist("other", [episode2]), playlist("podcastOnly", [PlaylistEntryKey(itemID: "pod")]),
                playlist("same", [episode1]),
            ])
        #expect(model.rows.filter(\.isChecked).map(\.id) == ["same"])
    }

    @Test func noEntriesChecksNothingAndNeverWrites() async {
        let model = await loadedModel([], playlists: [playlist("p", [])])
        #expect(model.rows.map(\.isChecked) == [false])
        await model.toggle(playlistID: "p")
        #expect(await model.create(name: "New") == false)
        #expect(model.failure == nil)
    }

    @Test func toggleAddsMissingEntriesOptimistically() async throws {
        let gate = GatedCalls<PlaylistWrite, Playlist>()
        let model = await loadedModel(
            [book1, episode1], playlists: [playlist("p", [book1])],
            // A wrong removal reaches the gate too, so it fails the request check instead of hanging.
            service: FakePlaylistEditingService(add: { try await gate.call($0) }, remove: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()
        let task = Task { await model.toggle(playlistID: "p") }
        let call = try #require(await calls.next())
        #expect(call.request == PlaylistWrite(id: "p", entries: [episode1]))
        #expect(model.rows.first?.isChecked == true)
        #expect(model.rows.first?.isUpdating == true)
        call.reply.resume(
            returning: Playlist(id: "p", libraryId: "lib", name: "Renamed", items: []).with([book1, episode1]))
        await task.value
        #expect(model.rows.first?.name == "Renamed")
        #expect(model.rows.first?.isChecked == true)
        #expect(model.rows.first?.isUpdating == false)
        #expect(model.failure == nil)
    }

    @Test func toggleRemovesEveryEntryFromACheckedPlaylist() async {
        let writes = Locked<[PlaylistWrite]>([])
        let model = await loadedModel(
            [book1, episode1], playlists: [playlist("p", [book2, episode1, book1])],
            service: FakePlaylistEditingService(remove: { write in
                writes.value.append(write)
                return playlist("p", [book2])
            }))
        await model.toggle(playlistID: "p")
        #expect(writes.value == [PlaylistWrite(id: "p", entries: [book1, episode1])])
        #expect(model.rows.map(\.isChecked) == [false])
        #expect(model.rows.map(\.itemCount) == [1])
    }

    @Test func removingTheLastMembersDropsThePlaylist() async {
        let model = await loadedModel(
            [book1], playlists: [playlist("p", [book1]), playlist("q", [])],
            service: FakePlaylistEditingService(remove: { _ in playlist("p", []) }))
        await model.toggle(playlistID: "p")
        #expect(model.rows.map(\.id) == ["q"])
    }

    @Test(arguments: [true, false])
    func failedToggleRollsBack(checked: Bool) async throws {
        let gate = GatedCalls<PlaylistWrite, Playlist>()
        let original = playlist("p", checked ? [book2, book1] : [book2])
        let model = await loadedModel(
            [book1], playlists: [original],
            service: FakePlaylistEditingService(
                add: { try await gate.call($0) }, remove: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()
        let task = Task { await model.toggle(playlistID: "p") }
        let call = try #require(await calls.next())
        #expect(model.rows.first?.isChecked == !checked)
        call.reply.resume(throwing: TestError.offline)
        await task.value
        #expect(model.playlists == [original])
        #expect(model.rows.first?.isChecked == checked)
        #expect(model.rows.first?.isUpdating == false)
        #expect(model.failure == (checked ? .remove : .add))
        model.clearFailure()
        #expect(model.failure == nil)
    }

    @Test func cancelledToggleRollsBackWithoutFailure() async {
        let model = await loadedModel(
            [book1], playlists: [playlist("p", [])],
            service: FakePlaylistEditingService(add: { _ in throw CancellationError() }))
        await model.toggle(playlistID: "p")
        #expect(model.rows.map(\.isChecked) == [false])
        #expect(model.failure == nil)
    }

    @Test func secondToggleOfTheSamePlaylistIsIgnoredWhileInFlight() async throws {
        let gate = GatedCalls<PlaylistWrite, Playlist>()
        let model = await loadedModel(
            [book1], playlists: [playlist("p", []), playlist("q", [])],
            service: FakePlaylistEditingService(add: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()
        let first = Task { await model.toggle(playlistID: "p") }
        let call = try #require(await calls.next())
        await model.toggle(playlistID: "p")
        let other = Task { await model.toggle(playlistID: "q") }
        let otherCall = try #require(await calls.next())
        #expect(otherCall.request.id == "q")
        call.reply.resume(returning: playlist("p", [book1]))
        otherCall.reply.resume(returning: playlist("q", [book1]))
        await first.value
        await other.value
        #expect(call.request == PlaylistWrite(id: "p", entries: [book1]))
        #expect(model.rows.map(\.isChecked) == [true, true])
    }

    @Test func createSendsTheEntriesAndListsThePlaylistFirst() async {
        let writes = Locked<[PlaylistWrite]>([])
        let model = await loadedModel(
            [episode1, book1], playlists: [playlist("p", [])],
            service: FakePlaylistEditingService(create: { write in
                writes.value.append(write)
                return playlist("new", [episode1, book1])
            }))
        #expect(await model.create(name: "   ") == false)
        #expect(await model.create(name: "  Road trip \n") == true)
        #expect(writes.value == [PlaylistWrite(id: "lib/Road trip", entries: [episode1, book1])])
        #expect(model.rows.map(\.id) == ["new", "p"])
        #expect(model.rows.first?.isChecked == true)
        #expect(model.isCreating == false)
    }

    @Test func failedCreateReportsAndKeepsTheList() async {
        let model = await loadedModel(
            [book1], playlists: [playlist("p", [])],
            service: FakePlaylistEditingService(create: { _ in throw TestError.offline }))
        #expect(await model.create(name: "New") == false)
        #expect(model.failure == .create)
        #expect(model.rows.map(\.id) == ["p"])
    }

    @Test func failedLoadCanBeRetried() async {
        let attempts = Locked(0)
        let service = FakePlaylistEditingService(list: { libraryID in
            #expect(libraryID == "lib")
            attempts.value += 1
            if attempts.value == 1 { throw TestError.offline }
            return [playlist("p", [])]
        })
        let model = AddToPlaylistModel(entries: [book1], libraryID: "lib", service: service)
        await model.load()
        #expect(model.loadFailed)
        #expect(!model.hasLoaded)
        await model.load()
        #expect(!model.loadFailed)
        #expect(model.rows.map(\.id) == ["p"])
    }
}

extension Playlist {
    fileprivate func with(_ entries: [PlaylistEntryKey]) -> Playlist {
        Playlist(
            id: id, libraryId: libraryId, name: name,
            items: entries.map { PlaylistItem(libraryItemId: $0.itemID, episodeId: $0.episodeID) })
    }
}
