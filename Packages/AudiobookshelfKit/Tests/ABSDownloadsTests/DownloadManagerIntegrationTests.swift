import ABSCore
import Foundation
import Testing

@testable import ABSData
@testable import ABSDownloads

/// ``DownloadManager`` with the real ``DownloadEngine`` over ``StubDownloadSession``.
@Suite(.timeLimit(.minutes(1))) struct DownloadManagerIntegrationTests {
    /// Each fixture file's body, sized as the server reported it.
    static let bodies: [String: Data] = [
        "101": Data(repeating: 1, count: 1_000), "102": Data(repeating: 2, count: 2_000),
        "103": Data(repeating: 3, count: 3_000), "201": Data(repeating: 4, count: 4_000),
    ]
    static let cover = Data("jpeg-bytes".utf8)

    @Test func aQueuedBookBecomesALocalItem() async throws {
        let harness = try await DownloadHarness { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/api/items/li_book/cover") {
                return .status(200, body: Self.cover, contentType: "image/jpeg")
            }
            let ino = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            guard let body = Self.bodies[ino] else { return .status(404) }
            return .status(200, body: body, contentType: ino == "201" ? "application/epub+zip" : "audio/mpeg")
        }
        let engine = harness.makeEngine()
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: engine, locations: harness.locations,
            capacity: FakeCapacity(), clock: harness.clock)
        try await manager.start()
        let events = await manager.events()
        let item = LibraryItemFixtures.book()

        let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: harness.connectionID)

        guard case .started(let recordID) = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        let completed = await events.next {
            if case .completed = $0 { true } else { false }
        }
        guard case .completed(recordID, let itemID, let key) = completed else {
            Issue.record("Unexpected \(String(describing: completed))")
            return
        }
        #expect(key == MediaKey(serverConnectionID: harness.connectionID, libraryItemId: "li_book"))
        #expect(try await harness.store.record(id: recordID) == nil)
        let local = try #require(try await harness.localItems.item(id: itemID))
        let folder = "\(harness.connectionID.uuidString)/li_book"
        #expect(local.relativeDirectory == folder)
        #expect(local.files.map(\.kind) == [.audio, .audio, .audio, .ebook])
        #expect(
            local.files.map(\.relativePath) == [
                "\(folder)/01 - Part One.mp3", "\(folder)/02 - Part Two.mp3", "\(folder)/03 - Part Three.mp3",
                "\(folder)/Dune.epub",
            ])
        #expect(local.files.map(\.size) == [1_000, 2_000, 3_000, 4_000])
        #expect(local.coverRelativePath == "\(folder)/cover.jpg")
        let coverUpdatedAt = try #require(local.coverUpdatedAt)
        #expect(abs(coverUpdatedAt.timeIntervalSince1970 - 1_700_000_000.123) < 0.000_1)
        #expect(try Data(contentsOf: harness.fileURL("\(folder)/cover.jpg")) == Self.cover)
        #expect(try Data(contentsOf: harness.fileURL("\(folder)/Dune.epub")) == Self.bodies["201"])
        let coverRequest = try #require(harness.requests.first { $0.url?.path().hasSuffix("/cover") == true })
        #expect(coverRequest.url?.query() == "width=1200&format=jpeg&ts=1700000000123")
    }
}
