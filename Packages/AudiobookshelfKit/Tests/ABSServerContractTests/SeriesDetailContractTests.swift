import ABSAPI
import ABSCore
import Foundation
import Testing

// Unlike .requiresServer alone, this condition lets explicit but incomplete fixture setup
// reach the failing requirements below, even when ABS_TEST_SERVER_URL was forgotten.
@Suite(
    "Server contract: series detail",
    .enabled(
        if: ContractServer.current != nil || SeriesContractFixture.requested,
        "Set ABS_TEST_SERVER_URL (docs/testing/series-detail-contracts.md)"),
    .tags(.serverContract))
struct SeriesDetailContractTests {
    @Test(
        "owned two-book series: associations, progress transitions and user isolation",
        .enabled(
            if: SeriesContractFixture.requested,
            "Shared seed has no series; set ABS_TEST_SERIES_FIXTURE=1 and owned fixture IDs (docs/testing/series-detail-contracts.md)"
        ))
    func aggregateProgress() async throws {
        let fixture = try SeriesContractFixture.require()
        let server = try ContractServer.require()
        try await server.withUser { first in
            try await server.withUser { second in
                #expect(first.user.id != second.user.id)
                let detail = try await first.client.send(SeriesEndpoints.detail(id: fixture.seriesID))
                try await verifyAssociations(fixture, detail: detail, session: first)

                let omitted = try await first.client.send(
                    SeriesEndpoints.detail(id: fixture.seriesID, includeProgress: false))
                #expect(omitted.series == detail.series)
                #expect(omitted.progress == nil)
                // The old metadata-only endpoint and the shared core model remain compatible.
                #expect(try await first.client.send(ItemEndpoints.series(id: fixture.seriesID)) == detail.series)
                for id in fixture.itemIDs {
                    #expect(try await first.client.mediaProgress(itemID: id) == nil)
                    #expect(try await second.client.mediaProgress(itemID: id) == nil)
                }
                try await expectState(fixture, session: first, finished: [], isFinished: false)
                try await expectState(fixture, session: second, finished: [], isFinished: false)

                let one = fixture.itemIDs[0]
                let two = fixture.itemIDs[1]
                try await first.patch(one, .finished(true))
                let firstRow = try await first.progress(one)
                #expect(firstRow.libraryItemId == one)
                #expect(firstRow.isFinished)
                #expect(try await first.client.mediaProgress(itemID: two) == nil)
                try await expectState(fixture, session: first, finished: [one], isFinished: false)
                try await expectState(fixture, session: second, finished: [], isFinished: false)

                // A stored percentage of 1 alone is not the finished flag. The create-row
                // PATCH leaves this synthetic 30 s book unfinished, with ample time remaining.
                try await first.patch(two, .audio(currentTime: 5, duration: 30, progress: 1))
                let unfinishedRow = try await first.progress(two)
                #expect(unfinishedRow.progress == 1)
                #expect(!unfinishedRow.isFinished)
                try await expectState(fixture, session: first, finished: [one], isFinished: false)

                try await first.patch(two, .finished(true))
                #expect(try await first.progress(two).isFinished)
                try await expectState(fixture, session: first, finished: [one, two], isFinished: true)
                try await expectState(fixture, session: second, finished: [], isFinished: false)

                try await first.patch(one, .finished(false))
                #expect(try await first.progress(one).isFinished == false)
                try await expectState(fixture, session: first, finished: [two], isFinished: false)
                try await expectState(fixture, session: second, finished: [], isFinished: false)

                try await second.patch(one, .finished(true))
                try await expectState(fixture, session: second, finished: [one], isFinished: false)
                try await expectState(fixture, session: first, finished: [two], isFinished: false)
            }
        }
    }

    @Test("unknown series returns 404", .requiresServer)
    func missingSeries() async throws {
        try await ContractServer.require().withUser { session in
            await expectNotFound {
                try await session.client.send(SeriesEndpoints.detail(id: UUID().uuidString))
            }
        }
    }

