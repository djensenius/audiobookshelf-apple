import ABSAPI
import Foundation
import Testing

@Suite("Server contract: author detail", .requiresServer, .tags(.serverContract))
struct AuthorContractTests {
    @Test("author metadata and included associations agree with the real response")
    func includedAssociations() async throws {
        try await ContractServer.require().withUser { session in
            // An independently seeded disposable evidence server can supply a series-bearing
            // author without changing shared harness books or expanding the standard seed.
            let evidenceID = ProcessInfo.processInfo.environment["ABS_TEST_AUTHOR_ID"]
            let authorID: String
            if let evidenceID {
                authorID = evidenceID
            } else {
                let seed = try await ContractSeed.shared.data()
                let authors = try await session.client.send(
                    LibraryEndpoints.authors(libraryID: seed.bookLibraryID))
                authorID = try #require(authors.authors.first { $0.name == "Ada Fixture" }).id
            }
            let endpoint = AuthorEndpoints.author(id: authorID)
            let detail = try await session.client.send(endpoint)
            #expect(detail.author.id == authorID)
            #expect(!detail.author.name.isEmpty)
            #expect(detail.author.addedAt != nil)
            #expect(detail.author.updatedAt != nil)
            #expect(!detail.libraryItems.isEmpty)
            #expect(detail.libraryItems.allSatisfy { $0.libraryId == detail.author.libraryId })
            #expect(detail.libraryItems.allSatisfy { $0.book?.metadata.title.isEmpty == false })

            // Lossy decoders must not turn a changed wire shape into a false green.
            let data = try await session.client.send(
                Endpoint<Data>(endpoint.method, endpoint.path, query: endpoint.query))
            let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let items = try #require(raw["libraryItems"] as? [[String: Any]])
            let groups = try #require(raw["series"] as? [[String: Any]])
            #expect(detail.libraryItems.map(\.id) == items.compactMap { $0["id"] as? String })
            #expect(detail.series.map(\.id) == groups.compactMap { $0["id"] as? String })
            if evidenceID != nil { #expect(!detail.series.isEmpty) }
            for (group, rawGroup) in zip(detail.series, groups) {
                let members = try #require(rawGroup["items"] as? [[String: Any]])
                #expect(!group.items.isEmpty)
                #expect(group.items.map(\.id) == members.compactMap { $0["id"] as? String })
                for (member, rawMember) in zip(group.items, members) {
                    #expect(detail.libraryItems.contains { $0.id == member.id })
                    #expect(member.libraryId == detail.author.libraryId)
                    #expect(member.series?.id == group.id)
                    #expect(member.series?.name == group.name)
                    let media = try #require(rawMember["media"] as? [String: Any])
                    let metadata = try #require(media["metadata"] as? [String: Any])
                    let series = try #require(metadata["series"] as? [String: Any])
                    #expect(member.series?.sequence == series["sequence"] as? String)
                }
            }
        }
    }

    @Test("a missing author returns 404 through the production endpoint")
    func missingAuthor() async throws {
        try await ContractServer.require().withUser { session in
            await expectNotFound {
                try await session.client.send(AuthorEndpoints.author(id: UUID().uuidString))
            }
        }
    }
}
