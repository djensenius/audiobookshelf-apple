import ABSCore
import Foundation
import Testing

@testable import ABSAPI

/// Progress bodies `MediaProgressUpdate` can't build because the app never sends them: a mix of
/// the audio and finished groups, and one entry of a batch update.
private struct MixedGroups: Encodable, Sendable {
    let currentTime = 20.0
    let duration = 50.0
    let progress = 0.9
    let isFinished = false
}

private struct BatchEntry: Encodable, Sendable {
    let libraryItemId: String
    var episodeId: String?
    let currentTime: Double
    let duration: Double
    let progress: Double
}

extension ContractSession {
    fileprivate func rawPatch(_ path: String, _ body: some Encodable & Sendable) async throws {
        _ = try await client.send(Endpoint<EmptyResponse>(.patch, path, body: body))
    }

    /// The item IDs on the book library's Continue Listening shelf.
    fileprivate func continueListening(libraryID: String) async throws -> [String] {
        let shelves = try await client.send(LibraryEndpoints.personalized(libraryID: libraryID)).elements
        guard let shelf = shelves.first(where: { $0.id == "continue-listening" }),
            case .libraryItems(let items) = shelf.entities
        else { return [] }
        return items.map(\.id)
    }
}

/// `PATCH /api/me/progress` against a real server. The rules here are the ones the docs of
/// `MediaProgressUpdate` and ADR 0003 rely on; every test runs on a user with no progress.
@Suite("Server contract: media progress", .requiresServer, .tags(.serverContract))
struct ProgressContractTests {
    @Test("the audio group creates progress, which /api/me lists too")
    func audioGroup() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            #expect(try await session.client.mediaProgress(itemID: seed.taleID) == nil)

            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            let row = try await session.progress(seed.taleID)
            #expect(row.currentTime == 10)
            #expect(row.duration == 50)
            #expect(row.progress == 0.2)
            #expect(!row.isFinished)
            #expect(row.libraryItemId == seed.taleID)
            #expect(row.episodeId == nil)
            #expect(row.mediaItemType == .book)
            // Creating progress stores `ebookProgress` as 0 and starts it now: `startedAt` and
            // `lastUpdate` are separate clock reads, so they can differ by a millisecond.
            #expect(row.ebookProgress == 0)
            #expect(row.ebookLocation == nil)
            let startedAt = try #require(row.startedAt)
            #expect(abs(startedAt - (row.lastUpdate ?? 0)) <= 50)

