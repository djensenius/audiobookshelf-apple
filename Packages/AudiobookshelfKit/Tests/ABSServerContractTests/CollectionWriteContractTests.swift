import ABSAPI
import ABSCore
import Foundation
import Testing

@Suite(.requiresServer, .tags(.serverContract))
struct CollectionWriteContractTests {
    @Test func orderedTwoBookLifecycleAndEmptyRead() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            let user = try await fixture.user()
            let seed = fixture.seed
            let created = try await fixture.create(as: user)
            let id = created.id
            #expect(created.books?.map(\.id) == [seed.taleID, seed.singleFileID])
            #expect(created.libraryId == seed.bookLibraryID)
            #expect(created.description == "Initial description")
            #expect(created.userId == nil)
            let reordered = try await fixture.send(
                CollectionEndpoints.update(
                    id: id, CollectionUpdateRequest(bookIDsInOrder: [seed.singleFileID, seed.taleID])), as: user)
            #expect(reordered.books?.map(\.id) == [seed.singleFileID, seed.taleID])
            #expect(try await fixture.read(id, as: user).books?.map(\.id) == [seed.singleFileID, seed.taleID])
            let name = "renamed-" + UUID().uuidString
            let metadata = try await fixture.send(
                CollectionEndpoints.update(id: id, CollectionUpdateRequest(name: name, description: "Updated")),
                as: user)
            #expect(metadata.name == name)
            #expect(metadata.description == "Updated")
            let cleared = try await fixture.send(
                CollectionEndpoints.update(id: id, CollectionUpdateRequest(description: "")), as: user)
            #expect(cleared.description == "")
            let persisted = try await fixture.read(id, as: user)
            #expect(persisted.name == name)
            #expect(persisted.description == "")
            #expect(persisted.books?.map(\.id) == [seed.singleFileID, seed.taleID])
            let removed = try await fixture.send(
                CollectionEndpoints.removeBooks(id: id, CollectionBooksRequest(bookIDs: [seed.singleFileID])),
                as: user)
            #expect(removed.books?.map(\.id) == [seed.taleID])
            #expect(try await fixture.read(id, as: user).books?.map(\.id) == [seed.taleID])
            let added = try await fixture.send(
                CollectionEndpoints.addBooks(
                    id: id, CollectionBooksRequest(bookIDs: [seed.singleFileID, seed.taleID, UUID().uuidString])),
                as: user)
            #expect(added.books?.map(\.id) == [seed.taleID, seed.singleFileID])
            #expect(try await fixture.read(id, as: user).books?.map(\.id) == [seed.taleID, seed.singleFileID])
            let empty = try await fixture.send(
                CollectionEndpoints.removeBooks(
                    id: id, CollectionBooksRequest(bookIDs: [seed.taleID, seed.singleFileID])), as: user)
            #expect(empty.books == [])
            #expect(try await fixture.read(id, as: user).books == [])
            try await fixture.delete(id, as: user)
            await expectNotFound { try await user.client.send(ItemEndpoints.collection(id: id)) }
        }
    }

    @Test func noOpsAndMembershipErrors() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            let user = try await fixture.user()
            let seed = fixture.seed
            let original = try await fixture.create(as: user, books: [seed.taleID])
            let id = original.id
            let noOps = [
                CollectionEndpoints.update(id: id, CollectionUpdateRequest()),
                CollectionEndpoints.update(id: id, CollectionUpdateRequest(bookIDsInOrder: [])),
                CollectionEndpoints.addBooks(id: id, CollectionBooksRequest(bookIDs: [seed.taleID, seed.taleID])),
                CollectionEndpoints.removeBooks(
                    id: id, CollectionBooksRequest(bookIDs: [seed.singleFileID, UUID().uuidString])),
            ]
            for endpoint in noOps {
                let result = try await fixture.send(endpoint, as: user)
                #expect(result.books?.map(\.id) == [seed.taleID])
                #expect(result.name == original.name)
                #expect(result.description == original.description)
            }
            for books in [[], [UUID().uuidString], [seed.podcastID]] {
                await expectCollectionStatus(400) {
                    try await fixture.send(
                        CollectionEndpoints.addBooks(id: id, CollectionBooksRequest(bookIDs: books)), as: user)
                }
            }
            await expectCollectionStatus(500) {
                try await fixture.send(
                    CollectionEndpoints.removeBooks(id: id, CollectionBooksRequest(bookIDs: [])), as: user)
            }
            #expect(try await fixture.read(id, as: user).books?.map(\.id) == [seed.taleID])
            // More than one append: assert membership, not database-dependent append order.
            _ = try await fixture.send(
                CollectionEndpoints.removeBooks(id: id, CollectionBooksRequest(bookIDs: [seed.taleID])), as: user)
            let appended = try await fixture.send(
                CollectionEndpoints.addBooks(
                    id: id, CollectionBooksRequest(bookIDs: [seed.singleFileID, seed.taleID])), as: user)
            #expect(Set(appended.books?.map(\.id) ?? []) == [seed.taleID, seed.singleFileID])
            #expect(try await fixture.read(id, as: user).books?.map(\.id) == appended.books?.map(\.id))
        }
    }

    @Test func invalidCreateIsAtomic() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            let user = try await fixture.user()
            let seed = fixture.seed
            let media = try await user.client.send(ItemEndpoints.item(id: seed.taleID))
            let mediaID = try #require(media.book?.id)
            let cases: [(String, [String])] = [
                (seed.bookLibraryID, []),
                (seed.bookLibraryID, [seed.taleID, UUID().uuidString]),
                (seed.bookLibraryID, [seed.taleID, seed.taleID]),
                (seed.podcastLibraryID, [seed.taleID]),
                (seed.podcastLibraryID, [seed.podcastID]),
                (seed.bookLibraryID, [mediaID]),
            ]
            for (library, books) in cases {
                let name = "invalid-" + UUID().uuidString
                await expectCollectionStatus(400) {
                    try await fixture.create(as: user, books: books, name: name, libraryID: library)
                }
                // Exact unique name check only; no global count assertion or name-based deletion.
                let listed = try await user.client.send(LibraryEndpoints.collections(libraryID: library))
                #expect(!listed.results.contains { $0.name == name })
            }
        }
    }

    @Test func defaultUserIsDeniedAllFiveWritesOnRealCollection() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            let writer = try await fixture.user()
            let ordinary = try await fixture.user(elevated: false)
            let seed = fixture.seed
            let collection = try await fixture.create(as: writer)
            let endpoints = [
                CollectionEndpoints.create(
                    CollectionCreateRequest(
                        name: "denied-" + UUID().uuidString, libraryID: seed.bookLibraryID, bookIDs: [seed.taleID])),
                CollectionEndpoints.update(id: collection.id, CollectionUpdateRequest(name: "Denied")),
                CollectionEndpoints.addBooks(id: collection.id, CollectionBooksRequest(bookIDs: [seed.taleID])),
                CollectionEndpoints.removeBooks(id: collection.id, CollectionBooksRequest(bookIDs: [seed.taleID])),
            ]
            for endpoint in endpoints {
                await expectCollectionStatus(403) { try await fixture.send(endpoint, as: ordinary) }
            }
            await expectCollectionStatus(403) { try await fixture.delete(collection.id, as: ordinary) }
            let unchanged = try await fixture.read(collection.id, as: ordinary)
            #expect(unchanged == collection)
        }
    }

    @Test func lookupPrecedesPermissionsForUnknownIDs() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            for elevated in [false, true] {
                let user = try await fixture.user(elevated: elevated)
                let id = UUID().uuidString
                let endpoints = [
                    CollectionEndpoints.update(id: id, CollectionUpdateRequest()),
                    CollectionEndpoints.addBooks(id: id, CollectionBooksRequest(bookIDs: [fixture.seed.taleID])),
                    CollectionEndpoints.removeBooks(id: id, CollectionBooksRequest(bookIDs: [fixture.seed.taleID])),
                ]
                for endpoint in endpoints {
                    await expectCollectionStatus(404) { try await fixture.send(endpoint, as: user) }
                }
                await expectCollectionStatus(404) { try await fixture.delete(id, as: user) }
            }
        }
    }

    @Test func nameSanitizingAndLibraryAccessRemainVersionSpecific() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            let version = try #require(ContractServer.current?.version)
            try #require(["2.26.0", "2.37.2"].contains(version), "This contract requires an exact validated release")
            let writer = try await fixture.user()
            let restricted = try await fixture.user(accessibleLibraries: [fixture.seed.podcastLibraryID])
            let name = "collection-" + UUID().uuidString
            let collection = try await fixture.create(as: writer, name: "<b>\(name)</b>")
            #expect(collection.name == (version == "2.37.2" ? name : "<b>\(name)</b>"))
            let updated = try await fixture.send(
                CollectionEndpoints.update(id: collection.id, CollectionUpdateRequest(name: "<i>\(name)</i>")),
                as: writer)
            #expect(updated.name == (version == "2.37.2" ? name : "<i>\(name)</i>"))
            #expect(try await fixture.read(collection.id, as: writer).name == updated.name)
            if version == "2.37.2" {
                await expectCollectionStatus(403) { try await fixture.create(as: restricted) }
                await expectCollectionStatus(404) { try await fixture.read(collection.id, as: restricted) }
                await expectCollectionStatus(404) {
                    try await fixture.send(
                        CollectionEndpoints.update(id: collection.id, CollectionUpdateRequest()), as: restricted)
                }
            } else {
                let created = try await fixture.create(as: restricted)
                #expect(created.books?.count == 2)
                #expect(try await fixture.read(collection.id, as: restricted).id == collection.id)
                #expect(
                    try await fixture.send(
                        CollectionEndpoints.update(id: collection.id, CollectionUpdateRequest()), as: restricted
                    )
                    .id
                        == collection.id)
            }
        }
    }

    private struct DeliberateFailure: Error {
        let collections: [String]
        let users: [String]
    }

    @Test func teardownRunsAfterBodyThrowsAndPreservesPrimaryError() async throws {
        do {
            try await CollectionContractFixture.withFixture { fixture in
                let user = try await fixture.user()
                _ = try await fixture.create(as: user)
                let ids = await fixture.ownedIDs()
                throw DeliberateFailure(collections: ids.collections, users: ids.users)
            }
            Issue.record("Expected deliberate failure")
        } catch let failure as DeliberateFailure {
            #expect(failure.collections.count == 1)
            #expect(failure.users.count == 1)
            let admin = try await ContractAdmin.shared.session()
            for id in failure.collections {
                await expectNotFound { try await admin.client.send(ItemEndpoints.collection(id: id)) }
            }
            for id in failure.users {
                await expectNotFound { try await admin.client.send(Endpoint<Data>(.get, "/api/users/\(id)")) }
            }
        }
    }
}