    private func verifyAssociations(
        _ fixture: SeriesContractFixture, detail: SeriesDetailResponse, session: ContractSession
    ) async throws {
        #expect(detail.series.id == fixture.seriesID)
        #expect(!detail.series.name.isEmpty)
        #expect(detail.series.addedAt != nil)
        #expect(detail.series.updatedAt != nil)
        #expect(detail.series.books == nil)
        let libraryID = try #require(detail.series.libraryId)
        var mediaIDs: Set<String> = []
        // Expected membership comes from setup, NOT the aggregate's possibly lossy arrays.
        for (index, id) in fixture.itemIDs.enumerated() {
            let item = try await session.client.send(ItemEndpoints.item(id: id))
            let book = try #require(item.book)
            #expect(item.id == id)
            #expect(item.libraryId == libraryID)
            #expect(book.libraryItemId == id)
            let associations = try #require(book.metadata.series)
            #expect(associations.count == 1)
            let association = try #require(associations.first)
            #expect(association.id == fixture.seriesID)
            #expect(association.name == detail.series.name)
            #expect(association.sequence == String(index + 1))
            mediaIDs.insert(book.id)
        }
        #expect(mediaIDs.count == 2)
        #expect(mediaIDs.isDisjoint(with: fixture.itemIDs))
    }

    private func expectState(
        _ fixture: SeriesContractFixture, session: ContractSession, finished: [String], isFinished: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let endpoint = SeriesEndpoints.detail(id: fixture.seriesID)
        let detail = try await session.client.send(endpoint)
        let progress = try #require(detail.progress, sourceLocation: sourceLocation)
        #expect(Set(progress.libraryItemIds) == Set(fixture.itemIDs), sourceLocation: sourceLocation)
        #expect(progress.libraryItemIds.count == 2, sourceLocation: sourceLocation)
        #expect(Set(progress.libraryItemIdsFinished) == Set(finished), sourceLocation: sourceLocation)
        #expect(progress.libraryItemIdsFinished.count == finished.count, sourceLocation: sourceLocation)
        #expect(progress.isFinished == isFinished, sourceLocation: sourceLocation)

        // Independently inspect strict raw arrays so a lossy decoder cannot hide a wire change.
        let data = try await session.client.send(
            Endpoint<Data>(endpoint.method, endpoint.path, query: endpoint.query))
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["books"] == nil, sourceLocation: sourceLocation)
        let aggregate = try #require(raw["progress"] as? [String: Any])
        let rawIDs = try #require(aggregate["libraryItemIds"] as? [String])
        let rawFinishedIDs = try #require(aggregate["libraryItemIdsFinished"] as? [String])
        let rawFinished = try #require(aggregate["isFinished"] as? Bool)
        #expect(progress.libraryItemIds == rawIDs, sourceLocation: sourceLocation)
        #expect(progress.libraryItemIdsFinished == rawFinishedIDs, sourceLocation: sourceLocation)
        #expect(progress.isFinished == rawFinished, sourceLocation: sourceLocation)
    }
}

private struct SeriesContractFixture {
    let seriesID: String
    /// Ordered by synthetic sequence: 1, 2.
    let itemIDs: [String]

    static var requested: Bool {
        ProcessInfo.processInfo.environment["ABS_TEST_SERIES_FIXTURE"] != nil
    }

    static func require() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        try #require(
            environment["ABS_TEST_SERIES_FIXTURE"] == "1",
            "Explicit fixture enablement requires ABS_TEST_SERIES_FIXTURE=1")
        let seriesID = try #require(
            environment["ABS_TEST_SERIES_ID"], "Set ABS_TEST_SERIES_ID to the owned series UUID")
        try #require(UUID(uuidString: seriesID) != nil, "ABS_TEST_SERIES_ID must be a UUID")
        let rawIDs = try #require(
            environment["ABS_TEST_SERIES_ITEM_IDS"], "Set ABS_TEST_SERIES_ITEM_IDS to two comma-separated item UUIDs")
        let ids = rawIDs.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        try #require(
            ids.count == 2 && ids.allSatisfy { UUID(uuidString: $0) != nil } && Set(ids).count == 2
                && !ids.contains(seriesID),
            "ABS_TEST_SERIES_ITEM_IDS must contain two distinct library-item UUIDs, in sequence order 1,2")
        return Self(seriesID: seriesID, itemIDs: ids)
    }
}
