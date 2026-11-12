import ABSCore
import Foundation
import Testing

@testable import ABSAPI

// `MeController.getItemListeningSessions` (advplyr/audiobookshelf v2.26.0 L65–L92, v2.37.2
// L185–L218) looks up the item and `req.params.episodeId`, answers `sendStatus(404)` when
// `!libraryItem || (libraryItem.isPodcast && !episode)` (2.26.0 L69–L72, 2.37.2 L189–L192), and
// otherwise lists the user's sessions for `episode?.id || libraryItem.mediaId`. The book-item
// path, pagination and page size are pinned in `PlaybackSessionContractTests`.

@Suite("Server contract: listening sessions", .requiresServer, .tags(.serverContract))
struct ListeningSessionContractTests {
    @Test("an episode's page has its closed session, and the book's page doesn't")
    func episodePage() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let empty = try await session.client.send(
                SessionEndpoints.listeningSessions(itemID: seed.podcastID, episodeID: seed.episodeID))
            #expect(empty.sessions.isEmpty)

            let started = try await session.play(seed.podcastID, episodeID: seed.episodeID)
            try await session.sync(started, to: 5, listened: 2)
            // The 20 s episode keeps more than 10 s left, so the close doesn't finish it.
            let closing = try session.report(8, listened: 3, duration: started.duration)
            _ = try await session.client.send(SessionEndpoints.close(sessionID: started.id, report: closing))

            let page = try await session.client.send(
                SessionEndpoints.listeningSessions(itemID: seed.podcastID, episodeID: seed.episodeID))
            let stored = try #require(page.sessions.first { $0.id == started.id })
            #expect(stored.timeListening > 0)
            #expect(approximately(stored.timeListening, 5, tolerance: 0.001))
            #expect(approximately(stored.currentTime, 8))
            #expect(page.total == 1)

            let book = try await session.client.send(SessionEndpoints.listeningSessions(itemID: seed.taleID))
            #expect(!book.sessions.contains { $0.id == started.id })
            #expect(book.total == 0)
        }
    }

    @Test("an unknown item, and an unknown episode on a real podcast, are 404s")
    func notFound() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let unknown = UUID().uuidString.lowercased()
            await expectNotFound {
                try await session.client.send(SessionEndpoints.listeningSessions(itemID: unknown))
            }
            await expectNotFound {
                try await session.client.send(
                    SessionEndpoints.listeningSessions(itemID: unknown, episodeID: seed.episodeID))
            }
            await expectNotFound {
                try await session.client.send(
                    SessionEndpoints.listeningSessions(itemID: seed.podcastID, episodeID: unknown))
            }
        }
    }
}