            let me = try await session.client.send(Endpoint<User>(.get, "/api/me"))
            #expect(me.mediaProgress == [row])
            #expect(try await session.client.send(StatsEndpoints.finishedProgress()).finished == [false])
        }
    }

    @Test("lastUpdate is in milliseconds and moves with every effective PATCH only")
    func lastUpdate() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            let first = try #require(try await session.progress(seed.taleID).lastUpdate)
            #expect(first > 1_500_000_000_000)

            try await Task.sleep(for: .milliseconds(20))
            try await session.patch(seed.taleID, .audio(currentTime: 12, duration: 50, progress: 0.24))
            let second = try #require(try await session.progress(seed.taleID).lastUpdate)
            #expect(second > first)

            // `isFinished: false` on unfinished progress changes nothing, `lastUpdate` included.
            try await session.patch(seed.taleID, .finished(false))
            let unchanged = try await session.progress(seed.taleID)
            #expect(unchanged.lastUpdate == second)
            #expect(unchanged.currentTime == 12)
        }
    }

    @Test("the finished group sets progress to 1 and finishedAt, and un-finishing resets the position")
    func finishedGroup() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            let when = Date.now.addingTimeInterval(-86_400)
            try await session.patch(seed.taleID, .finished(true, at: when))
            let done = try await session.progress(seed.taleID)
            #expect(done.isFinished)
            #expect(done.progress == 1)
            #expect(done.currentTime == 10)
            #expect(done.finishedAt == milliseconds(when))
            #expect(try await session.client.send(StatsEndpoints.finishedProgress()).finishedCount == 1)
            #expect(try await session.continueListening(libraryID: seed.bookLibraryID) == [])

            try await session.patch(seed.taleID, .finished(false))
            let reset = try await session.progress(seed.taleID)
            #expect(!reset.isFinished)
            #expect(reset.currentTime == 0)
            #expect(reset.progress == 0)
            #expect(reset.finishedAt == nil)
        }
    }

    @Test("an audio PATCH that moves the position un-finishes the item")
    func audioUnfinishes() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            try await session.patch(seed.taleID, .finished(true))
            try await session.patch(seed.taleID, .audio(currentTime: 20, duration: 50, progress: 0.4))
            let row = try await session.progress(seed.taleID)
            #expect(!row.isFinished)
            #expect(row.currentTime == 20)
            #expect(row.progress == 0.4)
            #expect(row.finishedAt == nil)
        }
    }

    @Test("audio within 10 s of the end finishes the item; exactly 10 s does not")
    func autoFinish() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 40, duration: 50, progress: 0.8))
            #expect(try await session.progress(seed.taleID).isFinished == false)

            try await session.patch(seed.taleID, .audio(currentTime: 41, duration: 50, progress: 0.82))
            let row = try await session.progress(seed.taleID)
            #expect(row.isFinished)
            #expect(row.progress == 1)
            #expect(row.currentTime == 41)
            #expect(row.finishedAt != nil)
        }
    }

    @Test("the PATCH that creates a row near the end does not finish the item")
    func firstPatchNearTheEnd() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 49, duration: 50, progress: 0.98))
            let created = try await session.progress(seed.taleID)
            #expect(created.currentTime == 49)
            #expect(created.progress == 0.98)
            #expect(created.isFinished == false)

            try await session.patch(seed.taleID, .audio(currentTime: 49.5, duration: 50, progress: 0.99))
            #expect(try await session.progress(seed.taleID).isFinished)
        }
    }

    @Test("progress sent together with isFinished is ignored, so the groups are sent apart")
    func mixedGroupsLoseProgress() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            try await session.rawPatch("/api/me/progress/\(seed.taleID)", MixedGroups())
            let row = try await session.progress(seed.taleID)
            #expect(row.progress != 0.9)
            #expect(row.currentTime == 20)
        }
    }

    @Test("ebook progress of 0 is stored, and the group leaves the audio fields alone")
    func ebookGroup() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.patch(seed.taleID, .ebook(location: "epubcfi(/6/4)", progress: 0.7))
            let created = try await session.progress(seed.taleID)
            #expect(created.ebookLocation == "epubcfi(/6/4)")
            #expect(created.ebookProgress == 0.7)
            // An ebook PATCH that creates progress gives it empty audio fields.
            #expect(created.duration == 0)
            #expect(created.currentTime == 0)
            #expect(!created.isFinished)

            // The app always sends both fields; a location alone keeps the stored progress.
            try await session.rawPatch("/api/me/progress/\(seed.taleID)", ["ebookLocation": "epubcfi(/6/8)"])
            let moved = try await session.progress(seed.taleID)
            #expect(moved.ebookLocation == "epubcfi(/6/8)")
            #expect(moved.ebookProgress == 0.7)

            try await session.patch(seed.taleID, .ebook(location: "epubcfi(/6/2)", progress: 0))
            let zero = try await session.progress(seed.taleID)
            #expect(zero.ebookLocation == "epubcfi(/6/2)")
            #expect(zero.ebookProgress == 0)

            try await session.patch(seed.taleID, .audio(currentTime: 5, duration: 50, progress: 0.1))
            let both = try await session.progress(seed.taleID)
            #expect(both.currentTime == 5)
            #expect(both.ebookLocation == "epubcfi(/6/2)")
        }
    }

    @Test("hiding from Continue Listening holds until the position changes")
    func hideFromContinueListening() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            #expect(try await session.continueListening(libraryID: seed.bookLibraryID) == [])
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            #expect(try await session.continueListening(libraryID: seed.bookLibraryID) == [seed.taleID])

            try await session.patch(seed.taleID, .hideFromContinueListening(true))
            #expect(try await session.progress(seed.taleID).hideFromContinueListening)
            #expect(try await session.continueListening(libraryID: seed.bookLibraryID) == [])

            try await session.patch(seed.taleID, .audio(currentTime: 12, duration: 50, progress: 0.24))
            #expect(try await session.progress(seed.taleID).hideFromContinueListening == false)
            #expect(try await session.continueListening(libraryID: seed.bookLibraryID) == [seed.taleID])
        }
    }

    @Test("a batch update writes several items, episodes included, in one request")
    func batchUpdate() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.rawPatch(
                "/api/me/progress/batch/update",
                [
                    BatchEntry(libraryItemId: seed.taleID, currentTime: 10, duration: 50, progress: 0.2),
                    BatchEntry(libraryItemId: seed.singleFileID, currentTime: 5, duration: 40, progress: 0.125),
                    BatchEntry(
                        libraryItemId: seed.podcastID, episodeId: seed.episodeID, currentTime: 4, duration: 20,
                        progress: 0.2),
                ])
            #expect(try await session.progress(seed.taleID).currentTime == 10)
            #expect(try await session.progress(seed.singleFileID).currentTime == 5)
            let episode = try await session.progress(seed.podcastID, episodeID: seed.episodeID)
            #expect(episode.currentTime == 4)
            #expect(episode.mediaItemType == .podcastEpisode)
            let me = try await session.client.send(Endpoint<User>(.get, "/api/me"))
            #expect(me.mediaProgress.count == 3)
        }
    }

    @Test("deleting progress removes it everywhere")
    func deleteProgress() async throws {
        let seed = try await ContractSeed.shared.data()
        let server = try ContractServer.require()
        try await server.withUser { session in
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            let row = try await session.progress(seed.taleID)

            _ = try await session.client.send(ProgressEndpoints.delete(id: row.id))
            #expect(try await session.client.mediaProgress(itemID: seed.taleID) == nil)
            let me = try await session.client.send(Endpoint<User>(.get, "/api/me"))
            #expect(me.mediaProgress.isEmpty)

            // A repeated delete is 200 on 2.26.0 and 404 on 2.37.2, so a retry must accept both.
            do {
                _ = try await session.client.send(ProgressEndpoints.delete(id: row.id))
                #expect(server.version != "2.37.2", "2.37.2 answers 404 for progress that is gone")
            } catch APIError.notFound {
                #expect(server.version != "2.26.0", "2.26.0 answers 200 for progress that is gone")
            }
        }
    }
}
