import ABSAPI
import ABSCore
import Foundation
import Testing

@Suite(.requiresServer, .tags(.serverContract))
struct PlaylistWriteContractTests {
    @Test func ordinaryOwnerBookLifecycleAndTailReadd() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let books = await fixture.books
            let seed = fixture.seed
            let created = try await fixture.create(as: owner)
            let id = created.id
            #expect(created.userId == owner.user.id)
            #expect(created.libraryId == seed.bookLibraryID)
            #expect(created.items.map(\.libraryItemId) == [seed.taleID, seed.singleFileID])
            let reordered = try await fixture.send(
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(itemsInOrder: books.reversed())), as: owner)
            #expect(reordered.items.map(\.libraryItemId) == [seed.singleFileID, seed.taleID])
            let updated = try await fixture.send(
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(name: "Renamed", description: "Updated")),
                as: owner)
            #expect(updated.name == "Renamed")
            #expect(updated.description == "Updated")
            let noOp = try await fixture.send(
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(name: "", description: "")), as: owner)
            #expect(noOp.name == updated.name)
            #expect(noOp.description == updated.description)
            #expect(try await fixture.read(id, as: owner) == noOp)
            let removed = try await fixture.send(
                PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: [books[0]])), as: owner)
            #expect(removed.items.map(\.libraryItemId) == [seed.singleFileID])
            let added = try await fixture.send(
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: [books[0]])), as: owner)
            #expect(added.items.map(\.libraryItemId) == [seed.singleFileID, seed.taleID])
            #expect(try await fixture.read(id, as: owner).items == added.items)
            let empty = try await fixture.send(
                PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: books)), as: owner)
            #expect(empty.items.isEmpty)
            await expectPlaylistStatus(404) { try await fixture.read(id, as: owner) }
            let explicit = try await fixture.create(as: owner)
            try await fixture.delete(explicit.id, as: owner)
            await expectPlaylistStatus(404) { try await fixture.read(explicit.id, as: owner) }
        }
    }

    @Test func oneEpisodeCreateReaddNoOpRemoveLast() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let episode = await fixture.episode
            let created = try await fixture.create(
                as: owner, items: [episode], libraryID: fixture.seed.podcastLibraryID)
            #expect(created.items.count == 1)
            #expect(created.items.first?.libraryItemId == fixture.seed.podcastID)
            #expect(created.items.first?.episodeId == fixture.seed.episodeID)
            let added = try await fixture.send(
                PlaylistEndpoints.addItems(id: created.id, PlaylistItemsRequest(items: [episode])), as: owner)
            #expect(added.items == created.items)
            #expect(try await fixture.read(created.id, as: owner).items == created.items)
            let empty = try await fixture.send(
                PlaylistEndpoints.removeItems(id: created.id, PlaylistItemsRequest(items: [episode])), as: owner)
            #expect(empty.items.isEmpty)
            await expectPlaylistStatus(404) { try await fixture.read(created.id, as: owner) }
        }
    }

    @Test func noOpsAtomicInvalidAddEmptyBatchesAndInvalidReorders() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let books = await fixture.books
            let unknown = PlaylistItemReference(libraryItemID: UUID().uuidString)
            let original = try await fixture.create(as: owner, items: [books[0]])
            let id = original.id
            let noOps = [
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest()),
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(itemsInOrder: [])),
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: [books[0]])),
                PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: [books[1], unknown])),
            ]
            for endpoint in noOps {
                let result = try await fixture.send(endpoint, as: owner)
                #expect(result.items == original.items)
                #expect(result.name == original.name)
                #expect(result.description == original.description)
            }
            let errors = [
                // A valid new book followed by an unknown ID must reject ALL additions.
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: [books[1], unknown])),
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: [])),
                PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: [])),
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(itemsInOrder: [unknown])),
            ]
            for endpoint in errors {
                await expectPlaylistStatus(400) { try await fixture.send(endpoint, as: owner) }
                #expect(try await fixture.read(id, as: owner).items == original.items)
            }
            _ = try await fixture.send(
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: [books[1]])), as: owner)
            await expectPlaylistStatus(400) {
                try await fixture.send(
                    PlaylistEndpoints.update(id: id, PlaylistUpdateRequest(itemsInOrder: [books[0]])), as: owner)
            }
            // Removing the head then appending can produce tied order numbers: membership only.
            _ = try await fixture.send(
                PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: [books[0]])), as: owner)
            let tied = try await fixture.send(
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: [books[0]])), as: owner)
            #expect(Set(tied.items.map(\.libraryItemId)) == [fixture.seed.taleID, fixture.seed.singleFileID])
            #expect(tied.items.count == 2)
        }
    }

    @Test func secondOrdinaryAndAdminCannotReadOrMutateAnotherOwnersPlaylist() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let other = try await fixture.user()
            let original = try await fixture.create(as: owner)
            let books = await fixture.books
            for denied in [other, fixture.admin] {
                let endpoints = [
                    ItemEndpoints.playlist(id: original.id),
                    PlaylistEndpoints.update(id: original.id, PlaylistUpdateRequest(name: "Denied")),
                    PlaylistEndpoints.addItems(id: original.id, PlaylistItemsRequest(items: [books[0]])),
                    PlaylistEndpoints.removeItems(id: original.id, PlaylistItemsRequest(items: [books[0]])),
                ]
                for endpoint in endpoints {
                    await expectPlaylistStatus(403) { try await fixture.send(endpoint, as: denied) }
                }
                await expectPlaylistStatus(403) { try await fixture.delete(original.id, as: denied) }
            }
            #expect(try await fixture.read(original.id, as: owner) == original)
        }
    }

    @Test func unknownIDRoutesReturn404() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let books = await fixture.books
            let id = UUID().uuidString
            for endpoint in [
                ItemEndpoints.playlist(id: id),
                PlaylistEndpoints.update(id: id, PlaylistUpdateRequest()),
                PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: books)),
                PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: books)),
            ] {
                await expectPlaylistStatus(404) { try await fixture.send(endpoint, as: owner) }
            }
            await expectPlaylistStatus(404) { try await fixture.delete(id, as: owner) }
        }
    }

    @Test func versionSpecificNameAndLibraryAccess() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let version = try #require(ContractServer.current?.version)
            try #require(["2.26.0", "2.37.2"].contains(version))
            let owner = try await fixture.user()
            let restricted = try await fixture.user(accessibleLibraries: [fixture.seed.podcastLibraryID])
            let created = try await fixture.create(as: owner, name: "<b>Playlist</b>")
            #expect(created.name == (version == "2.37.2" ? "Playlist" : "<b>Playlist</b>"))
            let updated = try await fixture.send(
                PlaylistEndpoints.update(id: created.id, PlaylistUpdateRequest(name: "<i>Updated</i>")), as: owner)
            #expect(updated.name == (version == "2.37.2" ? "Updated" : "<i>Updated</i>"))
            #expect(try await fixture.read(created.id, as: owner).name == updated.name)
            if version == "2.37.2" {
                await expectPlaylistStatus(403) { try await fixture.create(as: restricted) }
            } else {
                #expect(try await fixture.create(as: restricted).items.count == 2)
            }
            try await fixture.restrict(owner)
            let books = await fixture.books
            let endpoints = [
                ItemEndpoints.playlist(id: created.id),
                PlaylistEndpoints.update(id: created.id, PlaylistUpdateRequest()),
                PlaylistEndpoints.addItems(id: created.id, PlaylistItemsRequest(items: [books[0]])),
                PlaylistEndpoints.removeItems(
                    id: created.id,
                    PlaylistItemsRequest(items: [PlaylistItemReference(libraryItemID: UUID().uuidString)])),
            ]
            for endpoint in endpoints {
                if version == "2.37.2" {
                    await expectPlaylistStatus(404) { try await fixture.send(endpoint, as: owner) }
                } else {
                    #expect(try await fixture.send(endpoint, as: owner).items.count == 2)
                }
            }
            if version == "2.37.2" {
                await expectPlaylistStatus(404) { try await fixture.delete(created.id, as: owner) }
                // Owner cannot delete after restriction; fixture explicitly uses verified user cascade.
            } else {
                try await fixture.delete(created.id, as: owner)
            }
        }
    }

    private struct OmittedItems: Encodable, Sendable {
        let name = "Omitted items"
        let libraryId: String
    }

    @Test func safeEmptyOmittedAndDuplicateBookCreateCharacterization() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let books = await fixture.books
            let empty = try await fixture.create(as: owner, items: [])
            #expect(empty.items.isEmpty)
            #expect(try await fixture.read(empty.id, as: owner).items.isEmpty)
            let omitted = try await fixture.send(
                Endpoint(.post, "/api/playlists", body: OmittedItems(libraryId: fixture.seed.bookLibraryID)), as: owner)
            #expect(omitted.items.isEmpty)
            #expect(try await fixture.read(omitted.id, as: owner).items.isEmpty)
            let duplicate = try await fixture.create(as: owner, items: [books[0], books[0]])
            #expect(duplicate.items.map(\.libraryItemId) == [fixture.seed.taleID, fixture.seed.taleID])
            #expect(try await fixture.read(duplicate.id, as: owner).items == duplicate.items)
            print(
                "Playlist \(ContractServer.current?.version ?? "?"): empty/omitted create 200 + GET 200; duplicate BOOK create retains two members"
            )
        }
    }

    @Test func listCacheFreshnessCharacterization() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            _ = try await fixture.list(as: owner)  // Prime before any write.
            let created = try await fixture.create(as: owner)
            let afterCreate = try await fixture.list(as: owner).first { $0.id == created.id }
            let updated = try await fixture.send(
                PlaylistEndpoints.update(id: created.id, PlaylistUpdateRequest(name: "Cache update")), as: owner)
            let afterUpdate = try await fixture.list(as: owner).first { $0.id == created.id }
            let books = await fixture.books
            let removed = try await fixture.send(
                PlaylistEndpoints.removeItems(id: created.id, PlaylistItemsRequest(items: [books[1]])), as: owner)
            let afterRemove = try await fixture.list(as: owner).first { $0.id == created.id }
            let added = try await fixture.send(
                PlaylistEndpoints.addItems(id: created.id, PlaylistItemsRequest(items: [books[1]])), as: owner)
            let afterAdd = try await fixture.list(as: owner).first { $0.id == created.id }
            try await fixture.delete(created.id, as: owner)
            let afterDelete = try await fixture.list(as: owner).contains { $0.id == created.id }
            print(
                "Playlist list freshness \(ContractServer.current?.version ?? "?"): create=\(afterCreate == created), update=\(afterUpdate == updated), remove=\(afterRemove == removed), add=\(afterAdd == added), delete=\(!afterDelete)"
            )
            #expect(afterCreate == created)
            #expect(afterUpdate == updated)
            #expect(afterRemove == removed)
            #expect(afterAdd == added)
            #expect(!afterDelete)
        }
    }

    @Test func userDeletionCascadesExactOwnedPlaylist() async throws {
        try await PlaylistContractFixture.withFixture { fixture in
            let owner = try await fixture.user()
            let created = try await fixture.create(as: owner)
            try await fixture.deleteUser(owner)
            await expectPlaylistStatus(404) { try await fixture.read(created.id, as: fixture.admin) }
        }
    }

    private struct DeliberateFailure: Error {
        let playlists: [String]
        let users: [String]
    }

    @Test func teardownAfterBodyFailurePreservesPrimaryError() async throws {
        do {
            try await PlaylistContractFixture.withFixture { fixture in
                let owner = try await fixture.user()
                _ = try await fixture.create(as: owner)
                let ids = await fixture.ownedIDs()
                throw DeliberateFailure(playlists: ids.playlists, users: ids.users)
            }
            Issue.record("Expected deliberate failure")
        } catch let failure as DeliberateFailure {
            #expect(failure.playlists.count == 1)
            #expect(failure.users.count == 1)
            let admin = try await ContractAdmin.shared.session()
            for id in failure.playlists {
                await expectPlaylistStatus(404) { try await admin.client.send(ItemEndpoints.playlist(id: id)) }
            }
            for id in failure.users {
                await expectPlaylistStatus(404) {
                    try await admin.client.send(Endpoint<Data>(.get, "/api/users/\(id)"))
                }
            }
        }
    }
}
