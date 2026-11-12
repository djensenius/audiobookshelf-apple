import ABSAPI
import ABSCore
import Foundation
import Testing

/// Opens, reads and closes a feed for a seeded book as root, since every feed route is admin-only.
/// The feed is closed again if the test fails part way.
@Suite(.requiresServer, .tags(.serverContract))
struct RssFeedContractTests {
    @Test func openCurrentAndClose() async throws {
        let admin = try await ContractAdmin.shared.session()
        let seed = try await ContractSeed.shared.data()
        let target = RssFeedTarget(.item, id: seed.taleID)
        let slug = "contract-" + UUID().uuidString.prefix(8).lowercased()
        let request = RssFeedOpenRequest(
            serverAddress: admin.server.configuration.baseURL.absoluteString, slug: slug,
            metadataDetails: .init(preventIndexing: false, ownerName: "Ada", ownerEmail: "ada@example.com"))

        #expect(try await admin.client.send(FeedEndpoints.current(target)).rssFeed == nil)
        let opened = try await admin.client.send(FeedEndpoints.open(target, request)).feed
        do {
            #expect(opened.entityType == "libraryItem")
            #expect(opened.entityId == seed.taleID)
            #expect(opened.feedUrl.hasSuffix("/feed/\(slug)"))
            #expect(opened.meta?.preventIndexing == false)
            #expect(opened.meta?.ownerName == "Ada")
            #expect(opened.meta?.ownerEmail == "ada@example.com")

            let current = try await admin.client.send(FeedEndpoints.current(target)).rssFeed
            #expect(current?.id == opened.id)
            #expect(current?.feedUrl == opened.feedUrl)

            // The slug is taken, and a user who isn't an admin can't open or close feeds.
            await expectFeedStatus(400) { try await admin.client.send(FeedEndpoints.open(target, request)) }
            try await ContractServer.require().withUser { user in
                await expectFeedStatus(403) { try await user.client.send(FeedEndpoints.close(id: opened.id)) }
            }
        } catch {
            _ = try? await admin.client.send(FeedEndpoints.close(id: opened.id))
            throw error
        }

        _ = try await admin.client.send(FeedEndpoints.close(id: opened.id))
        #expect(try await admin.client.send(FeedEndpoints.current(target)).rssFeed == nil)
        // Closing again is a 404, which the app treats as already closed.
        await expectNotFound { try await admin.client.send(FeedEndpoints.close(id: opened.id)) }
    }
}

private func expectFeedStatus<T>(
    _ status: Int, sourceLocation: SourceLocation = #_sourceLocation, _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    switch error {
    case .forbidden where status == 403:
        return
    case .http(let actual, _) where actual == status:
        return
    default:
        Issue.record("Expected \(status), got \(String(describing: error))", sourceLocation: sourceLocation)
    }
}
