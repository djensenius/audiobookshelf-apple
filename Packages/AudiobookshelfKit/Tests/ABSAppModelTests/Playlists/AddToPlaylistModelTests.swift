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
        let gate = CancellableGatedCalls<PlaylistWrite, Playlist>()
        let model = await loadedModel(
            [book1, episode1], playlists: [playlist("p", [book1])],
            // A wrong removal reaches the gate too, so it fails the request check instead of hanging.
            service: FakePlaylistEditingService(add: { try await gate.call($0) }, remove: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()
        async let toggled: Void = model.toggle(playlistID: "p")
        let call = try #require(await calls.next())
        #expect(call.request == PlaylistWrite(id: "p", entries: [episode1]))
        #expect(model.rows.first?.isChecked == true)
        #expect(model.rows.first?.isUpdating == true)
        call.reply.resume(
            returning: Playlist(id: "p", libraryId: "lib", name: "Renamed", items: []).with([book1, episode1]))
        await toggled
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

    /// Only a removal deletes a playlist on the server, so an add answered with no items keeps the row.
    @Test func anAddAnsweredWithNoItemsKeepsThePlaylist() async {
        let model = await loadedModel(
            [book1], playlists: [playlist("p", [])],
            service: FakePlaylistEditingService(add: { _ in playlist("p", []) }))
        await model.toggle(playlistID: "p")
        #expect(model.rows.map(\.id) == ["p"])
        #expect(model.failure == nil)
    }

    @Test func aRemovalFromADeletedPlaylistDropsItsRow() async {
        let model = await loadedModel(
            [book1], playlists: [playlist("p", [book1]), playlist("q", [])],
            service: FakePlaylistEditingService(
                add: { _ in throw APIError.notFound }, remove: { _ in throw APIError.notFound }))
        await model.toggle(playlistID: "p")
        #expect(model.rows.map(\.id) == ["q"])
        #expect(model.failure == nil)
        // An add that is 404 is an ordinary failure: the row goes back.
        await model.toggle(playlistID: "q")
        #expect(model.rows.map(\.id) == ["q"])
        #expect(model.rows.map(\.isChecked) == [false])
        #expect(model.failure == .add)
    }

    @Test(arguments: [true, false])
    func failedToggleRollsBack(checked: Bool) async throws {
        let gate = CancellableGatedCalls<PlaylistWrite, Playlist>()
        let original = playlist("p", checked ? [book2, book1] : [book2])
        let model = await loadedModel(
            [book1], playlists: [original],
            service: FakePlaylistEditingService(
                add: { try await gate.call($0) }, remove: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()
        async let toggled: Void = model.toggle(playlistID: "p")
        let call = try #require(await calls.next())
        #expect(model.rows.first?.isChecked == !checked)
        call.reply.resume(throwing: TestError.offline)
        await toggled
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
        let gate = CancellableGatedCalls<PlaylistWrite, Playlist>()
        let counter = KeyedCallCounter()
        let respond: @Sendable (PlaylistWrite) async throws -> Playlist = { write in
            // Only each playlist's first request waits. A repeat (a broken guard) is answered at once,
            // so the count check fails instead of the test hanging.
            guard counter.record(write.id) == 1 else { return playlist(write.id, []) }
            return try await gate.call(write)
        }
        let model = await loadedModel(
            [book1], playlists: [playlist("p", []), playlist("q", [])],
            service: FakePlaylistEditingService(add: respond, remove: respond))
        var calls = gate.calls.makeAsyncIterator()
        async let first: Void = model.toggle(playlistID: "p")
        let call = try #require(await calls.next())
        #expect(call.request == PlaylistWrite(id: "p", entries: [book1]))
        await model.toggle(playlistID: "p")
        #expect(counter.count("p") == 1)
        async let other: Void = model.toggle(playlistID: "q")
        let otherCall = try #require(await calls.next())
        #expect(otherCall.request.id == "q")
        call.reply.resume(returning: playlist("p", [book1]))
        otherCall.reply.resume(returning: playlist("q", [book1]))
        await first
        await other
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

    @Test func secondCreateIsIgnoredWhileOneIsInFlight() async throws {
        let gate = CancellableGatedCalls<PlaylistWrite, Playlist>()
        let counter = KeyedCallCounter()
        let model = await loadedModel(
            [book1], playlists: [playlist("p", [])],
            service: FakePlaylistEditingService(create: { write in
                // A repeat (a broken guard) is answered at once, so the count check fails instead of hanging.
                guard counter.record("create") == 1 else { return playlist("repeat", [book1]) }
                return try await gate.call(write)
            }))
        var calls = gate.calls.makeAsyncIterator()
        async let first = model.create(name: "One")
        let call = try #require(await calls.next())
        #expect(model.isCreating)
        #expect(await model.create(name: "Two") == false)
        #expect(counter.count("create") == 1)
        call.reply.resume(returning: playlist("new", [book1]))
        #expect(await first == true)
        #expect(call.request == PlaylistWrite(id: "lib/One", entries: [book1]))
        #expect(model.rows.map(\.id) == ["new", "p"])
        #expect(!model.isCreating)
    }

    @Test func aNewerLoadWinsOverAnOlderResponse() async throws {
        let gate = CancellableGatedCalls<Int, [Playlist]>()
        let counter = KeyedCallCounter()
        let model = AddToPlaylistModel(
            entries: [book1], libraryID: "lib",
            service: FakePlaylistEditingService(list: { _ in try await gate.call(counter.record("list")) }))
        var calls = gate.calls.makeAsyncIterator()
        async let older: Void = model.load()
        let olderCall = try #require(await calls.next())
        async let newer: Void = model.load()
        let newerCall = try #require(await calls.next())
        #expect(olderCall.request == 1)
        #expect(newerCall.request == 2)
        newerCall.reply.resume(returning: [playlist("new", [])])
        await newer
        #expect(model.rows.map(\.id) == ["new"])
        olderCall.reply.resume(returning: [playlist("old", [])])
        await older
        #expect(model.rows.map(\.id) == ["new"])
        #expect(!model.isLoading)
        #expect(!model.loadFailed)
    }

    @Test func aCancelledLoadIsNotAFailure() async {
        let model = AddToPlaylistModel(
            entries: [book1], libraryID: "lib",
            service: FakePlaylistEditingService(list: { _ in throw CancellationError() }))
        await model.load()
        #expect(!model.loadFailed)
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)
    }

    @Test func aFailedReloadKeepsTheList() async {
        let counter = KeyedCallCounter()
        let model = AddToPlaylistModel(
            entries: [book1], libraryID: "lib",
            service: FakePlaylistEditingService(list: { _ in
                if counter.record("list") > 1 { throw TestError.offline }
                return [playlist("p", [])]
            }))
        await model.load()
        await model.load()
        #expect(model.loadFailed)
        #expect(model.hasLoaded)
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
